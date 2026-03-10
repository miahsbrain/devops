# Internal Service Mesh on GCP — Complete Setup Guide

> **Project:** `secure-devops-setup`  
> **Region:** `us-central1` | **Zone:** `us-central1-a`  
> **VPC:** `service-mesh-vpc` | **Cluster:** `service-mesh-cluster`

---

## What This Is

This guide explains how to build a private internal service mesh on Google Cloud Platform that connects services running on **GKE** (Google Kubernetes Engine) with services running on **Cloud Run**, all communicating over a private VPC — never over the public internet.

The result is a setup where every service can call any other service using a consistent, human-readable internal URL like `http://service-name.api.internal` or `http://service-name.k8s.api.internal`, regardless of whether the target runs on GKE or Cloud Run.

---

## Network Map

```
PUBLIC INTERNET
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  VPC: service-mesh-vpc  (10.10.0.0/20)                         │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  GKE Cluster: service-mesh-cluster                      │   │
│  │  Pod range: 10.30.0.0/16                                │   │
│  │  Service range: 10.40.0.0/16                            │   │
│  │                                                          │   │
│  │  [Nginx Public]──────────────────────────────────────   │   │
│  │   ↑ Public IP (dynamic)                                 │   │
│  │                                                          │   │
│  │  [Service 1: Frontend]  ClusterIP: 10.40.x.x:80        │   │
│  │  [Service 2: Orders API]  ClusterIP: 10.40.x.x:80      │   │
│  │  [Service 4: Payments API]  ClusterIP: 10.40.x.x:80    │   │
│  │                                                          │   │
│  │  [Nginx Internal Gateway]  ◄── 10.10.1.51              │   │
│  │   DNS: *.k8s.api.internal → 10.10.1.51                 │   │
│  │   Routes by hostname to ClusterIP services              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  [Internal ALB]  ◄── 10.10.1.50                                │
│   DNS: *.api.internal → 10.10.1.50                             │
│   Routes by service name to Cloud Run (URL mask)               │
│                                                                  │
│  [Proxy-only subnet]  10.20.0.0/23                             │
│   (required by Internal ALB — runs its Envoy proxy fleet)      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
          │                              │
          ▼                              ▼
[Cloud Run: Service 3]        [Cloud Run: Service 5]
 Inventory (internal only)     Notifications (internal only)
 VPC Egress: all-traffic       VPC Egress: all-traffic
```

---

## How Traffic Flows

There are four possible call directions. Each works differently.

### 1. Browser → GKE Service (public traffic)

```
Browser → Nginx Public (dynamic public IP)
        → ClusterIP service (port 80 → container port)
        → Pod
```

The Nginx Public Ingress Controller gets a public IP from GCP. An Ingress resource maps URL paths to ClusterIP services. The ClusterIP services all listen on **port 80** externally, translating to the actual container port via `targetPort`.

### 2. GKE → Cloud Run (internal)

```
GKE Pod calls http://service-3-inventory-cloudrun.api.internal
  → Cloud DNS resolves *.api.internal → 10.10.1.50 (Internal ALB)
  → Internal ALB reads the hostname, extracts "service-3-inventory-cloudrun"
  → Routes to Cloud Run service named "service-3-inventory-cloudrun"
  → Cloud Run responds over VPC
```

The **URL mask** (`<service>.api.internal`) is the key — the ALB reads the service name directly from the hostname. Deploying a new Cloud Run service named `my-new-service` makes it immediately reachable at `http://my-new-service.api.internal` with zero infrastructure changes.

### 3. Cloud Run → GKE (callback / internal)

```
Cloud Run calls http://service-2-orders-api.k8s.api.internal
  → Cloud DNS resolves *.k8s.api.internal → 10.10.1.51 (Nginx Internal Gateway)
  → Nginx receives request, reads Host header
  → map{} block extracts "service-2-orders-api", appends "-cluster-ip"
  → proxy_pass to service-2-orders-api-cluster-ip.default.svc.cluster.local
  → CoreDNS (10.40.0.10) resolves to ClusterIP → Pod
```

