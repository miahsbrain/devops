#!/bin/bash
# =============================================================================
# Teardown: Internal Service Mesh — GKE + Cloud Run
# Project: secure-devops-setup
# =============================================================================
# Usage:
#   chmod +x teardown-internal-mesh.sh
#   ./teardown-internal-mesh.sh
#
# This script destroys everything created by setup-internal-mesh.sh
# in reverse order to respect dependencies.
# =============================================================================

set -euo pipefail

# =============================================================================
# ENVIRONMENT VARIABLES — Must match setup-internal-mesh.sh exactly
# =============================================================================

export PROJECT_ID="secure-devops-setup"
export REGION="us-central1"
export ZONE="us-central1-a"

# Networking
export VPC_NAME="internal-mesh-vpc"
export SUBNET_NAME="internal-mesh-subnet"
export PROXY_ONLY_SUBNET_NAME="proxy-only-subnet"

# GKE
export CLUSTER_NAME="internal-mesh-cluster"

# Load Balancer
export NEG_NAME="cloud-run-dynamic-neg"
export BACKEND_SERVICE_NAME="cloud-run-backend"
export URL_MAP_NAME="internal-lb-url-map"
export HTTP_PROXY_NAME="internal-lb-http-proxy"
export FORWARDING_RULE_NAME="internal-lb-forwarding-rule"
export ALB_IP_NAME="internal-alb-static-ip"

# Nginx
export NGINX_IP_NAME="nginx-ingress-static-ip"

# DNS
export DNS_ZONE_NAME="internal-api-zone"

# Cloud NAT
export ROUTER_NAME="internal-mesh-router"
export NAT_NAME="internal-mesh-nat"

# Cloud Run sample service
export SAMPLE_SERVICE="hello-service"

# =============================================================================
# HELPERS
# =============================================================================

