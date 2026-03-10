#!/usr/bin/env bash
# =============================================================
# deploy.sh — Service C (Heavy Task Processor)
# Builds the Docker image, pushes it to GCR, and deploys
# a new revision to Cloud Run.
#
# Cloud Run-specific flags used here:
#   --vpc-egress=all-traffic   routes all outbound traffic through
#                              your VPC so it can reach the internal ingress
#   --min-instances=0          scales to zero when idle (saves cost)
#   --timeout=3600             allows up to 1 hour for heavy jobs
#
# Usage:
#   cd services/service-c
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

SERVICE_NAME="service-c"
IMAGE="${IMAGE_REGISTRY}/${SERVICE_NAME}"
TAG="${1:-latest}"
FULL_IMAGE="${IMAGE}:${TAG}"

echo "============================================"
echo " Deploying: ${SERVICE_NAME} → Cloud Run"
echo " Image:     ${FULL_IMAGE}"
echo " Region:    ${REGION}"
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
echo "[4/4] Deploying to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --image="${FULL_IMAGE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --network="${VPC_NETWORK}" \
  --subnet="${VPC_SUBNET}" \
  --vpc-egress=all-traffic \
  --set-env-vars="INTERNAL_GATEWAY_URL=http://${INTERNAL_GATEWAY_HOST}" \
  --min-instances=0 \
  --max-instances=10 \
  --cpu=2 \
  --memory=2Gi \
  --timeout=3600 \
  --no-allow-unauthenticated \
  --quiet

# ── Print the deployed URL so Service A knows where to call ───
DEPLOYED_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo ""
echo "✓ ${SERVICE_NAME} deployed successfully"
echo ""
echo "  Cloud Run URL: ${DEPLOYED_URL}"
echo ""
echo "  ⚠  Next step: update the Kubernetes secret in Service A"
echo "     so it knows where to find Service C."
echo ""
echo "     Run this command:"
echo "     kubectl create secret generic service-urls \\"
echo "       --from-literal=service-c-url=${DEPLOYED_URL} \\"
echo "       --namespace ${K8S_NAMESPACE} \\"
echo "       --dry-run=client -o yaml | kubectl apply -f -"
echo ""
echo "     Then restart Service A to pick up the new URL:"
echo "     kubectl rollout restart deployment/service-a --namespace ${K8S_NAMESPACE}"
