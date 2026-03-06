#!/usr/bin/env bash
set -euo pipefail

# deploy-runners.sh
# Installs Actions Runner Controller (ARC) v2 on AKS via Helm.
#
# Prerequisites:
#   - kubectl configured for your AKS cluster
#     (run: az aks get-credentials --resource-group <RG> --name <CLUSTER>)
#   - helm >= 3.x installed
#   - GITHUB_PAT env var set (PAT with 'repo' scope)
#   - GITHUB_OWNER and GITHUB_REPO env vars set

# ── Configuration ──────────────────────────────────────────────────────────────
ARC_CONTROLLER_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
ARC_RUNNER_SET_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
ARC_CONTROLLER_VERSION="0.9.3"
ARC_RUNNER_SET_VERSION="0.9.3"

CONTROLLER_NAMESPACE="arc-systems"
RUNNER_NAMESPACE="arc-runners"
RUNNER_RELEASE_NAME="aks-runners"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "${SCRIPT_DIR}/../helm" && pwd)"

# ── Validation ─────────────────────────────────────────────────────────────────
if [[ -z "${GITHUB_PAT:-}" ]]; then
  echo "ERROR: GITHUB_PAT environment variable is not set."
  echo "       Export your GitHub PAT with 'repo' scope:"
  echo "       export GITHUB_PAT=ghp_xxxxxxxxxxxxxxxxxxxx"
  exit 1
fi

if [[ -z "${GITHUB_OWNER:-}" || -z "${GITHUB_REPO:-}" ]]; then
  echo "ERROR: GITHUB_OWNER and GITHUB_REPO environment variables must be set."
  echo "       export GITHUB_OWNER=myorg"
  echo "       export GITHUB_REPO=myrepo"
  exit 1
fi

echo "==> Deploying ARC v2 for https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
echo "    Controller namespace : ${CONTROLLER_NAMESPACE}"
echo "    Runner namespace     : ${RUNNER_NAMESPACE}"
echo "    Runner release name  : ${RUNNER_RELEASE_NAME}"
echo ""

# ── Namespaces ─────────────────────────────────────────────────────────────────
echo "==> Creating namespaces..."
kubectl create namespace "${CONTROLLER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${RUNNER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── GitHub PAT Secret ──────────────────────────────────────────────────────────
echo "==> Creating GitHub PAT secret in namespace '${RUNNER_NAMESPACE}'..."
kubectl create secret generic github-pat-secret \
  --namespace "${RUNNER_NAMESPACE}" \
  --from-literal=github_token="${GITHUB_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── ARC Controller ─────────────────────────────────────────────────────────────
echo "==> Installing ARC controller (version ${ARC_CONTROLLER_VERSION})..."
helm upgrade --install arc-controller \
  "${ARC_CONTROLLER_CHART}" \
  --version "${ARC_CONTROLLER_VERSION}" \
  --namespace "${CONTROLLER_NAMESPACE}" \
  --values "${HELM_DIR}/arc-controller-values.yaml" \
  --wait \
  --timeout 5m

echo "    ARC controller installed."

# ── Runner Scale Set ───────────────────────────────────────────────────────────
echo "==> Installing runner scale set '${RUNNER_RELEASE_NAME}' (version ${ARC_RUNNER_SET_VERSION})..."
helm upgrade --install "${RUNNER_RELEASE_NAME}" \
  "${ARC_RUNNER_SET_CHART}" \
  --version "${ARC_RUNNER_SET_VERSION}" \
  --namespace "${RUNNER_NAMESPACE}" \
  --values "${HELM_DIR}/arc-runner-set-values.yaml" \
  --set githubConfigUrl="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}" \
  --wait \
  --timeout 5m

echo "    Runner scale set installed."

# ── Verification ───────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying deployment..."
echo ""
echo "--- ARC Controller pods (${CONTROLLER_NAMESPACE}) ---"
kubectl get pods -n "${CONTROLLER_NAMESPACE}"
echo ""
echo "--- Runner pods (${RUNNER_NAMESPACE}) ---"
kubectl get pods -n "${RUNNER_NAMESPACE}"
echo ""
echo "==> Done! Runners will appear in:"
echo "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/settings/actions/runners"
echo ""
echo "    Use in workflows with:"
echo "      runs-on: ${RUNNER_RELEASE_NAME}"