The **Nginx Internal Gateway** is a plain nginx pod (not the Nginx Ingress Controller) that we configure fully via a ConfigMap. This is CI-friendly — adding a new GKE service requires zero changes to the gateway config. CoreDNS auto-discovers every new ClusterIP service.

### 4. GKE → GKE (same cluster)

```
GKE Pod calls http://service-2-orders-api-cluster-ip
  → CoreDNS resolves directly to ClusterIP
  → Pod
```

Services in the same cluster should use ClusterIP names directly — no DNS hop, no Nginx, straight to the pod.

---

## Why Two Separate Routing Paths?

| Direction            | Mechanism               | Why                                                                                                                                                                                      |
| -------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `*.api.internal`     | Internal ALB + URL mask | Cloud Run has no visibility into the Kubernetes cluster network. The ALB acts as the bridge — it lives in the VPC and can reach Cloud Run via its serverless NEG                         |
| `*.k8s.api.internal` | Nginx proxy pod         | GKE ClusterIP addresses are only routable inside the cluster. Cloud Run (even with VPC Egress) can't reach them directly. The Nginx pod sits inside the cluster and acts as a translator |

---

## Why a Plain Nginx Pod (Not the Nginx Ingress Controller)?

This is a deliberate architectural choice made after running into problems with the Nginx Ingress Controller.

The Nginx Ingress Controller watches Kubernetes Ingress resources and **auto-generates** an `nginx.conf`. This generated config always includes its own `proxy_pass`, `resolver`, and `location /` block. Every attempt to override these via annotations caused errors:

- Adding `proxy_pass` in a `configuration-snippet` → **duplicate proxy_pass**
- Adding a `location /` in a `server-snippet` → **duplicate location "/"**
- Adding `resolver` in `http-snippet` → **duplicate resolver directive**

The Ingress Controller is designed for static declarative routing rules, not dynamic runtime routing based on request content. Since our use case requires extracting the upstream hostname from the request at runtime, we need to own the full `nginx.conf`.

A plain nginx pod with a ConfigMap gives us exactly that — and it's simpler, lighter, and easier to debug.

---

## CI-Friendliness Explained

Both routing paths are designed so that deploying a new service requires **zero infrastructure changes**.

**Cloud Run side:** The Internal ALB uses a URL mask `<service>.api.internal`. When a new Cloud Run service named `payments-v2` is deployed, it's instantly reachable at `http://payments-v2.api.internal`. The ALB reads the service name from the hostname at request time.

**GKE side:** The Nginx gateway uses a `map{}` block to extract the service name from the hostname and appends `-cluster-ip`. When a new GKE service is deployed with a ClusterIP service named `payments-v2-cluster-ip`, it's instantly reachable at `http://payments-v2.k8s.api.internal`. CoreDNS auto-discovers it.

---

## Prerequisites

Before running the setup script, you need:

1. **Google Cloud SDK (`gcloud`)** installed and authenticated
2. **kubectl** installed
3. **Docker** installed (for building and pushing service images)
4. **A GCP project** with billing enabled — set `PROJECT_ID` in the script
5. **Your local IP range** — set `MASTER_AUTHORIZED_CIDR` so you can reach the GKE API server

---

## Variables Reference

All variables are defined at the top of `setup-mesh.sh`. Key ones to review before running:

