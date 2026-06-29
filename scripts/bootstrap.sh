#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

kubectl apply -f "${REPO_ROOT}/bootstrap/root.yaml"
echo "Applied Argo CD root applications from ${REPO_ROOT}/bootstrap/root.yaml"
