#!/bin/bash
# =============================================================================
# Deploy: Service 4 — Payments API (GKE)
# Builds the Docker image, pushes to Artifact Registry, applies K8s manifests
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIG
# =============================================================================
export PROJECT_ID="secure-devops-setup"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER_NAME="service-mesh-cluster"
export ARTIFACT_REPO="prod-repo"
export SERVICE_NAME="service-4-payments-api"
export IMAGE_TAG="${1:-latest}"

export IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

# =============================================================================
# HELPERS
# =============================================================================
info() { echo -e "\n\033[1;34m[${SERVICE_NAME}]\033[0m $1"; }
success() { echo -e "\033[1;32m[OK]\033[0m $1"; }

# =============================================================================
# STEP 1: Authenticate Docker with Artifact Registry
# =============================================================================
info "Authenticating Docker with Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# =============================================================================
# STEP 2: Build the Docker image
# =============================================================================
info "Building Docker image: ${IMAGE_PATH}..."
docker build \
    --platform linux/amd64 \
    -t "${IMAGE_PATH}" \
    .

success "Image built."

# =============================================================================
# STEP 3: Push image to Artifact Registry (prod-repo)
# =============================================================================
info "Pushing image to Artifact Registry..."
docker push "${IMAGE_PATH}"
success "Image pushed to ${IMAGE_PATH}."

# =============================================================================
# STEP 4: Get GKE cluster credentials
# =============================================================================
info "Fetching GKE cluster credentials for ${CLUSTER_NAME}..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}"

# =============================================================================
# STEP 5: Apply manifests and update image
# =============================================================================
info "Applying Kubernetes deployment manifests..."
kubectl apply -f k8s-deployment.yaml

kubectl set image deployment/service-4-payments-api-deployment \
    service-4-payments-api="${IMAGE_PATH}"

# =============================================================================
# STEP 6: Wait for rollout
# =============================================================================
info "Waiting for rollout to complete..."
kubectl rollout status deployment/service-4-payments-api-deployment --timeout=120s

success "Service 4 (Payments API) deployed successfully."
echo ""
echo "  Image : ${IMAGE_PATH}"
echo "  Internal DNS (for GKE pods)     : http://service-4-payments-api.k8s.api.internal"
echo "  Public path (via Nginx ingress) : http://NGINX_PUBLIC_IP.nip.io/api/payments"
