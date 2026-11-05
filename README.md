# Container Security Lab

Hands-on lab covering the container pipeline from **build → scan → deploy → admission control → signing → runtime**. Runs in **GitHub Codespaces**, so nothing needs to be installed on my laptop.

**Time:** about 3–4 hours total. Each step stands on its own, so it can be split across sessions.

| Step | What I'll do | Where |
|---|---|---|
| 0 | Start the Codespace | Codespaces |
| 1 | Build a naive image and a hardened image | Codespaces |
| 2 | Scan both with Trivy, generate an SBOM, fail a "build" | Codespaces |
| 3 | Run both on a local Kubernetes cluster (kind); try Pod Security Admission | Codespaces |
| 4 | Install Kyverno; audit, then enforce policies | Codespaces |
| 5 | Sign an image with cosign and catch tampering | Codespaces |
| 6 | Detect a shell in a container with Falco | Killercoda |
| 7 | Clean up | Both |

---

## Step 0: Start the Codespace

1. On this repo's GitHub page: **Code → Codespaces → ⋯ → New with options**.
2. Pick the **4-core** machine. Click **Create codespace**.
3. Wait for setup to finish (a few minutes). The terminal ends with `Setup done.`
4. Check the tools: `kind version && trivy --version && cosign version && kubectl version --client && helm version`

**Cost:** personal GitHub accounts get free Codespaces hours each month; a 4-core machine uses them twice as fast as a 2-core one. Check usage under **GitHub Settings → Billing and licensing**. Codespaces stop automatically after 30 minutes idle.

---

## Step 1: Build two images

```bash
cd app
docker build -f Dockerfile.bad  -t lab/app-bad:latest .
docker build -f Dockerfile.good -t lab/app-good:1.0 .
docker images lab/*
```

**Compare them:**

```bash
# Who does each image run as?
docker run --rm --entrypoint whoami lab/app-bad:latest      # root
docker run --rm --entrypoint id lab/app-good:1.0             # fails: no 'id' binary in distroless

# Can an attacker get a shell?
docker run --rm -it --entrypoint sh lab/app-bad:latest -c 'echo I have a shell; which apt curl'
docker run --rm -it --entrypoint sh lab/app-good:1.0         # fails: no shell at all
cd ..
```

**What to notice:** size difference, root vs. non-root, and that the hardened image has no shell or package manager for an attacker to use.

**Interview takeaway:** "Approved minimal base images are the highest-leverage control: smaller attack surface, fewer CVEs, and one place to patch."

---

## Step 2: Scan, SBOM, and fail a build

```bash
# Scan both. Look at the "Total:" line for each.
trivy image --severity HIGH,CRITICAL lab/app-bad:latest | grep -E "^Total|^lab"
trivy image --severity HIGH,CRITICAL lab/app-good:1.0  | grep -E "^Total|^lab"

# Only show CVEs that have a fix available (what teams can actually act on)
trivy image --severity CRITICAL --ignore-unfixed lab/app-bad:latest | grep -E "^Total"
```

**Simulate a CI gate** (exit code 1 = the pipeline would fail):

```bash
trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed -q lab/app-bad:latest > /dev/null; echo "bad image exit code: $?"
trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed -q lab/app-good:1.0  > /dev/null; echo "good image exit code: $?"
```

**SBOM:**

```bash
trivy image --format cyclonedx --output sbom-bad.json lab/app-bad:latest
trivy image --format cyclonedx --output sbom-good.json lab/app-good:1.0

# "Are we running OpenSSL anywhere?" answered from the SBOM, no rescan needed
grep -o '"name":"[^"]*ssl[^"]*"' sbom-bad.json | sort -u
grep -o '"name":"[^"]*ssl[^"]*"' sbom-good.json | sort -u

# Rescan from the SBOM later (e.g. when a new CVE drops)
trivy sbom sbom-bad.json --severity CRITICAL | grep -E "^Total"
```

**What to notice:** how many CVEs the old full base image carries vs. distroless, and how many have no fix yet.

**Interview takeaway:** "I'd fail builds on fixable criticals, prioritize by exploitability, and keep SBOMs so a new CVE becomes a query, not a fire drill." (This is the same job Prisma/Twistlock and Wiz do at scale.)

---

## Step 3: Run on Kubernetes

```bash
kind create cluster --name lab
kind load docker-image lab/app-bad:latest lab/app-good:1.0 --name lab

kubectl apply -f k8s/pod-bad.yaml -f k8s/pod-good.yaml
kubectl get pods -w        # Ctrl+C once both are Running

kubectl exec app-bad -- whoami     # root, in a privileged container
kubectl delete -f k8s/pod-bad.yaml -f k8s/pod-good.yaml
```

With no policies, Kubernetes happily runs a **privileged root container**. That's the problem admission control solves.

**Built-in option: Pod Security Admission**

