#!/bin/bash
# =============================================================================
# Infrastructure Setup: Internal Service Mesh
# Project: secure-devops-setup
# =============================================================================
# Sets up the full VPC, GKE cluster, Internal ALB, Nginx gateway pod,
# DNS, and all Kubernetes resources needed for the 5-service mesh demo.
#
# Service Map:
#   Service 1 (Frontend, GKE)            — public facing, calls Service 2 and 4
#   Service 2 (Orders API, GKE)          — calls Service 3 (Cloud Run), receives callbacks
#   Service 3 (Inventory, Cloud Run)     — internal only, calls back to Service 2
#   Service 4 (Payments API, GKE)        — calls Service 5 (Cloud Run), receives callbacks
#   Service 5 (Notifications, Cloud Run) — internal only, calls back to Service 4
#
# Usage:
#   chmod +x setup-mesh.sh
#   ./setup-mesh.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# ENVIRONMENT VARIABLES
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
# Secondary ranges for GKE pods and services
export POD_RANGE_NAME="service-mesh-pod-range"
export POD_RANGE="10.30.0.0/16"
export SVC_RANGE_NAME="service-mesh-svc-range"
export SVC_RANGE="10.40.0.0/16"

# --- GKE ---
export CLUSTER_NAME="service-mesh-cluster"
export NODE_MACHINE_TYPE="e2-standard-2"
export NODE_COUNT=1
# Whitelist your local IP range so you can run kubectl from your machine
export MASTER_AUTHORIZED_CIDR="102.216.0.0/16"

# --- Internal ALB (Cloud Run gateway) ---
export NEG_NAME="service-mesh-cloudrun-neg"
export BACKEND_SERVICE_NAME="service-mesh-cloudrun-backend"
export URL_MAP_NAME="service-mesh-internal-lb-url-map"
export HTTP_PROXY_NAME="service-mesh-internal-lb-http-proxy"
export FORWARDING_RULE_NAME="service-mesh-internal-lb-forwarding-rule"
export ALB_IP_NAME="service-mesh-internal-alb-static-ip"
export ALB_IP_ADDRESS="10.10.1.50"
# URL mask: service name in hostname maps directly to Cloud Run service name
# e.g. service-3-inventory-cloudrun.api.internal → Cloud Run: service-3-inventory-cloudrun
export URL_MASK="<service>.api.internal"

# --- Nginx Internal Gateway (Cloud Run → GKE proxy pod) ---
# This is a plain nginx pod — NOT the Nginx Ingress Controller.
# We own the full nginx.conf so there are no conflicts with auto-generated config.
export NGINX_INTERNAL_IP_NAME="service-mesh-nginx-internal-static-ip"
export NGINX_INTERNAL_IP_ADDRESS="10.10.1.51"
# kube-dns ClusterIP — used by nginx to resolve *.svc.cluster.local at request time.
# Find with: kubectl get svc kube-dns -n kube-system
# Default GKE value for SVC_RANGE starting at 10.40.0.0/16 is 10.40.0.10
export KUBE_DNS_IP="10.40.0.10"

# --- Nginx Public Controller (public internet → GKE) ---
# Using the default ingress-nginx namespace from the upstream manifest
export NGINX_PUBLIC_NAMESPACE="ingress-nginx"

# --- DNS ---
export DNS_ZONE_NAME="service-mesh-api-internal-zone"
export DNS_DOMAIN="api.internal."

# --- Cloud NAT (for image pulls and external API calls) ---
export ROUTER_NAME="service-mesh-cloud-router"
export NAT_NAME="service-mesh-cloud-nat"

# --- Artifact Registry ---
export ARTIFACT_REPO="prod-repo"

# =============================================================================
# HELPERS
# =============================================================================

info()    { echo -e "\n\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m $1"; }
header()  { echo -e "\n\033[1;35m====== $1 ======\033[0m"; }

