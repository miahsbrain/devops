#!/usr/bin/env bash
# =============================================================
# deploy.sh — Service A (API Gateway)
# Builds the Docker image, pushes it to GCR, and rolls out
# an updated Deployment on GKE.
#
# Usage:
#   cd services/service-a
#   ../../scripts/load-env.sh   # or: source ../../.env
#   bash deploy.sh
# =============================================================

set -euo pipefail  # exit on error, undefined var, or pipe failure

# ── Load shared config ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ ! -f "${ROOT_DIR}/.env" ]; then
  echo "ERROR: .env file not found at ${ROOT_DIR}/.env"
  echo "Copy .env.example to .env and fill in your values first."
  exit 1
fi

# shellcheck source=../../.env
source "${ROOT_DIR}/.env"

# ── Variables ─────────────────────────────────────────────────
SERVICE_NAME="service-a"
IMAGE="${IMAGE_REGISTRY}/${SERVICE_NAME}"
TAG="${1:-latest}"                  # pass a tag as first arg, defaults to "latest"
FULL_IMAGE="${IMAGE}:${TAG}"

echo "============================================"
echo " Deploying: ${SERVICE_NAME}"
echo " Image:     ${FULL_IMAGE}"
echo " Cluster:   ${CLUSTER_NAME} (${REGION})"
echo "============================================"

# ── Step 1: Authenticate Docker with Artifact Registry ────────
echo ""
echo "[1/4] Configuring Docker authentication..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── Step 2: Build the Docker image ───────────────────────────
echo ""
echo "[2/4] Building Docker image..."
docker build \
  --tag "${FULL_IMAGE}" \
  --file "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

# ── Step 3: Push the image to Google Container Registry ───────
echo ""
echo "[3/4] Pushing image to GCR..."
docker push "${FULL_IMAGE}"

# ── Step 4: Apply Kubernetes manifests and roll out ───────────
echo ""
echo "[4/4] Deploying to GKE..."

# Make sure kubectl is pointing at the right cluster
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone "${ZONE}" \
  --project "${PROJECT_ID}" \
  --quiet

# Replace the image tag placeholder in the manifest before applying
# This ensures the cluster always pulls the exact tag we just built
sed "s|IMAGE_PLACEHOLDER|${FULL_IMAGE}|g" \
  "${ROOT_DIR}/k8s/service-a/deployment.yaml" \
  | kubectl apply -f - --namespace "${K8S_NAMESPACE}"

# Wait for the rollout to complete — fails loudly if pods crash
kubectl rollout status deployment/"${SERVICE_NAME}" \
  --namespace "${K8S_NAMESPACE}" \
  --timeout=120s

echo ""
echo "✓ ${SERVICE_NAME} deployed successfully"
echo "  Image: ${FULL_IMAGE}"