| Variable                    | Default               | What it is                                         |
| --------------------------- | --------------------- | -------------------------------------------------- |
| `PROJECT_ID`                | `secure-devops-setup` | Your GCP project ID                                |
| `REGION`                    | `us-central1`         | GCP region for all resources                       |
| `ZONE`                      | `us-central1-a`       | Zone for the GKE cluster                           |
| `MASTER_AUTHORIZED_CIDR`    | `102.216.0.0/16`      | Your IP range for kubectl access                   |
| `ALB_IP_ADDRESS`            | `10.10.1.50`          | Static IP for Internal ALB                         |
| `NGINX_INTERNAL_IP_ADDRESS` | `10.10.1.51`          | Static IP for Nginx Internal Gateway               |
| `KUBE_DNS_IP`               | `10.40.0.10`          | kube-dns ClusterIP (verify after cluster creation) |
| `NODE_MACHINE_TYPE`         | `e2-standard-2`       | GKE node machine type                              |
| `NODE_COUNT`                | `1`                   | Number of GKE nodes                                |

> **Important:** `KUBE_DNS_IP` defaults to `10.40.0.10` because the services CIDR starts at `10.40.0.0/16` and kube-dns is always the 10th address. Verify with `kubectl get svc kube-dns -n kube-system` after cluster creation.

---

## Setup Process Overview

The script runs in 10 phases. Here's what each does at a high level before we go through them in detail:

1. **Phase 0** — Enable GCP APIs
2. **Phase 1** — Create VPC, subnets, Cloud NAT, firewall rules
3. **Phase 2** — Create the GKE cluster
4. **Phase 3** — Reserve static internal IPs
5. **Phase 4** — Build the Internal ALB stack for Cloud Run routing
6. **Phase 5** — Deploy the Nginx Internal Gateway pod
7. **Phase 6** — Deploy the Nginx Public Ingress Controller
8. **Phase 7** — Create the Internal ALB bridge inside Kubernetes
9. **Phase 8** — Create the Cloud DNS private zone and wildcard records
10. **Phase 9 & 10** — Apply Kubernetes manifests

---

## Detailed Phase-by-Phase Walkthrough

### Phase 0 — Project Setup

Enables the five GCP APIs required:

- `compute` — VPC, subnets, firewall, load balancers
- `container` — GKE
- `run` — Cloud Run
- `dns` — Cloud DNS private zones
- `artifactregistry` — Docker image storage

### Phase 1 — VPC & Networking

Creates:

**Main subnet** (`10.10.0.0/20`) with two secondary ranges:

- Pod range (`10.30.0.0/16`) — where GKE pods get IPs
- Service range (`10.40.0.0/16`) — where ClusterIP services get IPs

**Proxy-only subnet** (`10.20.0.0/23`) — this is mandatory for the Internal ALB. Google's internal load balancer runs a fleet of Envoy proxies, and they need a dedicated subnet to operate in. Without this, the forwarding rule creation in Phase 4 will fail.

**Cloud NAT** — private GKE nodes have no public IPs, so they can't pull Docker images or reach external APIs directly. Cloud NAT provides outbound internet access without exposing the nodes publicly.

**Firewall rules:**

- Allow all internal VPC traffic (pods, nodes, services talk freely)
- Allow the proxy-only subnet to reach GKE backends (the ALB Envoy proxies need this)

### Phase 2 — GKE Cluster

Creates a **private zonal cluster** — worker nodes have no public IP addresses. The Kubernetes API server is publicly accessible but restricted to `MASTER_AUTHORIZED_CIDR`. All node-to-node traffic stays inside the VPC.

`--enable-ip-alias` is required for VPC-native networking — without it, GKE uses routes-based networking which doesn't work with Internal ALB.

### Phase 3 — Static IP Reservation

Reserves two private IPs inside the subnet:

- `10.10.1.50` — for the Internal ALB (Cloud Run gateway)
- `10.10.1.51` — for the Nginx Internal Gateway

These IPs are what the DNS wildcard records point to. They must be reserved before Phase 4 and 5 create the resources that use them, otherwise GCP might assign them to something else.

### Phase 4 — Internal ALB Stack

This is the most complex phase. It builds a full GCP load balancer stack in 5 steps:

**Serverless NEG (Network Endpoint Group)** — this is the bridge between the load balancer and Cloud Run. A NEG with `--cloud-run-url-mask="<service>.api.internal"` tells GCP: "extract the service name from the hostname and route to the matching Cloud Run service." No explicit service registration needed.