# =============================================================================
# PHASE 0: Project Setup & API Enablement
# =============================================================================
header "PHASE 0: Project Setup"

info "Setting active GCP project to ${PROJECT_ID}..."
gcloud config set project "${PROJECT_ID}"

info "Enabling required GCP APIs..."
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    run.googleapis.com \
    dns.googleapis.com \
    artifactregistry.googleapis.com \
    --project="${PROJECT_ID}"

success "APIs enabled."

# =============================================================================
# PHASE 1: VPC & Networking
# =============================================================================
header "PHASE 1: VPC & Networking"

info "Creating VPC: ${VPC_NAME}..."
gcloud compute networks create "${VPC_NAME}" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"

info "Creating main subnet: ${SUBNET_NAME} (${SUBNET_RANGE})..."
info "  Includes secondary ranges for GKE pods (${POD_RANGE}) and services (${SVC_RANGE})"
gcloud compute networks subnets create "${SUBNET_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="${SUBNET_RANGE}" \
    --secondary-range="${POD_RANGE_NAME}=${POD_RANGE}","${SVC_RANGE_NAME}=${SVC_RANGE}" \
    --enable-private-ip-google-access \
    --project="${PROJECT_ID}"

info "Creating proxy-only subnet: ${PROXY_ONLY_SUBNET_NAME}..."
info "  Required by Internal ALB to run its Envoy proxy fleet"
gcloud compute networks subnets create "${PROXY_ONLY_SUBNET_NAME}" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="${PROXY_ONLY_SUBNET_RANGE}" \
    --project="${PROJECT_ID}"

info "Creating Cloud Router: ${ROUTER_NAME}..."
gcloud compute routers create "${ROUTER_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

info "Creating Cloud NAT: ${NAT_NAME}..."
info "  Allows private GKE nodes to pull images and reach external APIs"
gcloud compute routers nats create "${NAT_NAME}" \
    --router="${ROUTER_NAME}" \
    --region="${REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --project="${PROJECT_ID}"

info "Creating firewall rule: allow internal VPC traffic..."
gcloud compute firewall-rules create service-mesh-allow-internal \
    --network="${VPC_NAME}" \
    --allow=tcp,udp,icmp \
    --source-ranges="${SUBNET_RANGE}","${POD_RANGE}","${SVC_RANGE}" \
    --description="Allow all internal traffic between GKE pods, nodes, and VPC resources" \
    --project="${PROJECT_ID}"

info "Creating firewall rule: allow Internal ALB proxy subnet to reach GKE backends..."
gcloud compute firewall-rules create service-mesh-allow-proxy-to-backends \
    --network="${VPC_NAME}" \
    --allow=tcp:80,tcp:443,tcp:8080 \
    --source-ranges="${PROXY_ONLY_SUBNET_RANGE}" \
    --description="Allow Internal ALB Envoy proxies to reach GKE and Cloud Run backends" \
    --project="${PROJECT_ID}"

success "VPC, subnets, NAT, and firewall rules ready."

# =============================================================================
# PHASE 2: GKE Cluster
# =============================================================================
header "PHASE 2: GKE Cluster"

info "Creating private zonal GKE cluster: ${CLUSTER_NAME}..."
info "  Zone: ${ZONE} | Nodes: ${NODE_COUNT} | Machine: ${NODE_MACHINE_TYPE}"
info "  Private nodes — no public IPs on worker nodes"
info "  Master authorized networks: ${MASTER_AUTHORIZED_CIDR}"
gcloud container clusters create "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --num-nodes="${NODE_COUNT}" \
    --machine-type="${NODE_MACHINE_TYPE}" \
    --network="${VPC_NAME}" \
    --subnetwork="${SUBNET_NAME}" \
    --cluster-secondary-range-name="${POD_RANGE_NAME}" \
    --services-secondary-range-name="${SVC_RANGE_NAME}" \
    --enable-private-nodes \
    --master-ipv4-cidr="172.16.0.0/28" \
    --enable-ip-alias \
    --enable-master-authorized-networks \
    --master-authorized-networks="${MASTER_AUTHORIZED_CIDR}" \
    --project="${PROJECT_ID}"

