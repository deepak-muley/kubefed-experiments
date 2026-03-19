#!/usr/bin/env bash
# Download kubefedctl from kubernetes-retired/kubefed releases.
# Usage: ./download-kubefedctl.sh [version] [output-dir]
# Example: ./download-kubefedctl.sh v0.9.2 ./bin

set -o errexit
set -o nounset
set -o pipefail

VERSION="${1:-v0.9.2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/../bin}"
RELEASE_URL="https://github.com/kubernetes-retired/kubefed/releases/download/${VERSION}"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "${ARCH}" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) ARCH="amd64" ;;
esac

# v0.9.2 only has darwin-amd64 and linux-amd64; use amd64 for arm64 (Rosetta on Mac)
if [[ "${OS}" == "darwin" && "${ARCH}" == "arm64" ]]; then
  ARCH="amd64"
fi

VER="${VERSION#v}"
TARBALL="kubefedctl-${VER}-${OS}-${ARCH}.tgz"
DOWNLOAD_URL="${RELEASE_URL}/${TARBALL}"

echo "Downloading kubefedctl ${VERSION} for ${OS}-${ARCH}..."
echo "  URL: ${DOWNLOAD_URL}"
echo "  Output: ${OUTPUT_DIR}"
echo ""

mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

if [[ -f "${TARBALL}" ]]; then
  echo "Tarball already exists, skipping download."
else
  curl -sSL -o "${TARBALL}" "${DOWNLOAD_URL}" || {
    echo "Failed to download. v0.9.2 has darwin-amd64 and linux-amd64 only."
    echo "For darwin-arm64 (M1/M2), darwin-amd64 may run via Rosetta."
    exit 1
  }
fi

tar -xzf "${TARBALL}"
chmod +x kubefedctl 2>/dev/null || true
KUBEFEDCTL_PATH="$(cd "${OUTPUT_DIR}" && pwd)/kubefedctl"
echo ""
echo "kubefedctl installed at: ${KUBEFEDCTL_PATH}"
"${KUBEFEDCTL_PATH}" version 2>/dev/null || true
echo ""
echo "Use with: export KUBEFEDCTL_PATH=${KUBEFEDCTL_PATH}"
