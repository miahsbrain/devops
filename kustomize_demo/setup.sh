#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CLUSTER_NAME="kustomize-demo"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}   Kustomize Demo - Setup Script        ${NC}"
echo -e "${CYAN}========================================${NC}\n"

# ── 1. Create cluster ──────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/5] Creating k3d cluster: ${CLUSTER_NAME}...${NC}"
if k3d cluster list | grep -q "${CLUSTER_NAME}"; then
  echo "  Cluster already exists, skipping creation."
else
  k3d cluster create ${CLUSTER_NAME} \
    --port "8080:80@loadbalancer" \
    --port "8443:443@loadbalancer" \
    --agents 1
  echo -e "${GREEN}  ✓ Cluster created!${NC}"
fi

# ── 2. Create namespaces ───────────────────────────────────────────────────────
echo -e "\n${YELLOW}[2/5] Creating namespaces...${NC}"
kubectl create namespace staging --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod    --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}  ✓ Namespaces ready!${NC}"

# ── 3. Preview what kustomize will generate ────────────────────────────────────
echo -e "\n${YELLOW}[3/5] Previewing kustomize output (dry-run)...${NC}"
echo -e "\n${CYAN}--- STAGING manifests (first 60 lines) ---${NC}"
kubectl kustomize overlays/staging | head -60
echo -e "\n${CYAN}--- PROD manifests (first 60 lines) ---${NC}"
kubectl kustomize overlays/prod | head -60

# ── 4. Apply both overlays ─────────────────────────────────────────────────────
echo -e "\n${YELLOW}[4/5] Applying staging overlay...${NC}"
kubectl apply -k overlays/staging
echo -e "${GREEN}  ✓ Staging deployed!${NC}"

echo -e "\n${YELLOW}[4/5] Applying prod overlay...${NC}"
kubectl apply -k overlays/prod
echo -e "${GREEN}  ✓ Prod deployed!${NC}"

# ── 5. Wait and show status ────────────────────────────────────────────────────
echo -e "\n${YELLOW}[5/5] Waiting for pods to be ready...${NC}"
kubectl rollout status deployment/web-app -n staging --timeout=90s
kubectl rollout status deployment/web-app -n prod    --timeout=90s

echo -e "\n${CYAN}========================================${NC}"
echo -e "${GREEN}  ✓ All done! Here's your cluster:${NC}"
echo -e "${CYAN}========================================${NC}"

echo -e "\n${CYAN}STAGING pods:${NC}"
kubectl get pods -n staging -o wide

echo -e "\n${CYAN}PROD pods:${NC}"
kubectl get pods -n prod -o wide

echo -e "\n${CYAN}Services:${NC}"
kubectl get svc -n staging
kubectl get svc -n prod

echo -e "\n${CYAN}ConfigMaps (notice kustomize hashed names!):${NC}"
kubectl get cm -n staging
kubectl get cm -n prod

echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  To access the apps, run in a NEW terminal:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}# Staging:${NC}"
echo -e "  kubectl port-forward svc/web-app 8081:80 -n staging"
echo -e "  Then open: http://localhost:8081\n"
echo -e "  ${GREEN}# Prod:${NC}"
echo -e "  kubectl port-forward svc/web-app 8082:80 -n prod"
echo -e "  Then open: http://localhost:8082"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
