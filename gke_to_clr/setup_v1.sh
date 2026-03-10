#!/bin/bash
# =============================================================================
# Internal Service Mesh: GKE + Cloud Run
# Project: secure-devops-setup
# =============================================================================
# Usage:
#   chmod +x setup-internal-mesh.sh
#   ./setup-internal-mesh.sh
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - kubectl installed
#   - Helm installed (for Nginx Ingress)
# =============================================================================

set -euo pipefail

# =============================================================================
# ENVIRONMENT VARIABLES — Edit these as needed
# =============================================================================

export PROJECT_ID="secure-devops-setup"
export REGION="us-central1"
export ZONE="us-central1-a"

# Networking
export VPC_NAME="internal-mesh-vpc"
export SUBNET_NAME="internal-mesh-subnet"
export SUBNET_RANGE="10.10.0.0/20"
export PROXY_ONLY_SUBNET_NAME="proxy-only-subnet"
export PROXY_ONLY_SUBNET_RANGE="10.20.0.0/23"
export POD_RANGE_NAME="pod-range"
export POD_RANGE="10.30.0.0/16"
export SVC_RANGE_NAME="svc-range"
export SVC_RANGE="10.40.0.0/16"

# GKE
export CLUSTER_NAME="internal-mesh-cluster"
export NODE_MACHINE_TYPE="e2-standard-2"
export NODE_COUNT=1

# Load Balancer
export NEG_NAME="cloud-run-dynamic-neg"
export BACKEND_SERVICE_NAME="cloud-run-backend"
export URL_MAP_NAME="internal-lb-url-map"
export HTTP_PROXY_NAME="internal-lb-http-proxy"
export FORWARDING_RULE_NAME="internal-lb-forwarding-rule"
export ALB_IP_NAME="internal-alb-static-ip"
export ALB_IP_ADDRESS="10.10.1.50"

# Nginx
export NGINX_IP_NAME="nginx-ingress-static-ip"
export NGINX_IP_ADDRESS="10.10.1.51"

# DNS
export DNS_ZONE_NAME="internal-api-zone"
export DNS_DOMAIN="api.internal."

# Cloud NAT
export ROUTER_NAME="internal-mesh-router"
export NAT_NAME="internal-mesh-nat"

# URL Mask pattern — service name maps to Cloud Run service name
export URL_MASK="<service>.api.internal"

# Access Control
export MASTER_AUTHORIZED_CIDR="102.216.0.0/16" # Your local IP range

# =============================================================================
# HELPERS
# =============================================================================

