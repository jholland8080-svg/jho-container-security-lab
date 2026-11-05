#!/usr/bin/env bash
# Installs the lab tools inside the Codespace. Runs once when the Codespace is created.
set -euo pipefail

KIND_VERSION="v0.24.0"
TRIVY_VERSION="0.75.0"
TRIVY_SHA256="c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f"
COSIGN_VERSION="v2.4.1"

echo "==> Installing kind ${KIND_VERSION}"
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
sudo install -m 0755 /tmp/kind /usr/local/bin/kind

echo "==> Installing Trivy ${TRIVY_VERSION} (checksum verified)"
curl -fsSLo /tmp/trivy.tar.gz \
  "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
echo "${TRIVY_SHA256}  /tmp/trivy.tar.gz" | sha256sum -c -
tar -xzf /tmp/trivy.tar.gz -C /tmp trivy
sudo install -m 0755 /tmp/trivy /usr/local/bin/trivy

echo "==> Installing cosign ${COSIGN_VERSION}"
curl -fsSLo /tmp/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
sudo install -m 0755 /tmp/cosign /usr/local/bin/cosign

echo "==> Tool versions"
kind version
trivy --version | head -1
cosign version 2>/dev/null | grep GitVersion || true
kubectl version --client
helm version --short

echo "==> Setup done. Open README.md and start at Step 1."