```bash
kubectl create namespace psa-demo
kubectl label namespace psa-demo pod-security.kubernetes.io/enforce=restricted

kubectl apply -n psa-demo -f k8s/pod-bad.yaml    # rejected, with the list of violations
kubectl apply -n psa-demo -f k8s/pod-good.yaml   # allowed
kubectl delete namespace psa-demo
```

**What to notice:** the rejection message lists every violation. The good pod passes the strictest built-in level.

**Interview takeaway:** "Pod Security Admission is a free baseline per namespace. A policy engine like Kyverno adds custom rules: approved registries, required tags, signed images."

---

## Step 4: Kyverno, audit first, then enforce

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

kubectl apply -f policies/
kubectl get clusterpolicy
```

**Audit mode:** violations are allowed but recorded.

```bash
kubectl apply -f k8s/pod-bad.yaml
sleep 20
kubectl get policyreport -A
kubectl describe policyreport -n default | grep -A3 -i fail
kubectl delete -f k8s/pod-bad.yaml
```

**Enforce mode:** violations are blocked.

```bash
sed -i 's/failureAction: Audit/failureAction: Enforce/' policies/*.yaml
kubectl apply -f policies/

kubectl apply -f k8s/pod-bad.yaml     # blocked, with all three policy messages
kubectl apply -f k8s/pod-good.yaml    # allowed
kubectl delete -f k8s/pod-good.yaml
```

**Try breaking it:** edit `k8s/pod-good.yaml`, change the image to `lab/app-good:latest`, and apply. Which policy catches it?

**What to notice:** audit mode tells you how many workloads *would* break before you turn on enforcement.

**Interview takeaway:** "I roll out admission policies in audit mode, share the violations with teams, fix the noisy rules, then enforce, with a time-boxed exception process. Same pattern I'd use for Wiz Code and the Wiz Admission Controller."

---

## Step 5: Sign an image and catch tampering

Run a local registry, push the good image, sign it, then swap the image and watch verification fail.

```bash
docker run -d -p 5001:5000 --name registry registry:2

docker tag lab/app-good:1.0 localhost:5001/app-good:1.0
docker push localhost:5001/app-good:1.0
IMAGE=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' localhost:5001/app-good:1.0 | grep '^localhost:5001/')
echo $IMAGE     # must start with localhost:5001/app-good@sha256:

# Create a key pair (empty password is fine for a lab)
COSIGN_PASSWORD="" cosign generate-key-pair

# Sign by digest. --tlog-upload=false keeps this off the public Sigstore transparency log.
COSIGN_PASSWORD="" cosign sign --key cosign.key --tlog-upload=false --allow-insecure-registry --yes $IMAGE

# Verify: should succeed
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-insecure-registry $IMAGE
```

**Now tamper:** push the bad image under the same tag.

```bash
docker tag lab/app-bad:latest localhost:5001/app-good:1.0
docker push localhost:5001/app-good:1.0
cosign verify --key cosign.pub --insecure-ignore-tlog=true --allow-insecure-registry localhost:5001/app-good:1.0   # fails: no valid signature
```

**What to notice:** the tag now points to a different image, and verification fails. That's why you sign and deploy **by digest**, and why tag immutability in ECR/ACR matters.

**Stretch:** wire Kyverno's `verifyImages` rule to the local registry so unsigned images are blocked at admission (needs the kind local-registry setup from the kind docs).

**Interview takeaway:** "Signing proves an image came from our pipeline and wasn't swapped. Enforced at admission, it stops unapproved or tampered images from ever running."

---

## Step 6: Runtime detection with Falco (Killercoda)

Falco needs real kernel access, which is easiest on a full VM. Killercoda gives one free in the browser.

1. Go to **killercoda.com → Playgrounds → Kubernetes** and start a session.
2. Install Falco (if `helm` is missing, install it first with the official Helm install script):

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco -n falco --create-namespace --set tty=true --wait --timeout 5m
kubectl get pods -n falco
```

3. Act like an attacker:

```bash
kubectl run victim --image=nginx
kubectl wait --for=condition=Ready pod/victim --timeout=120s
kubectl exec -it victim -- sh -c "cat /etc/shadow; id"
```

4. See what Falco caught:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=50 | grep -iE "shell|sensitive"
```

**What to notice:** Falco flags the shell in the container and the read of a sensitive file, with pod, namespace, and command details.

**Optional:** try the same install in the Codespace's kind cluster to see whether it works there.

**Interview takeaway:** "Runtime detection catches what got past build and admission. In production I'd use Falco, GuardDuty Runtime Monitoring, Prisma Defender, or the Wiz Sensor, and send alerts to the SIEM."

---helm 

## Step 7: Clean up

```bash
kind delete cluster --name lab
docker rm -f registry
```

Then **stop** the Codespace (GitHub → Codespaces → ⋯ → Stop). **Delete** it when the lab is finished; stopped Codespaces still use storage quota.

---

## My notes

| Step | What surprised me / what broke | How I fixed it |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