info() { echo -e "\n\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

# =============================================================================
# PHASE 0: Project Setup
# =============================================================================

info "Setting active project to $PROJECT_ID..."
gcloud config set project "$PROJECT_ID"

info "Enabling required APIs..."
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    run.googleapis.com \
    dns.googleapis.com \
    --project="$PROJECT_ID"

success "APIs enabled."

# =============================================================================
# PHASE 1: VPC & Networking
# =============================================================================

info "Creating VPC: $VPC_NAME..."
gcloud compute networks create "$VPC_NAME" \
    --subnet-mode=custom \
    --project="$PROJECT_ID"

info "Creating main subnet: $SUBNET_NAME..."
gcloud compute networks subnets create "$SUBNET_NAME" \
    --network="$VPC_NAME" \
    --region="$REGION" \
    --range="$SUBNET_RANGE" \
    --secondary-range="$POD_RANGE_NAME=$POD_RANGE","$SVC_RANGE_NAME=$SVC_RANGE" \
    --enable-private-ip-google-access \
    --project="$PROJECT_ID"

info "Creating proxy-only subnet (required for Internal ALB)..."
gcloud compute networks subnets create "$PROXY_ONLY_SUBNET_NAME" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --network="$VPC_NAME" \
    --region="$REGION" \
    --range="$PROXY_ONLY_SUBNET_RANGE" \
    --project="$PROJECT_ID"

info "Creating Cloud Router: $ROUTER_NAME..."
gcloud compute routers create "$ROUTER_NAME" \
    --network="$VPC_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID"

info "Creating Cloud NAT: $NAT_NAME..."
gcloud compute routers nats create "$NAT_NAME" \
    --router="$ROUTER_NAME" \
    --region="$REGION" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --project="$PROJECT_ID"

info "Creating firewall rule to allow internal traffic..."
gcloud compute firewall-rules create allow-internal-mesh \
    --network="$VPC_NAME" \
    --allow=tcp,udp,icmp \
    --source-ranges="$SUBNET_RANGE","$POD_RANGE","$SVC_RANGE" \
    --project="$PROJECT_ID"

info "Creating firewall rule to allow proxy-only subnet to reach backends..."
gcloud compute firewall-rules create allow-proxy-to-backends \
    --network="$VPC_NAME" \
    --allow=tcp:80,tcp:443,tcp:8080 \
    --source-ranges="$PROXY_ONLY_SUBNET_RANGE" \
    --project="$PROJECT_ID"

success "VPC and networking ready."

# =============================================================================
# PHASE 2: GKE Cluster
# =============================================================================

info "Creating GKE zonal cluster: $CLUSTER_NAME..."
gcloud container clusters create "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --num-nodes="$NODE_COUNT" \
    --machine-type="$NODE_MACHINE_TYPE" \
    --network="$VPC_NAME" \
    --subnetwork="$SUBNET_NAME" \
    --cluster-secondary-range-name="$POD_RANGE_NAME" \
    --services-secondary-range-name="$SVC_RANGE_NAME" \
    --enable-private-nodes \
    --master-ipv4-cidr="172.16.0.0/28" \
    --enable-ip-alias \
    --enable-master-authorized-networks \
    --master-authorized-networks="$MASTER_AUTHORIZED_CIDR" \
    --project="$PROJECT_ID"

info "Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID"

success "GKE cluster ready."

# =============================================================================
# PHASE 3: Reserve Static IPs
# =============================================================================

info "Reserving static internal IP for Internal ALB: $ALB_IP_ADDRESS..."
gcloud compute addresses create "$ALB_IP_NAME" \
    --region="$REGION" \
    --subnet="$SUBNET_NAME" \
    --addresses="$ALB_IP_ADDRESS" \
    --purpose=GCE_ENDPOINT \
    --project="$PROJECT_ID"

info "Reserving static internal IP for Nginx Ingress: $NGINX_IP_ADDRESS..."
gcloud compute addresses create "$NGINX_IP_NAME" \
    --region="$REGION" \
    --subnet="$SUBNET_NAME" \
    --addresses="$NGINX_IP_ADDRESS" \
    --purpose=GCE_ENDPOINT \
    --project="$PROJECT_ID"

success "Static IPs reserved."

# =============================================================================
# PHASE 4: Internal Application Load Balancer (Cloud Run Gateway)
# =============================================================================

info "Creating Serverless NEG with URL mask: $URL_MASK..."
gcloud compute network-endpoint-groups create "$NEG_NAME" \
    --region="$REGION" \
    --network-endpoint-type=serverless \
    --cloud-run-url-mask="$URL_MASK" \
    --project="$PROJECT_ID"

info "Creating backend service: $BACKEND_SERVICE_NAME..."
gcloud compute backend-services create "$BACKEND_SERVICE_NAME" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --protocol=HTTP \
    --region="$REGION" \
    --project="$PROJECT_ID"

info "Attaching NEG to backend service..."
gcloud compute backend-services add-backend "$BACKEND_SERVICE_NAME" \
    --network-endpoint-group="$NEG_NAME" \
    --network-endpoint-group-region="$REGION" \
    --region="$REGION" \
    --project="$PROJECT_ID"

info "Creating URL map: $URL_MAP_NAME..."
gcloud compute url-maps create "$URL_MAP_NAME" \
    --default-service="$BACKEND_SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID"

info "Creating target HTTP proxy: $HTTP_PROXY_NAME..."
gcloud compute target-http-proxies create "$HTTP_PROXY_NAME" \
    --url-map="$URL_MAP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID"

info "Creating forwarding rule: $FORWARDING_RULE_NAME..."
gcloud compute forwarding-rules create "$FORWARDING_RULE_NAME" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --network="$VPC_NAME" \
    --subnet="$SUBNET_NAME" \
    --address="$ALB_IP_NAME" \
    --target-http-proxy="$HTTP_PROXY_NAME" \
    --target-http-proxy-region="$REGION" \
    --ports=80 \
    --region="$REGION" \
    --project="$PROJECT_ID"

success "Internal ALB ready at $ALB_IP_ADDRESS."

# =============================================================================
# PHASE 5: Nginx Ingress Controller (GKE via kubectl)
# =============================================================================

info "Installing Nginx Ingress Controller via kubectl..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

info "Waiting for Nginx controller pods to be ready..."
kubectl rollout status deployment ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=120s

info "Patching Nginx service to use static internal IP and internal LB annotation..."
kubectl patch svc ingress-nginx-controller \
    -n ingress-nginx \
    --type='merge' \
    -p "{
    \"metadata\": {
      \"annotations\": {
        \"networking.gke.io/load-balancer-type\": \"Internal\",
        \"networking.gke.io/subnet-name\": \"${SUBNET_NAME}\"
      }
    },
    \"spec\": {
      \"loadBalancerIP\": \"${NGINX_IP_ADDRESS}\"
    }
  }"

