#!/bin/bash
# =============================================================================
# Teardown: Internal Service Mesh
# Project: secure-devops-setup
#
# Deletes all resources created by setup-mesh.sh and the service deploy scripts.
# Does NOT delete the GCP project itself.
#
# Variables are kept identical to setup-mesh.sh — copy changes to both files.
#
# Usage:
#   chmod +x teardown.sh
#   ./teardown.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# ENVIRONMENT VARIABLES
# (identical to setup-mesh.sh — keep in sync)
# =============================================================================

export PROJECT_ID="secure-devops-setup"
export REGION="us-central1"
export ZONE="us-central1-a"

# --- Networking ---
export VPC_NAME="service-mesh-vpc"
export SUBNET_NAME="service-mesh-subnet"
export SUBNET_RANGE="10.10.0.0/20"
export PROXY_ONLY_SUBNET_NAME="service-mesh-proxy-only-subnet"
export PROXY_ONLY_SUBNET_RANGE="10.20.0.0/23"
export POD_RANGE_NAME="service-mesh-pod-range"
export POD_RANGE="10.30.0.0/16"
export SVC_RANGE_NAME="service-mesh-svc-range"
export SVC_RANGE="10.40.0.0/16"
export KUBE_DNS_IP="10.40.0.10"

# --- GKE ---
export CLUSTER_NAME="service-mesh-cluster"
export NODE_MACHINE_TYPE="e2-standard-2"
export NODE_COUNT=1
export MASTER_AUTHORIZED_CIDR="102.216.0.0/16"

# --- Internal ALB (Cloud Run gateway) ---
export NEG_NAME="service-mesh-cloudrun-neg"
export BACKEND_SERVICE_NAME="service-mesh-cloudrun-backend"
export URL_MAP_NAME="service-mesh-internal-lb-url-map"
export HTTP_PROXY_NAME="service-mesh-internal-lb-http-proxy"
export FORWARDING_RULE_NAME="service-mesh-internal-lb-forwarding-rule"
export ALB_IP_NAME="service-mesh-internal-alb-static-ip"
export ALB_IP_ADDRESS="10.10.1.50"
export URL_MASK="<service>.api.internal"

# --- Nginx Internal Gateway ---
export NGINX_INTERNAL_IP_NAME="service-mesh-nginx-internal-static-ip"
export NGINX_INTERNAL_IP_ADDRESS="10.10.1.51"

# --- Nginx Public Controller ---
export NGINX_PUBLIC_NAMESPACE="ingress-nginx"

# --- DNS ---
export DNS_ZONE_NAME="service-mesh-api-internal-zone"
export DNS_DOMAIN="api.internal."

# --- Cloud NAT ---
export ROUTER_NAME="service-mesh-cloud-router"
export NAT_NAME="service-mesh-cloud-nat"

# --- Artifact Registry ---
export ARTIFACT_REPO="prod-repo"

# --- Cloud Run Services ---
export CLOUDRUN_SERVICES=("service-3-inventory-cloudrun" "service-5-notifications-cloudrun")

# =============================================================================
# HELPERS
# =============================================================================