**Backend Service** — connects the NEG to the load balancer. Uses `INTERNAL_MANAGED` scheme for private VPC load balancing.

**URL Map** — the routing brain. Maps incoming requests to the backend service. In this setup it's simple (default → backend), but it could be extended for path-based routing.

**Target HTTP Proxy** — sits between the forwarding rule and the URL map. GCP requires this intermediate layer.

**Forwarding Rule** — the actual entry point. Binds to `10.10.1.50:80` and accepts traffic from inside the VPC.

> **Gotcha:** The forwarding rule command requires `--target-http-proxy-region`. This is a regional (not global) load balancer. Forgetting this flag causes a confusing error where GCP tries to find a global proxy with the same name and fails.

### Phase 5 — Nginx Internal Gateway

Deploys three Kubernetes resources in a single `kubectl apply`:

**ConfigMap** — the full `nginx.conf`. Key sections:

```nginx
resolver 10.40.0.10 valid=10s ipv6=off;
```

Uses the kube-dns IP directly. Using the hostname `kube-dns.kube-system.svc.cluster.local` fails because nginx itself needs DNS to resolve it — a chicken-and-egg problem. Use the IP.

```nginx
map $host $service_name {
  ~^(?<svc>[^.]+)\.k8s\.api\.internal$  ${svc}-cluster-ip;
  default  "";
}
```

Extracts the service name from the hostname and appends `-cluster-ip`. The capture group is named `svc` and must match the reference `${svc}` exactly. The `-cluster-ip` suffix matches the Kubernetes ClusterIP service naming convention used in the deployment manifests.

```nginx
set $upstream http://$service_name.default.svc.cluster.local;
proxy_pass $upstream;
```

Routes to the correct pod. Using a variable in `proxy_pass` requires the `resolver` directive — nginx won't start without it if `proxy_pass` references a variable.

**Deployment** — a plain `nginx:1.25-alpine` pod mounting the ConfigMap.

**Service** — `LoadBalancer` type with `networking.gke.io/load-balancer-type: Internal` annotation. GKE provisions an internal load balancer and assigns `10.10.1.51`.

> **Gotcha:** The IP assignment can take 2–3 minutes. The service will show `<pending>` in `EXTERNAL-IP` during this time. This is normal.

### Phase 6 — Nginx Public Ingress Controller

Deploys the Nginx Ingress Controller for handling public internet traffic. This is written as a full manifest directly in the script rather than patching the upstream manifest from GitHub.

> **Gotcha about manifest patching:** An earlier approach downloaded the official Nginx manifest and used `sed` to rename resources. This caused a double-rename bug — `ingress-nginx` became `ingress-nginx-internal` correctly, but then `ingress-nginx-controller` also got renamed to `ingress-nginx-internal-controller` except the controller args like `--publish-service` still referenced the old name. The fix was to write the full manifest explicitly with correct names throughout. Never use broad `sed` replacement on Kubernetes manifests.

### Phase 7 — Internal ALB Bridge

Creates a Kubernetes `ClusterIP` service and `Endpoints` object that point to the Internal ALB IP (`10.10.1.50`). This makes the ALB addressable as a Kubernetes service so public Ingress rules can reference it as a backend for Cloud Run routes.

> **Gotcha:** The service's `metadata.labels` cannot contain free-form text. Labels have strict character and length requirements — only alphanumeric, `-`, `_`, `.`, max 63 chars. A description was originally put in a label which caused a validation error. Move descriptive text to `metadata.annotations` instead.

### Phase 8 — Cloud DNS

Creates a **private DNS zone** for `api.internal.` bound to the VPC. Private zones are only resolvable from inside the VPC — nothing on the public internet can see them.

Two wildcard A records:

- `*.api.internal.` → `10.10.1.50` (Internal ALB)
- `*.k8s.api.internal.` → `10.10.1.51` (Nginx Internal Gateway)