info "Fetching cluster credentials for kubectl..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}"

success "GKE cluster ready."

# =============================================================================
# PHASE 3: Reserve Static IPs
# =============================================================================
header "PHASE 3: Static IP Reservation"

info "Reserving static internal IP for Internal ALB: ${ALB_IP_ADDRESS}..."
info "  This IP is the single entry point for all Cloud Run services (via URL mask)"
gcloud compute addresses create "${ALB_IP_NAME}" \
    --region="${REGION}" \
    --subnet="${SUBNET_NAME}" \
    --addresses="${ALB_IP_ADDRESS}" \
    --purpose=GCE_ENDPOINT \
    --project="${PROJECT_ID}"

info "Reserving static internal IP for Nginx Internal Gateway: ${NGINX_INTERNAL_IP_ADDRESS}..."
info "  This IP is the entry point for Cloud Run → GKE callbacks"
gcloud compute addresses create "${NGINX_INTERNAL_IP_NAME}" \
    --region="${REGION}" \
    --subnet="${SUBNET_NAME}" \
    --addresses="${NGINX_INTERNAL_IP_ADDRESS}" \
    --purpose=GCE_ENDPOINT \
    --project="${PROJECT_ID}"

success "Static IPs reserved."

# =============================================================================
# PHASE 4: Internal Application Load Balancer
# Purpose: Receives requests for *.api.internal and routes to Cloud Run
#          using URL masking — no config changes needed per new service
# =============================================================================
header "PHASE 4: Internal Application Load Balancer (Cloud Run Gateway)"

info "Creating Serverless NEG with URL mask: ${URL_MASK}..."
info "  The URL mask extracts the service name from the hostname automatically"
info "  e.g. service-3-inventory-cloudrun.api.internal → Cloud Run: service-3-inventory-cloudrun"
gcloud compute network-endpoint-groups create "${NEG_NAME}" \
    --region="${REGION}" \
    --network-endpoint-type=serverless \
    --cloud-run-url-mask="${URL_MASK}" \
    --project="${PROJECT_ID}"

info "Creating backend service: ${BACKEND_SERVICE_NAME}..."
gcloud compute backend-services create "${BACKEND_SERVICE_NAME}" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --protocol=HTTP \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

info "Attaching Serverless NEG to backend service..."
gcloud compute backend-services add-backend "${BACKEND_SERVICE_NAME}" \
    --network-endpoint-group="${NEG_NAME}" \
    --network-endpoint-group-region="${REGION}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

info "Creating URL map: ${URL_MAP_NAME}..."
gcloud compute url-maps create "${URL_MAP_NAME}" \
    --default-service="${BACKEND_SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

info "Creating target HTTP proxy: ${HTTP_PROXY_NAME}..."
gcloud compute target-http-proxies create "${HTTP_PROXY_NAME}" \
    --url-map="${URL_MAP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

info "Creating forwarding rule: ${FORWARDING_RULE_NAME} → ${ALB_IP_ADDRESS}:80..."
info "  This is the actual private IP that DNS points to — the 'front door' of the ALB"
info "  NOTE: --target-http-proxy-region is required here (regional proxy, not global)"
gcloud compute forwarding-rules create "${FORWARDING_RULE_NAME}" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --network="${VPC_NAME}" \
    --subnet="${SUBNET_NAME}" \
    --address="${ALB_IP_NAME}" \
    --target-http-proxy="${HTTP_PROXY_NAME}" \
    --target-http-proxy-region="${REGION}" \
    --ports=80 \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

success "Internal ALB ready at ${ALB_IP_ADDRESS}."

