#!/bin/bash
# =============================================================================
# Deploy All Services
# Run from the infra/ folder. Calls each service's own deploy.sh in order.
#
# Usage:
#   chmod +x deploy-all.sh
#   ./deploy-all.sh           # deploys with tag: latest
#   ./deploy-all.sh v1.2.3    # deploys with a specific tag
# =============================================================================

set -euo pipefail

IMAGE_TAG="${1:-latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

header() { echo -e "\n\033[1;35m====== $1 ======\033[0m"; }
success() { echo -e "\033[1;32m[OK]\033[0m $1"; }

# Deploy GKE backends first so their DNS is live before Cloud Run comes up
header "Service 2 — Orders API (GKE)"
cd "${ROOT}/service-2-orders-api" && chmod +x deploy.sh && ./deploy.sh "${IMAGE_TAG}"

header "Service 4 — Payments API (GKE)"
cd "${ROOT}/service-4-payments-api" && chmod +x deploy.sh && ./deploy.sh "${IMAGE_TAG}"

# Cloud Run services call back to GKE — GKE must be up first
header "Service 3 — Inventory (Cloud Run)"
cd "${ROOT}/service-3-inventory-cloudrun" && chmod +x deploy.sh && ./deploy.sh "${IMAGE_TAG}"

header "Service 5 — Notifications (Cloud Run)"
cd "${ROOT}/service-5-notifications-cloudrun" && chmod +x deploy.sh && ./deploy.sh "${IMAGE_TAG}"

# Frontend last — depends on services 2 and 4 being ready
header "Service 1 — Frontend (GKE)"
cd "${ROOT}/service-1-frontend" && chmod +x deploy.sh && ./deploy.sh "${IMAGE_TAG}"

echo ""
echo "=================================================================="
echo " All services deployed. Tag: ${IMAGE_TAG}"
echo "=================================================================="
