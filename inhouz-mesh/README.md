# Internal Service Mesh Demo — GKE + Cloud Run

A 5-service demonstration of a fully private internal service mesh
where GKE and Cloud Run services communicate entirely within a VPC.

---

## Service Map

```
[Public Internet]
      ↓
[Nginx Public Controller — public IP]
      ↓
┌─────────────────────────────────────────────────────────────┐
│  VPC: service-mesh-vpc                                       │
│                                                             │
│  Service 1: Frontend (GKE)                                  │
│    ↓ http://service-2-orders-api.k8s.api.internal           │
│    ↓ http://service-4-payments-api.k8s.api.internal         │
│                                                             │
│  Service 2: Orders API (GKE)                                │
│    ↓ http://service-3-inventory-cloudrun.api.internal       │
│    ↑ /inventory-callback (receives from Service 3)          │
│                                                             │
│  Service 3: Inventory (Cloud Run — internal only)           │
│    ← called by Service 2 via Internal ALB                   │
│    ↓ http://service-2-orders-api.k8s.api.internal           │
│                                                             │
│  Service 4: Payments API (GKE)                              │
│    ↓ http://service-5-notifications-cloudrun.api.internal   │
│    ↑ /notification-callback (receives from Service 5)       │
│                                                             │
│  Service 5: Notifications (Cloud Run — internal only)       │
│    ← called by Service 4 via Internal ALB                   │
│    ↓ http://service-4-payments-api.k8s.api.internal         │
│                                                             │
│  [Internal ALB: 10.10.1.50]                                 │
│    ← *.api.internal DNS wildcard                            │
│    → Cloud Run services via URL mask                        │
│                                                             │
│  [Nginx Internal: 10.10.1.51]                               │
│    ← *.k8s.api.internal DNS wildcard                        │
│    → GKE pods via internal Ingress rules                    │
└─────────────────────────────────────────────────────────────┘
```

---

## DNS Routing

| DNS Pattern              | Resolves To    | Routes To                        |
|--------------------------|----------------|----------------------------------|
| `*.api.internal`         | `10.10.1.50`   | Internal ALB → Cloud Run (mask)  |
| `*.k8s.api.internal`     | `10.10.1.51`   | Nginx Internal → GKE pods        |

---

## Project Structure

```
inhouz-mesh/
├── service-1-frontend/
│   ├── index.js               # Express app — calls Service 2 and 4
│   ├── package.json
│   ├── Dockerfile
│   ├── k8s-deployment.yaml    # GKE Deployment + ClusterIP Service
│   └── deploy.sh              # Build → Push → Deploy to GKE
│
├── service-2-orders-api/
│   ├── index.js               # Express app — calls Service 3, receives callbacks
│   ├── package.json
│   ├── Dockerfile
│   ├── k8s-deployment.yaml    # GKE Deployment + ClusterIP Service
│   └── deploy.sh              # Build → Push → Deploy to GKE
│
├── service-3-inventory-cloudrun/
│   ├── index.js               # Express app — called by Service 2, calls back
│   ├── package.json
│   ├── Dockerfile
│   └── deploy.sh              # Build → Push → Deploy to Cloud Run (internal)
│
├── service-4-payments-api/
│   ├── index.js               # Express app — calls Service 5, receives callbacks
│   ├── package.json
│   ├── Dockerfile
│   ├── k8s-deployment.yaml    # GKE Deployment + ClusterIP Service
│   └── deploy.sh              # Build → Push → Deploy to GKE
│
├── service-5-notifications-cloudrun/
│   ├── index.js               # Express app — called by Service 4, calls back
│   ├── package.json
│   ├── Dockerfile
│   └── deploy.sh              # Build → Push → Deploy to Cloud Run (internal)
│
└── infra/
    ├── setup-mesh.sh              # One-time infrastructure setup (run first)
    ├── k8s-public-ingress.yaml    # Public-facing Ingress rules (internet → GKE)
    ├── k8s-internal-ingress.yaml  # Internal Ingress rules (Cloud Run → GKE)
    └── k8s-internal-alb-bridge.yaml  # ClusterIP + Endpoints for Internal ALB
```

---

## Setup Order

### Step 1: Infrastructure (one time)
```bash
cd infra
chmod +x setup-mesh.sh
./setup-mesh.sh
```

This sets up:
- VPC, subnets, Cloud NAT, firewall rules
- GKE private cluster
- Internal ALB with URL masking (Cloud Run gateway)
- Nginx internal controller (Cloud Run → GKE callbacks)
- Nginx public controller (public internet → GKE)
- Cloud DNS private zone with wildcard records
- Internal ALB bridge (ClusterIP + Endpoints)
- All Kubernetes Ingress rules

### Step 2: Deploy Services (run from each service directory)
```bash
# GKE services
cd service-1-frontend && chmod +x deploy.sh && ./deploy.sh
cd service-2-orders-api && chmod +x deploy.sh && ./deploy.sh
cd service-4-payments-api && chmod +x deploy.sh && ./deploy.sh

# Cloud Run services
cd service-3-inventory-cloudrun && chmod +x deploy.sh && ./deploy.sh
cd service-5-notifications-cloudrun && chmod +x deploy.sh && ./deploy.sh
```

### Step 3: Get your public IP and access the app
```bash
kubectl get svc ingress-nginx-public-controller -n ingress-nginx-public
# Use the EXTERNAL-IP: http://EXTERNAL-IP.nip.io/
```

---

## Re-deploying a Service

Each deploy.sh accepts an optional image tag argument:
```bash
./deploy.sh v1.2.3   # deploy specific tag
./deploy.sh          # defaults to latest
```

No infrastructure changes needed between deployments.

---

## Adding a New Cloud Run Service

1. Deploy it with `--ingress=internal` and `--vpc-egress=all-traffic`
2. It is instantly reachable at `http://your-service-name.api.internal`
3. No DNS changes, no ALB changes, no Nginx changes needed

---

## Internal URL Reference

| Service | Internal URL | Type |
|---------|-------------|------|
| Service 1 Frontend | `http://service-1-frontend.k8s.api.internal` | GKE |
| Service 2 Orders API | `http://service-2-orders-api.k8s.api.internal` | GKE |
| Service 3 Inventory | `http://service-3-inventory-cloudrun.api.internal` | Cloud Run |
| Service 4 Payments API | `http://service-4-payments-api.k8s.api.internal` | GKE |
| Service 5 Notifications | `http://service-5-notifications-cloudrun.api.internal` | Cloud Run |