# =============================================================================
# PHASE 5: Nginx Internal Gateway (proxy pod)
# Purpose: Receives *.k8s.api.internal traffic from Cloud Run and routes
#          dynamically to the correct GKE ClusterIP service by hostname.
#
# Why a plain nginx pod instead of Nginx Ingress Controller?
#   The Ingress Controller auto-generates its own nginx.conf including its own
#   proxy_pass, resolver, and location blocks. Any attempt to override these
#   via annotations causes duplicate directive errors. A plain nginx pod gives
#   us full control over the config with no conflicts.
#
# How dynamic routing works:
#   1. Cloud Run calls http://service-2-orders-api.k8s.api.internal
#   2. DNS resolves *.k8s.api.internal → 10.10.1.51 (this pod's LB IP)
#   3. Nginx map{} extracts "service-2-orders-api" from the Host header
#   4. Appends "-cluster-ip" → "service-2-orders-api-cluster-ip"
#   5. proxy_pass to service-2-orders-api-cluster-ip.default.svc.cluster.local
#   6. CoreDNS (10.40.0.10) resolves that to the ClusterIP → pod
#
# CI-friendly: deploying a new GKE service = zero changes here.
# =============================================================================
header "PHASE 5: Nginx Internal Gateway (proxy pod)"

info "Deploying nginx-internal-gateway ConfigMap, Deployment, and LoadBalancer Service..."
info "  Resolver IP: ${KUBE_DNS_IP} (kube-dns ClusterIP)"
info "  Static IP: ${NGINX_INTERNAL_IP_ADDRESS}"

cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-internal-gateway-config
  namespace: default