The wildcard means any subdomain resolves to the same IP. `inventory.api.internal`, `payments.api.internal`, `anything.api.internal` all resolve to `10.10.1.50`.

### Phases 9 & 10 — Kubernetes Manifests

Applies:

- `k8s-internal-ingress.yaml` — the Nginx Internal Gateway ConfigMap/Deployment/Service
- `k8s-public-ingress.yaml` — the Nginx Public Ingress rules

---

## Kubernetes Service Port Convention

All GKE ClusterIP services are exposed on **port 80** externally, regardless of what port the container actually runs on. The `targetPort` handles the translation:

```yaml
ports:
  - port: 80 # what Kubernetes exposes (what callers use)
    targetPort: 3001 # what the container actually listens on
```

This matters for two reasons:

1. The Nginx Internal Gateway always proxies to port 80 — if each service had a different port, the gateway would need to know every service's port number, breaking CI-friendliness
2. The public Ingress backends reference port 80 uniformly

**This does not affect local development.** Your containers still run on 3000/3001/3002 locally. The port 80 translation only exists inside Kubernetes.

**This does affect intra-cluster calls.** If Service A calls Service B using the ClusterIP service name, it must use port 80:

```
# Correct — uses the Kubernetes service port
http://service-2-orders-api-cluster-ip/api/orders

# Wrong — bypasses Kubernetes service layer
http://service-2-orders-api-cluster-ip:3001/api/orders
```

---

## Deploying Services

After the infrastructure is up, deploy each service using its `deploy.sh`:

```bash
# GKE services
cd service-1-frontend && chmod +x deploy.sh && ./deploy.sh
cd service-2-orders-api && chmod +x deploy.sh && ./deploy.sh
cd service-4-payments-api && chmod +x deploy.sh && ./deploy.sh

# Cloud Run services
cd service-3-inventory-cloudrun && chmod +x deploy.sh && ./deploy.sh
cd service-5-notifications-cloudrun && chmod +x deploy.sh && ./deploy.sh
```

Each `deploy.sh`:

1. Authenticates Docker with Artifact Registry
2. Builds and pushes the Docker image
3. For GKE: applies the `k8s-deployment.yaml` (Deployment + ClusterIP Service)
4. For Cloud Run: deploys with `--ingress=internal` and `--vpc-egress=all-traffic`

---

## Verification

### Check all pods are running

```bash
kubectl get pods -n default
kubectl get pods -n ingress-nginx-public
```

### Check services and IPs

```bash
kubectl get svc -n default
# Should show nginx-internal-gateway with EXTERNAL-IP 10.10.1.51

kubectl get svc -n ingress-nginx-public
# Should show ingress-nginx-public-controller with a public EXTERNAL-IP
```

### Test GKE → GKE routing (via k8s.api.internal)

```bash
kubectl exec -it <any-pod-name> -- wget -qO- http://service-2-orders-api.k8s.api.internal/health
```

### Test DNS resolution from a pod

```bash
kubectl exec -it <any-pod-name> -- nslookup service-3-inventory-cloudrun.api.internal
# Should resolve to 10.10.1.50

kubectl exec -it <any-pod-name> -- nslookup service-2-orders-api.k8s.api.internal
# Should resolve to 10.10.1.51
```

### Check nginx internal gateway logs

```bash
kubectl logs -l app=nginx-internal-gateway -n default --tail=20
```

---

## Gotchas & Resolutions Reference