info() { echo -e "\n\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

# Safely delete a resource — warns instead of failing if it doesn't exist
safe_delete() {
    "$@" 2>/dev/null && success "Deleted: ${*: -1}" || warn "Already gone or not found: ${*: -1}"
}

# =============================================================================
# CONFIRM
# =============================================================================

echo ""
echo "============================================================"
echo " WARNING: This will permanently destroy all resources"
echo " created by setup-internal-mesh.sh in project: $PROJECT_ID"
echo "============================================================"
echo ""
read -r -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Teardown cancelled."
    exit 0
fi

gcloud config set project "$PROJECT_ID"

# =============================================================================
# PHASE 1: Kubernetes Resources
# =============================================================================

info "Fetching GKE cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" 2>/dev/null || warn "Could not fetch cluster credentials — skipping kubectl teardown."

if kubectl cluster-info &>/dev/null; then

    info "Deleting wildcard Ingress rule..."
    safe_delete kubectl delete ingress cloud-run-wildcard-proxy -n default --ignore-not-found

    info "Deleting internal ALB ClusterIP service and Endpoints..."
    safe_delete kubectl delete service internal-alb -n default --ignore-not-found
    safe_delete kubectl delete endpoints internal-alb -n default --ignore-not-found

    info "Deleting nginx-internal IngressClass..."
    safe_delete kubectl delete ingressclass nginx-internal --ignore-not-found

    info "Deleting nginx-internal controller and namespace..."
    safe_delete kubectl delete namespace ingress-nginx-internal --ignore-not-found

    info "Deleting default nginx-ingress controller and namespace..."
    safe_delete kubectl delete namespace ingress-nginx --ignore-not-found

    success "Kubernetes resources deleted."

else
    warn "Cluster unreachable — skipping kubectl teardown."
fi

# =============================================================================
# PHASE 2: Cloud Run Services
# =============================================================================

info "Deleting sample Cloud Run service: $SAMPLE_SERVICE..."
safe_delete gcloud run services delete "$SAMPLE_SERVICE" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting Cloud Run job: curl-test (if exists)..."
safe_delete gcloud run jobs delete curl-test \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

success "Cloud Run resources deleted."

# =============================================================================
# PHASE 3: GKE Cluster
# =============================================================================

info "Deleting GKE cluster: $CLUSTER_NAME..."
safe_delete gcloud container clusters delete "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --quiet

success "GKE cluster deleted."

# =============================================================================
# PHASE 4: Internal Load Balancer (reverse order of creation)
# =============================================================================

info "Deleting forwarding rule: $FORWARDING_RULE_NAME..."
safe_delete gcloud compute forwarding-rules delete "$FORWARDING_RULE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting target HTTP proxy: $HTTP_PROXY_NAME..."
safe_delete gcloud compute target-http-proxies delete "$HTTP_PROXY_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting URL map: $URL_MAP_NAME..."
safe_delete gcloud compute url-maps delete "$URL_MAP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting backend service: $BACKEND_SERVICE_NAME..."
safe_delete gcloud compute backend-services delete "$BACKEND_SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting Serverless NEG: $NEG_NAME..."
safe_delete gcloud compute network-endpoint-groups delete "$NEG_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

success "Internal ALB resources deleted."

# =============================================================================
# PHASE 5: Static IPs
# =============================================================================

info "Releasing static IP: $ALB_IP_NAME..."
safe_delete gcloud compute addresses delete "$ALB_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Releasing static IP: $NGINX_IP_NAME..."
safe_delete gcloud compute addresses delete "$NGINX_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

success "Static IPs released."

# =============================================================================
# PHASE 6: DNS
# =============================================================================

info "Deleting DNS records and zone: $DNS_ZONE_NAME..."

# Delete all record sets except the default SOA and NS records
gcloud dns record-sets list \
    --zone="$DNS_ZONE_NAME" \
    --project="$PROJECT_ID" \
    --format="value(name,type)" 2>/dev/null |
    while read -r NAME TYPE; do
        if [[ "$TYPE" != "SOA" && "$TYPE" != "NS" ]]; then
            gcloud dns record-sets delete "$NAME" \
                --type="$TYPE" \
                --zone="$DNS_ZONE_NAME" \
                --project="$PROJECT_ID" \
                --quiet 2>/dev/null &&
                echo "  Deleted DNS record: $NAME ($TYPE)" ||
                warn "Could not delete DNS record: $NAME ($TYPE)"
        fi
    done

safe_delete gcloud dns managed-zones delete "$DNS_ZONE_NAME" \
    --project="$PROJECT_ID" \
    --quiet

success "DNS zone deleted."

# =============================================================================
# PHASE 7: Cloud NAT and Router
# =============================================================================

info "Deleting Cloud NAT: $NAT_NAME..."
safe_delete gcloud compute routers nats delete "$NAT_NAME" \
    --router="$ROUTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting Cloud Router: $ROUTER_NAME..."
safe_delete gcloud compute routers delete "$ROUTER_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

success "Cloud NAT and Router deleted."

# =============================================================================
# PHASE 8: Firewall Rules
# =============================================================================

info "Deleting firewall rules..."
safe_delete gcloud compute firewall-rules delete allow-internal-mesh \
    --project="$PROJECT_ID" \
    --quiet

safe_delete gcloud compute firewall-rules delete allow-proxy-to-backends \
    --project="$PROJECT_ID" \
    --quiet

success "Firewall rules deleted."

# =============================================================================
# PHASE 9: Subnets and VPC
# =============================================================================

info "Deleting proxy-only subnet: $PROXY_ONLY_SUBNET_NAME..."
safe_delete gcloud compute networks subnets delete "$PROXY_ONLY_SUBNET_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting main subnet: $SUBNET_NAME..."
safe_delete gcloud compute networks subnets delete "$SUBNET_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

info "Deleting VPC: $VPC_NAME..."
safe_delete gcloud compute networks delete "$VPC_NAME" \
    --project="$PROJECT_ID" \
    --quiet

success "VPC and subnets deleted."

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "============================================================"
echo " Teardown Complete"
echo "============================================================"
echo ""
echo " All resources for project $PROJECT_ID have been removed:"
echo "   ✓ Kubernetes resources (Ingress, Services, Endpoints)"
echo "   ✓ Nginx controllers (internal + default)"
echo "   ✓ Cloud Run services and jobs"
echo "   ✓ GKE cluster"
echo "   ✓ Internal ALB (Forwarding Rule, Proxy, URL Map, NEG)"
echo "   ✓ Static IPs"
echo "   ✓ DNS zone and records"
echo "   ✓ Cloud NAT and Router"
echo "   ✓ Firewall rules"
echo "   ✓ Subnets and VPC"
echo "============================================================"