success "Nginx Ingress installed with static internal IP $NGINX_IP_ADDRESS."

# =============================================================================
# PHASE 6: Internal Service pointing to ALB + Wildcard Ingress Rule
# =============================================================================
# We use a ClusterIP Service + Endpoints object to represent the Internal ALB
# inside the cluster. Traffic goes directly to the ALB IP over the VPC —
# it never leaves the internal network.
# =============================================================================

info "Creating internal ClusterIP service and Endpoints for ALB..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: internal-alb
  namespace: default
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: internal-alb
  namespace: default
subsets:
- addresses:
  - ip: ${ALB_IP_ADDRESS}
  ports:
  - port: 80
EOF

info "Creating wildcard Ingress rule for *.api.internal → internal ALB service..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cloud-run-wildcard-proxy
  namespace: default
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/upstream-vhost: "\$host"
spec:
  rules:
  - host: "*.api.internal"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: internal-alb
            port:
              number: 80
EOF

success "Internal ALB service, Endpoints, and wildcard Ingress rule applied."

# =============================================================================
# PHASE 7: Cloud DNS Private Zone
# =============================================================================

info "Creating private DNS zone: $DNS_ZONE_NAME..."
gcloud dns managed-zones create "$DNS_ZONE_NAME" \
    --description="Internal service mesh DNS zone" \
    --dns-name="$DNS_DOMAIN" \
    --networks="$VPC_NAME" \
    --visibility=private \
    --project="$PROJECT_ID"

info "Adding wildcard A record: *.api.internal → ALB ($ALB_IP_ADDRESS)..."
gcloud dns record-sets transaction start --zone="$DNS_ZONE_NAME" --project="$PROJECT_ID"
gcloud dns record-sets transaction add "$ALB_IP_ADDRESS" \
    --name="*.api.internal." \
    --ttl=300 \
    --type=A \
    --zone="$DNS_ZONE_NAME" \
    --project="$PROJECT_ID"
gcloud dns record-sets transaction execute --zone="$DNS_ZONE_NAME" --project="$PROJECT_ID"

info "Adding wildcard A record: *.k8s.api.internal → Nginx ($NGINX_IP_ADDRESS)..."
gcloud dns record-sets transaction start --zone="$DNS_ZONE_NAME" --project="$PROJECT_ID"
gcloud dns record-sets transaction add "$NGINX_IP_ADDRESS" \
    --name="*.k8s.api.internal." \
    --ttl=300 \
    --type=A \
    --zone="$DNS_ZONE_NAME" \
    --project="$PROJECT_ID"
gcloud dns record-sets transaction execute --zone="$DNS_ZONE_NAME" --project="$PROJECT_ID"

success "DNS zone and records created."

# =============================================================================
# PHASE 8: Sample Cloud Run Service (to verify setup)
# =============================================================================

info "Deploying sample Cloud Run service: hello-service..."
gcloud run deploy hello-service \
    --image=us-docker.pkg.dev/cloudrun/container/hello \
    --region="$REGION" \
    --ingress=internal-and-cloud-load-balancing \
    --vpc-egress=all-traffic \
    --network="$VPC_NAME" \
    --subnet="$SUBNET_NAME" \
    --no-allow-unauthenticated \
    --project="$PROJECT_ID"

success "Sample Cloud Run service deployed."

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "============================================================"
echo " Internal Service Mesh Setup Complete"
echo "============================================================"
echo ""
echo " Project ID   : $PROJECT_ID"
echo " Region       : $REGION"
echo " Zone         : $ZONE"
echo " VPC          : $VPC_NAME"
echo " GKE Cluster  : $CLUSTER_NAME"
echo ""
echo " Internal ALB IP  : $ALB_IP_ADDRESS"
echo " Nginx Ingress IP : $NGINX_IP_ADDRESS"
echo ""
echo " Routing:"
echo "   *.api.internal      → ALB → Cloud Run (via URL Mask)"
echo "   *.k8s.api.internal  → Nginx → GKE Pods"
echo ""
echo " To add a new Cloud Run service (e.g. 'payments'):"
echo "   gcloud run deploy payments \\"
echo "     --ingress=internal-and-cloud-load-balancing \\"
echo "     --vpc-egress=all-traffic \\"
echo "     --network=$VPC_NAME \\"
echo "     --subnet=$SUBNET_NAME \\"
echo "     --region=$REGION"
echo ""
echo "   It will be instantly reachable at: http://payments.api.internal"
echo "============================================================"