| Problem                                         | Root Cause                                                                                                  | Fix                                                                                         |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `"resolver" directive is duplicate`             | Nginx Ingress Controller already sets its own resolver. Adding one via `http-snippet` creates a conflict    | Remove the `http-snippet` — Nginx Ingress manages its own resolver                          |
| `duplicate location "/"`                        | `server-snippet` defines a `location /` block but the Ingress Controller also generates one                 | Switch to `configuration-snippet` or use a plain nginx pod                                  |
| `duplicate proxy_pass`                          | `configuration-snippet` injects into an existing `location` block that already has `proxy_pass`             | Use a plain nginx pod where you own the full config                                         |
| `ingress-nginx-internal-internal` double rename | `sed 's/ingress-nginx/ingress-nginx-internal/'` runs twice on values that already contain `ingress-nginx`   | Write manifests explicitly instead of patching upstream manifests                           |
| `--publish-service` still points to old name    | sed rename missed controller args that reference the service name                                           | Write manifests explicitly — the controller args need exact names                           |
| Internal LB IP `<pending>` for 2+ minutes       | GKE internal LB provisioning takes time                                                                     | Wait — it resolves on its own, typically within 2–3 minutes                                 |
| `Host not found` from nginx gateway             | Nginx was using `kube-dns.kube-system.svc.cluster.local` as the resolver, which itself needs DNS to resolve | Use the kube-dns ClusterIP directly: `10.40.0.10`                                           |
| `metadata.labels` invalid value                 | Labels have strict character restrictions — no spaces, special chars, max 63 chars                          | Move descriptive text to `metadata.annotations` instead                                     |
| `--target-http-proxy-region` missing            | Regional forwarding rules require the region flag for the proxy reference                                   | Always include `--target-http-proxy-region=$REGION` on forwarding rule creation             |
| `No cluster named 'internal-mesh-cluster'`      | deploy.sh had the old demo cluster name                                                                     | Update `CLUSTER_NAME` in each service's `deploy.sh` to `service-mesh-cluster`               |
| Nginx pod resolves service name but 502s        | ClusterIP services used port 3001/3002 but nginx proxied to port 80                                         | Standardize ClusterIP service `port` to 80 with `targetPort` pointing to the container port |

---

## Teardown

To tear down everything in reverse dependency order:

```bash
# GKE cluster (removes all Kubernetes resources inside it)
gcloud container clusters delete service-mesh-cluster --zone=us-central1-a --project=secure-devops-setup --quiet

# Internal ALB stack
gcloud compute forwarding-rules delete service-mesh-internal-lb-forwarding-rule --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute target-http-proxies delete service-mesh-internal-lb-http-proxy --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute url-maps delete service-mesh-internal-lb-url-map --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute backend-services delete service-mesh-cloudrun-backend --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute network-endpoint-groups delete service-mesh-cloudrun-neg --region=us-central1 --project=secure-devops-setup --quiet

# Static IPs
gcloud compute addresses delete service-mesh-internal-alb-static-ip --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute addresses delete service-mesh-nginx-internal-static-ip --region=us-central1 --project=secure-devops-setup --quiet

# DNS
gcloud dns record-sets delete "*.api.internal." --type=A --zone=service-mesh-api-internal-zone --project=secure-devops-setup --quiet
gcloud dns record-sets delete "*.k8s.api.internal." --type=A --zone=service-mesh-api-internal-zone --project=secure-devops-setup --quiet
gcloud dns managed-zones delete service-mesh-api-internal-zone --project=secure-devops-setup --quiet

# Cloud NAT and Router
gcloud compute routers nats delete service-mesh-cloud-nat --router=service-mesh-cloud-router --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute routers delete service-mesh-cloud-router --region=us-central1 --project=secure-devops-setup --quiet

# Firewall rules
gcloud compute firewall-rules delete service-mesh-allow-internal --project=secure-devops-setup --quiet
gcloud compute firewall-rules delete service-mesh-allow-proxy-to-backends --project=secure-devops-setup --quiet

# Subnets then VPC (subnets must go before VPC)
gcloud compute networks subnets delete service-mesh-proxy-only-subnet --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute networks subnets delete service-mesh-subnet --region=us-central1 --project=secure-devops-setup --quiet
gcloud compute networks delete service-mesh-vpc --project=secure-devops-setup --quiet
```

> Always delete the GKE cluster first. Deleting the VPC while a cluster still exists fails because GKE holds references to the subnet.