data:
  nginx.conf: |
    worker_processes auto;
    events {
      worker_connections 1024;
    }
    http {
      # CoreDNS IP — required for resolving \$variables in proxy_pass at request time.
      # Using the IP directly (not the hostname) avoids a chicken-and-egg DNS problem
      # where nginx itself would need DNS to find the DNS server.
      resolver ${KUBE_DNS_IP} valid=10s ipv6=off;
      resolver_timeout 5s;

      # Extract service name from *.k8s.api.internal hostname and append -cluster-ip
      # e.g. service-2-orders-api.k8s.api.internal → service-2-orders-api-cluster-ip
      # This matches the actual Kubernetes ClusterIP service naming convention.
      map \$host \$service_name {
        ~^(?<svc>[^.]+)\.k8s\.api\.internal\$  \${svc}-cluster-ip;
        default                                  "";
      }

      server {
        listen 80;

        # Restrict to RFC-1918 private ranges only — belt-and-suspenders security
        # even though the LB is already internal-only
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        deny all;

        location / {
          if (\$service_name = "") {
            return 400 "Cannot resolve service from hostname: \$host\n";
          }
          set \$upstream http://\$service_name.default.svc.cluster.local;
          proxy_pass \$upstream;
          proxy_set_header Host \$service_name.default.svc.cluster.local;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_connect_timeout 10s;
          proxy_read_timeout 60s;
          proxy_send_timeout 60s;
        }

        location /healthz {
          allow all;
          return 200 "ok\n";
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-internal-gateway
  namespace: default
  labels:
    app: nginx-internal-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-internal-gateway
  template:
    metadata:
      labels:
        app: nginx-internal-gateway
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
          livenessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
      volumes:
        - name: config
          configMap:
            name: nginx-internal-gateway-config
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-internal-gateway
  namespace: default
  annotations:
    networking.gke.io/load-balancer-type: "Internal"
    networking.gke.io/subnet-name: "${SUBNET_NAME}"
spec:
  type: LoadBalancer
  loadBalancerIP: ${NGINX_INTERNAL_IP_ADDRESS}
  selector:
    app: nginx-internal-gateway
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
EOF

info "Waiting for nginx-internal-gateway to be ready..."
kubectl rollout status deployment nginx-internal-gateway -n default --timeout=120s

info "Waiting for internal gateway to get IP ${NGINX_INTERNAL_IP_ADDRESS}..."
for i in {1..12}; do
    ASSIGNED_IP=$(kubectl get svc nginx-internal-gateway -n default \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ "${ASSIGNED_IP}" == "${NGINX_INTERNAL_IP_ADDRESS}" ]]; then
        break
    fi
    warn "Still waiting for IP... attempt ${i}/12"
    sleep 10
done

success "Nginx internal gateway ready at ${NGINX_INTERNAL_IP_ADDRESS}."

 directly — no renaming or patching required"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

info "Waiting for nginx controller to be ready..."
kubectl rollout status deployment ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=180s

info "Waiting for public Nginx to get a public IP..."
sleep 30
PUBLIC_NGINX_IP=""
for i in {1..12}; do
    PUBLIC_NGINX_IP=$(kubectl get svc ingress-nginx-controller \
        -n ingress-nginx \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${PUBLIC_NGINX_IP}" ]]; then
        break
    fi
    warn "Still waiting for public IP... attempt ${i}/12"
    sleep 10
done

success "Nginx public controller ready."
if [[ -n "${PUBLIC_NGINX_IP}" ]]; then
    success "Public IP: ${PUBLIC_NGINX_IP}"
    success "Access your services at: http://${PUBLIC_NGINX_IP}.nip.io"
else
    warn "Public IP not yet assigned. Run: kubectl get svc ingress-nginx-controller -n ingress-nginx"
fi

# =============================================================================
# PHASE 7: Internal ALB Bridge (ClusterIP + Endpoints)
# Purpose: Makes the Internal ALB IP addressable inside Kubernetes
#          so public Ingress rules can use it as a backend for Cloud Run routes
# =============================================================================
header "PHASE 7: Internal ALB Bridge (Kubernetes ClusterIP + Endpoints)"

info "Creating ClusterIP service 'internal-alb' pointing to ALB at ${ALB_IP_ADDRESS}..."
info "  This lets Ingress rules route to Cloud Run without leaving the VPC"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: internal-alb
  namespace: default
  labels:
    role: internal-alb-bridge
  annotations:
    description: "Bridge to Internal ALB at ${ALB_IP_ADDRESS} - routes to Cloud Run via URL mask"
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
  labels:
    role: internal-alb-bridge
subsets:
  - addresses:
      - ip: ${ALB_IP_ADDRESS}
    ports:
      - port: 80
EOF

success "Internal ALB bridge ready."

# =============================================================================
# PHASE 8: Cloud DNS Private Zone
# Purpose: Name resolution for all internal services
#   *.api.internal       → Internal ALB (10.10.1.50) → Cloud Run services
#   *.k8s.api.internal   → Nginx Internal Gateway (10.10.1.51) → GKE pods
# =============================================================================
header "PHASE 8: Cloud DNS Private Zone"

info "Creating private DNS zone: ${DNS_ZONE_NAME} for domain ${DNS_DOMAIN}..."
info "  Bound to VPC ${VPC_NAME} — only resolvable from inside the VPC"
gcloud dns managed-zones create "${DNS_ZONE_NAME}" \
    --description="Private DNS zone for internal service mesh" \
    --dns-name="${DNS_DOMAIN}" \
    --networks="${VPC_NAME}" \
    --visibility=private \
    --project="${PROJECT_ID}"

info "Adding wildcard DNS record: *.api.internal → ${ALB_IP_ADDRESS} (Internal ALB)..."
gcloud dns record-sets transaction start --zone="${DNS_ZONE_NAME}" --project="${PROJECT_ID}"
gcloud dns record-sets transaction add "${ALB_IP_ADDRESS}" \
    --name="*.api.internal." \
    --ttl=300 \
    --type=A \
    --zone="${DNS_ZONE_NAME}" \
    --project="${PROJECT_ID}"
gcloud dns record-sets transaction execute --zone="${DNS_ZONE_NAME}" --project="${PROJECT_ID}"

info "Adding wildcard DNS record: *.k8s.api.internal → ${NGINX_INTERNAL_IP_ADDRESS} (Nginx Internal Gateway)..."
gcloud dns record-sets transaction start --zone="${DNS_ZONE_NAME}" --project="${PROJECT_ID}"
gcloud dns record-sets transaction add "${NGINX_INTERNAL_IP_ADDRESS}" \
    --name="*.k8s.api.internal." \
    --ttl=300 \
    --type=A \
    --zone="${DNS_ZONE_NAME}" \
    --project="${PROJECT_ID}"
gcloud dns record-sets transaction execute --zone="${DNS_ZONE_NAME}" --project="${PROJECT_ID}"

success "DNS zone and wildcard records created."

# =============================================================================
# PHASE 9: Apply Kubernetes Internal Gateway Rules
# =============================================================================
header "PHASE 9: Kubernetes Internal Gateway"

info "Applying internal nginx gateway for Cloud Run → GKE callbacks..."
kubectl apply -f ./k8s-internal-ingress.yaml

success "Internal gateway applied."

# =============================================================================
# PHASE 10: Apply Public Ingress Rules
# =============================================================================
header "PHASE 10: Kubernetes Public Ingress Rules"

info "Applying public ingress rules for internet → GKE services..."
kubectl apply -f ./k8s-public-ingress.yaml

success "Public ingress rules applied."

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=================================================================="
echo " Service Mesh Infrastructure Setup Complete"
echo "=================================================================="
echo ""
echo " Project     : ${PROJECT_ID}"
echo " Region      : ${REGION} | Zone: ${ZONE}"
echo " VPC         : ${VPC_NAME}"
echo " GKE Cluster : ${CLUSTER_NAME}"
echo ""
echo " Internal ALB IP      : ${ALB_IP_ADDRESS}  (Cloud Run gateway)"
echo " Nginx Internal IP    : ${NGINX_INTERNAL_IP_ADDRESS}  (GKE callback entry)"
echo " kube-dns IP          : ${KUBE_DNS_IP}  (used by nginx gateway resolver)"
if [[ -n "${PUBLIC_NGINX_IP:-}" ]]; then
    echo " Nginx Public IP      : ${PUBLIC_NGINX_IP}  (Public internet entry)"
    echo ""
    echo " Public URLs:"
    echo "   Frontend  : http://${PUBLIC_NGINX_IP}.nip.io/"
    echo "   Orders    : http://${PUBLIC_NGINX_IP}.nip.io/api/orders"
    echo "   Payments  : http://${PUBLIC_NGINX_IP}.nip.io/api/payments"
fi
echo ""
echo " Internal DNS Routing:"
echo "   *.api.internal      → ${ALB_IP_ADDRESS} → Internal ALB → Cloud Run (URL mask)"
echo "   *.k8s.api.internal  → ${NGINX_INTERNAL_IP_ADDRESS} → Nginx Gateway → GKE pods"
echo ""
echo " Service Communication Map:"
echo "   Service 1 (Frontend, GKE)"
echo "     → http://service-2-orders-api.k8s.api.internal"
echo "     → http://service-4-payments-api.k8s.api.internal"
echo "   Service 2 (Orders API, GKE)"
echo "     → http://service-3-inventory-cloudrun.api.internal"
echo "   Service 3 (Inventory, Cloud Run) [internal only]"
echo "     → http://service-2-orders-api.k8s.api.internal/inventory-callback"
echo "   Service 4 (Payments API, GKE)"
echo "     → http://service-5-notifications-cloudrun.api.internal"
echo "   Service 5 (Notifications, Cloud Run) [internal only]"
echo "     → http://service-4-payments-api.k8s.api.internal/notification-callback"
echo ""
echo " Next Steps:"
echo "   1. Deploy each service using its deploy.sh script"
echo "   2. Verify with: kubectl exec -it <pod> -- wget -qO- http://service-2-orders-api.k8s.api.internal/health"
echo "=================================================================="