info() { echo -e "\n\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
header() { echo -e "\n\033[1;35m====== $1 ======\033[0m"; }

# Run a command and continue even if it fails (resource may already be deleted)
safe() {
    if "$@" 2>/dev/null; then
        success "Done"
    else
        warn "Skipped (already deleted or not found)"
    fi
}

# =============================================================================
# STEP 1: Cloud Run Services
# =============================================================================
header "STEP 1: Cloud Run Services"

for SERVICE in "${CLOUDRUN_SERVICES[@]}"; do
    info "Deleting Cloud Run service: ${SERVICE}..."
    safe gcloud run services delete "${SERVICE}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
done

# =============================================================================
# STEP 2: GKE Cluster
# Deletes the cluster and ALL Kubernetes resources inside it automatically
# (pods, deployments, services, ingresses, nginx controllers, gateway pod, etc.)
# =============================================================================
header "STEP 2: GKE Cluster"

info "Deleting GKE cluster: ${CLUSTER_NAME}..."
safe gcloud container clusters delete "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# STEP 3: Internal ALB Stack
# Deleted in reverse creation order — each resource depends on the next
# =============================================================================
header "STEP 3: Internal ALB Stack"

info "Deleting forwarding rule: ${FORWARDING_RULE_NAME}..."
safe gcloud compute forwarding-rules delete "${FORWARDING_RULE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting target HTTP proxy: ${HTTP_PROXY_NAME}..."
safe gcloud compute target-http-proxies delete "${HTTP_PROXY_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting URL map: ${URL_MAP_NAME}..."
safe gcloud compute url-maps delete "${URL_MAP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting backend service: ${BACKEND_SERVICE_NAME}..."
safe gcloud compute backend-services delete "${BACKEND_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting serverless NEG: ${NEG_NAME}..."
safe gcloud compute network-endpoint-groups delete "${NEG_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# STEP 4: Static IPs
# Must be released after the resources that were using them are gone
# =============================================================================
header "STEP 4: Static IPs"

info "Releasing Internal ALB static IP: ${ALB_IP_NAME} (${ALB_IP_ADDRESS})..."
safe gcloud compute addresses delete "${ALB_IP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Releasing Nginx Internal Gateway static IP: ${NGINX_INTERNAL_IP_NAME} (${NGINX_INTERNAL_IP_ADDRESS})..."
safe gcloud compute addresses delete "${NGINX_INTERNAL_IP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# STEP 5: Cloud DNS
# =============================================================================
header "STEP 5: Cloud DNS"

info "Deleting DNS record: *.${DNS_DOMAIN}..."
safe gcloud dns record-sets delete "*.${DNS_DOMAIN}" \
    --type=A \
    --zone="${DNS_ZONE_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting DNS record: *.k8s.${DNS_DOMAIN}..."
safe gcloud dns record-sets delete "*.k8s.${DNS_DOMAIN}" \
    --type=A \
    --zone="${DNS_ZONE_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting DNS managed zone: ${DNS_ZONE_NAME}..."
safe gcloud dns managed-zones delete "${DNS_ZONE_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# STEP 6: Cloud NAT & Router
# NAT must be deleted before the router that owns it
# =============================================================================
header "STEP 6: Cloud NAT & Router"

info "Deleting Cloud NAT: ${NAT_NAME}..."
safe gcloud compute routers nats delete "${NAT_NAME}" \
    --router="${ROUTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting Cloud Router: ${ROUTER_NAME}..."
safe gcloud compute routers delete "${ROUTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# STEP 7: Firewall Rules
# =============================================================================
header "STEP 7: Firewall Rules"

info "Deleting firewall rule: service-mesh-allow-internal..."
safe gcloud compute firewall-rules delete service-mesh-allow-internal \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting firewall rule: service-mesh-allow-proxy-to-backends..."
safe gcloud compute firewall-rules delete service-mesh-allow-proxy-to-backends \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# STEP 8: Subnets & VPC
# Subnets must be deleted before the VPC that contains them
# =============================================================================
header "STEP 8: Subnets & VPC"

info "Deleting proxy-only subnet: ${PROXY_ONLY_SUBNET_NAME}..."
safe gcloud compute networks subnets delete "${PROXY_ONLY_SUBNET_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting main subnet: ${SUBNET_NAME}..."
safe gcloud compute networks subnets delete "${SUBNET_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet

info "Deleting VPC: ${VPC_NAME}..."
safe gcloud compute networks delete "${VPC_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "=================================================================="
echo " Teardown Complete"
echo "=================================================================="
echo ""
echo " All service mesh resources deleted."
echo " Project '${PROJECT_ID}' still exists."
echo ""
echo " Verify nothing is left:"
echo "   gcloud compute networks list --project=${PROJECT_ID}"
echo "   gcloud container clusters list --project=${PROJECT_ID}"
echo "   gcloud run services list --region=${REGION} --project=${PROJECT_ID}"
echo "   gcloud dns managed-zones list --project=${PROJECT_ID}"
echo "   gcloud compute addresses list --project=${PROJECT_ID}"
echo "=================================================================="
