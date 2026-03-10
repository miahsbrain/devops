#!/bin/bash
# =============================================================================
# Deploy: Service 5 — Notifications (Cloud Run)
# Builds the Docker image, pushes to Artifact Registry, deploys to Cloud Run
# with internal ingress and Direct VPC Egress so it can call back to GKE
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIG
# =============================================================================
export PROJECT_ID="secure-devops-setup"
export REGION="us-central1"
export ARTIFACT_REPO="prod-repo"
export SERVICE_NAME="service-5-notifications-cloudrun"
export IMAGE_TAG="${1:-latest}"

export VPC_NAME="internal-mesh-vpc"
export SUBNET_NAME="internal-mesh-subnet"

export IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

# Internal Nginx DNS — used by this Cloud Run service to call back to Service 4 (GKE)
# *.k8s.api.internal resolves to the internal Nginx IP (10.10.1.51) via Cloud DNS
export PAYMENTS_API_CALLBACK_URL="http://service-4-payments-api.k8s.api.internal"

# =============================================================================
# HELPERS
# =============================================================================
info()    { echo -e "\n\033[1;34m[${SERVICE_NAME}]\033[0m $1"; }
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
# STEP 4: Deploy to Cloud Run
# --ingress=internal           → Only reachable from VPC (Internal ALB), not public internet
# --vpc-egress=all-traffic     → Routes all outbound traffic through VPC so it can
#                                reach GKE internal services via Cloud DNS
# --network / --subnet         → Attaches Cloud Run to your VPC for Direct VPC Egress
# --set-env-vars               → Passes internal DNS URLs as environment variables
# =============================================================================
info "Deploying to Cloud Run with internal ingress and Direct VPC Egress..."
gcloud run deploy "${SERVICE_NAME}" \
  --image="${IMAGE_PATH}" \
  --region="${REGION}" \
  --ingress=internal \
  --vpc-egress=all-traffic \
  --network="${VPC_NAME}" \
  --subnet="${SUBNET_NAME}" \
  --no-allow-unauthenticated \
  --set-env-vars="PAYMENTS_API_CALLBACK_URL=${PAYMENTS_API_CALLBACK_URL}" \
  --min-instances=0 \
  --max-instances=5 \
  --memory=256Mi \
  --cpu=1 \
  --project="${PROJECT_ID}"

success "Service 5 (Notifications Cloud Run) deployed successfully."
echo ""
echo "  Image          : ${IMAGE_PATH}"
echo "  Ingress        : internal only (not reachable from public internet)"
echo "  VPC Egress     : all-traffic (can call GKE services internally)"
echo "  Internal DNS   : http://service-5-notifications-cloudrun.api.internal"
echo "  Callback URL   : ${PAYMENTS_API_CALLBACK_URL}/notification-callback"
