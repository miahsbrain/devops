#!/usr/bin/env bash
# =============================================================
# deploy.sh — Service B (Business Logic)
# Builds the Docker image, pushes it to GCR, and rolls out
# an updated Deployment on GKE.
#
# Usage:
#   cd services/service-b
#   bash deploy.sh
#   bash deploy.sh v1.2.0   # deploy a specific tag
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ ! -f "${ROOT_DIR}/.env" ]; then
  echo "ERROR: .env file not found at ${ROOT_DIR}/.env"
  echo "Copy .env.example to .env and fill in your values first."
  exit 1
fi

source "${ROOT_DIR}/.env"

SERVICE_NAME="service-b"
IMAGE="${IMAGE_REGISTRY}/${SERVICE_NAME}"
TAG="${1:-latest}"
FULL_IMAGE="${IMAGE}:${TAG}"

echo "============================================"
echo " Deploying: ${SERVICE_NAME}"
echo " Image:     ${FULL_IMAGE}"
echo " Cluster:   ${CLUSTER_NAME} (${REGION})"
echo "============================================"

echo ""
echo "[1/4] Configuring Docker authentication..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo ""
echo "[2/4] Building Docker image..."
docker build \
  --tag "${FULL_IMAGE}" \
  --file "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

echo ""
echo "[3/4] Pushing image to GCR..."
docker push "${FULL_IMAGE}"

echo ""
echo "[4/4] Deploying to GKE..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone "${ZONE}" \
  --project "${PROJECT_ID}" \
  --quiet

sed "s|IMAGE_PLACEHOLDER|${FULL_IMAGE}|g" \
  "${ROOT_DIR}/k8s/service-b/deployment.yaml" \
  | kubectl apply -f - --namespace "${K8S_NAMESPACE}"

kubectl rollout status deployment/"${SERVICE_NAME}" \
  --namespace "${K8S_NAMESPACE}" \
  --timeout=120s

echo ""
echo "✓ ${SERVICE_NAME} deployed successfully"
echo "  Image: ${FULL_IMAGE}"
