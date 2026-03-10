set -euo pipefail # exit on error, undefined var, or pipe failure

# ── Load shared config ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"

if [ ! -f "${ROOT_DIR}/.env" ]; then
    echo "ERROR: .env file not found at ${ROOT_DIR}/.env"
    echo "Copy .env.example to .env and fill in your values first."
    exit 1
fi

# shellcheck source=../../.env
source "${ROOT_DIR}/.env"
# Delete GKE workloads
kubectl delete ingress external-ingress internal-ingress --namespace $K8S_NAMESPACE 2>/dev/null || true
kubectl delete ingressclass gce gce-internal 2>/dev/null || true
kubectl delete deployment service-a service-b --namespace $K8S_NAMESPACE 2>/dev/null || true
kubectl delete service service-a service-b --namespace $K8S_NAMESPACE 2>/dev/null || true

# Delete the GKE cluster entirely
gcloud container clusters delete $CLUSTER_NAME \
    --zone $ZONE \
    --project $PROJECT_ID \
    --quiet

# Delete the internal static IP
gcloud compute addresses delete $INTERNAL_IP_NAME \
    --region $REGION \
    --project $PROJECT_ID \
    --quiet

# Delete the Cloud DNS zone and its records
gcloud dns record-sets delete "$INTERNAL_GATEWAY_HOST." \
    --zone $DNS_ZONE_NAME \
    --type A \
    --project $PROJECT_ID 2>/dev/null || true

gcloud dns managed-zones delete $DNS_ZONE_NAME \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true

# Delete Artifact Registry images (keeps the repo, just clears images)
gcloud artifacts docker images delete \
    "$IMAGE_REGISTRY/service-a" --delete-tags --quiet 2>/dev/null || true
gcloud artifacts docker images delete \
    "$IMAGE_REGISTRY/service-b" --delete-tags --quiet 2>/dev/null || true
gcloud artifacts docker images delete \
    "$IMAGE_REGISTRY/service-c" --delete-tags --quiet 2>/dev/null || true

# Delete Cloud Run service if it was deployed
gcloud run services delete service-c \
    --region $REGION \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true

# Delete the VPC and related networking
gcloud compute routers nats delete devops-nat \
    --router devops-router \
    --region $REGION \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true

gcloud compute routers delete devops-router \
    --region $REGION \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true

gcloud compute firewall-rules delete allow-internal-vpc \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true

gcloud compute networks subnets delete $VPC_SUBNET \
    --region $REGION \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true

gcloud compute networks delete $VPC_NETWORK \
    --project $PROJECT_ID \
    --quiet 2>/dev/null || true
