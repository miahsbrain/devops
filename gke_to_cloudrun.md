# GKE + Cloud Run Internal Networking — Setup Guide

This guide walks you through setting up three microservices that communicate over a shared
private network inside Google Cloud. Service A and B run on Kubernetes (GKE). Service C runs
on Cloud Run and handles heavy, bursty workloads. All traffic between Cloud Run and GKE stays
inside your private network — it never goes out to the public internet.

**What you will end up with:**

```
Public internet → External Ingress → Service A (GKE)
                                          ↕ ClusterIP (private, cluster-only)
                                      Service B (GKE)
                                          ↕
                              Internal Ingress (VPC-only)
                                          ↕
                              Service C (Cloud Run, via VPC egress)
```

---

## Before You Start

### What you need installed on your machine

- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install) — the command-line tool for Google Cloud
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — the command-line tool for Kubernetes
- [Docker](https://docs.docker.com/get-docker/) — for building container images

Verify they are installed by running:

```bash
gcloud version
kubectl version --client
docker --version
```

### Log in to Google Cloud

```bash
gcloud auth login
gcloud auth application-default login
```

---

## Configuration — Set Your Variables Once

All commands in this guide use variables so you only need to change things in one place.

**Copy the example config file and fill in your values:**

```bash
cp .env.example .env
```

Then open `.env` in any text editor and fill in your project details. Every variable is
explained inside that file. Here is a summary of what each one means:

| Variable                | What it is                          | Example                  |
| ----------------------- | ----------------------------------- | ------------------------ |
| `PROJECT_ID`            | Your GCP project ID                 | `my-company-prod`        |
| `REGION`                | GCP region for everything           | `us-central1`            |
| `VPC_NETWORK`           | Name of your VPC network            | `my-vpc`                 |
| `VPC_SUBNET`            | Name of a subnet inside that VPC    | `my-subnet`              |
| `CLUSTER_NAME`          | Your GKE cluster name               | `my-cluster`             |
| `K8S_NAMESPACE`         | Kubernetes namespace to deploy into | `default`                |
| `INTERNAL_GATEWAY_HOST` | DNS hostname for internal ingress   | `internal.myapp.com`     |
| `INTERNAL_IP_NAME`      | Name for the reserved internal IP   | `my-app-internal-ip`     |
| `DNS_ZONE_NAME`         | Name for the Cloud DNS private zone | `internal-zone`          |
| `IMAGE_REGISTRY`        | Where Docker images are stored      | `gcr.io/my-company-prod` |

**Load your variables into the current terminal session:**

```bash
source .env
```

> You need to run `source .env` every time you open a new terminal before running any of the
> commands below. The deploy scripts load this file automatically, but manual commands in this
> guide require you to source it first.

---

## Phase 1 — Enable APIs and Reserve a Static IP

These are one-time steps you run once per project, not per deployment.

### Step 1.1 — Enable the required Google Cloud APIs

Google Cloud APIs are disabled by default. This command turns on everything this setup needs:

```bash
gcloud services enable \
  container.googleapis.com \
  run.googleapis.com \
  compute.googleapis.com \
  dns.googleapis.com \
  vpcaccess.googleapis.com \
  --project=$PROJECT_ID
```

Wait about 30 seconds after running this before continuing.

### Step 1.2 — Create a VPC-native GKE cluster (skip if you already have one)

Your GKE cluster must be **VPC-native** (also called alias IP mode). This is required for the
internal ingress to work. If you already have a cluster, check whether it is VPC-native:

```bash
gcloud container clusters describe $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --format="value(ipAllocationPolicy.useIpAliases)"
```

If the output is `true`, your cluster is VPC-native and you can skip to Step 1.3.

If you need to create a new cluster:

```bash
gcloud container clusters create $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --network $VPC_NETWORK \
  --subnetwork $VPC_SUBNET \
  --enable-ip-alias \
  --enable-private-nodes \
  --master-ipv4-cidr 172.16.0.0/28 \
  --num-nodes 3
```

This takes 5–10 minutes.

### Step 1.3 — Connect kubectl to your cluster

This command configures `kubectl` so it talks to your GKE cluster:

```bash
gcloud container clusters get-credentials $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID
```

Verify it worked:

```bash
kubectl get nodes
```

You should see a list of nodes. If you see an error, check your `CLUSTER_NAME` and `REGION`
values in `.env`.

### Step 1.4 — Reserve a static internal IP address

This IP address will be the stable address for your internal ingress. Reserving it first means
the IP never changes even if you recreate the ingress:

```bash
gcloud compute addresses create $INTERNAL_IP_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --subnet $VPC_SUBNET \
  --purpose SHARED_LOADBALANCER_VIP
```

**Save the IP address that was just reserved** — you will need it in Phase 3:

```bash
gcloud compute addresses describe $INTERNAL_IP_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --format "value(address)"
```

Write this IP down. It looks something like `10.128.0.45`. We will call it `INTERNAL_LB_IP`
from here on.

---

## Phase 2 — Deploy Service A and Service B to GKE

### Step 2.1 — Deploy the internal ingress

Do this before deploying the services, because the ingress needs the services to already exist
in the cluster as targets.

Apply the Kubernetes manifests for Service A and Service B. The deploy scripts handle the image
build and push, but the Service objects (which create the ClusterIP DNS names) can be applied
right now even without pods running yet:

```bash
kubectl apply -f k8s/service-a/deployment.yaml --namespace $K8S_NAMESPACE
kubectl apply -f k8s/service-b/deployment.yaml --namespace $K8S_NAMESPACE
```

At this point the pods will fail to start because the Docker images do not exist yet — that
is fine. The Service objects are created which is what the ingress needs.

### Step 2.2 — Build and deploy Service A

From the root of the monorepo:

```bash
bash services/service-a/deploy.sh
```

This script does four things:

1. Authenticates Docker with Google Container Registry
2. Builds the Docker image from `services/service-a/Dockerfile`
3. Pushes the image to `gcr.io/$PROJECT_ID/service-a:latest`
4. Applies the Kubernetes manifest and waits for pods to become healthy

### Step 2.3 — Build and deploy Service B

```bash
bash services/service-b/deploy.sh
```

### Step 2.4 — Verify both services are running

```bash
kubectl get pods --namespace $K8S_NAMESPACE
```

You should see pods for `service-a` and `service-b` with status `Running`. If any pod shows
`CrashLoopBackOff`, check its logs:

```bash
kubectl logs deployment/service-a --namespace $K8S_NAMESPACE
kubectl logs deployment/service-b --namespace $K8S_NAMESPACE
```

### Step 2.5 — Confirm ClusterIP DNS works between A and B

This verifies that Service A can reach Service B using the internal Kubernetes DNS name:

```bash
kubectl exec -it deployment/service-a \
  --namespace $K8S_NAMESPACE \
  -- wget -qO- http://service-b.$K8S_NAMESPACE.svc.cluster.local:8080/health
```

Expected output:

```json
{ "status": "ok", "service": "service-b" }
```

---

## Phase 3 — Set Up the Internal Ingress and Private DNS

This phase gives Cloud Run a single stable hostname to reach all services inside the cluster.

### Step 3.1 — Apply the ingress manifest

```bash
kubectl apply -f k8s/ingress/ingress.yaml --namespace $K8S_NAMESPACE
```

Watch the ingresses until they show an IP address in the `ADDRESS` column:

```bash
kubectl get ingress --namespace $K8S_NAMESPACE --watch
```

This can take 3–5 minutes. Press `Ctrl+C` once both ingresses show an IP.

### Step 3.2 — Confirm the internal ingress got the right IP

The internal ingress should have the same IP you reserved in Step 1.4:

```bash
kubectl get ingress internal-ingress \
  --namespace $K8S_NAMESPACE \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

This should match the `INTERNAL_LB_IP` you wrote down earlier. If it shows a different IP,
update the `kubernetes.io/ingress.regional-static-ip-name` annotation in
`k8s/ingress/ingress.yaml` to match your `$INTERNAL_IP_NAME` and reapply.

### Step 3.3 — Create a Cloud DNS private zone

A private DNS zone works like a regular DNS zone except it only resolves inside your VPC.
The public internet cannot see or use it.

```bash
gcloud dns managed-zones create $DNS_ZONE_NAME \
  --description "Private zone for internal service-to-service routing" \
  --dns-name "$INTERNAL_GATEWAY_HOST." \
  --visibility private \
  --networks $VPC_NETWORK \
  --project $PROJECT_ID
```

> The trailing dot after `$INTERNAL_GATEWAY_HOST.` is intentional — DNS zone names require it.

### Step 3.4 — Create a DNS A record

This is the record that maps `internal.myapp.com` (or whatever you set as
`INTERNAL_GATEWAY_HOST`) to the internal load balancer IP.

Replace `INTERNAL_LB_IP` with the IP you wrote down in Step 1.4:

```bash
gcloud dns record-sets create "$INTERNAL_GATEWAY_HOST." \
  --zone $DNS_ZONE_NAME \
  --type A \
  --ttl 300 \
  --rrdatas INTERNAL_LB_IP \
  --project $PROJECT_ID
```

**This is the only DNS record you will ever need to create.** When you add service #50 or
service #100, you only add a path to the ingress — not a new DNS record.

If the internal load balancer IP ever changes (for example you recreate the ingress), you
update this one record:

```bash
gcloud dns record-sets update "$INTERNAL_GATEWAY_HOST." \
  --zone $DNS_ZONE_NAME \
  --type A \
  --ttl 300 \
  --rrdatas NEW_IP \
  --project $PROJECT_ID
```

---

## Phase 4 — Deploy Service C to Cloud Run

### Step 4.1 — Build and deploy Service C

```bash
bash services/service-c/deploy.sh
```

This script builds and pushes the image, then deploys it to Cloud Run with VPC egress enabled.
At the end it prints the Cloud Run URL and the exact command to update the Kubernetes secret.

**Copy the command it prints and run it.** It looks like:

```bash
kubectl create secret generic service-urls \
  --from-literal=service-c-url=https://service-c-xxxx-uc.a.run.app \
  --namespace default \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then restart Service A so it picks up the new secret value:

```bash
kubectl rollout restart deployment/service-a --namespace $K8S_NAMESPACE
```

### Step 4.2 — Grant Service A permission to call Service C

By default Cloud Run requires authentication. This command allows Service A's Kubernetes
service account to call Service C:

```bash
# Get your project number (different from project ID)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud run services add-iam-policy-binding service-c \
  --region $REGION \
  --project $PROJECT_ID \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/run.invoker
```

### Step 4.3 — Verify Cloud Run can resolve the internal DNS name

Deploy a one-off Cloud Run job that checks whether `internal.myapp.com` resolves to an IP
from inside the VPC. This confirms the private DNS zone is working:

```bash
gcloud run jobs create dns-check \
  --image gcr.io/google.com/cloudsdktool/cloud-sdk:slim \
  --region $REGION \
  --project $PROJECT_ID \
  --network $VPC_NETWORK \
  --subnet $VPC_SUBNET \
  --vpc-egress all-traffic \
  --args "nslookup,$INTERNAL_GATEWAY_HOST"

gcloud run jobs execute dns-check \
  --region $REGION \
  --project $PROJECT_ID \
  --wait
```

Check the logs of the job. You should see the IP address you reserved in Step 1.4 in the
output. If you see `NXDOMAIN` or no address, the private DNS zone is not set up correctly —
go back to Step 3.3 and verify the zone name and network match.

Clean up the test job after:

```bash
gcloud run jobs delete dns-check \
  --region $REGION \
  --project $PROJECT_ID \
  --quiet
```

---

## Phase 5 — End-to-End Verification

### Step 5.1 — Test standard path: external → A → B

Call the external ingress with a standard processing request. This should flow through Service
A to Service B and back:

```bash
curl -X POST https://myapp.com/api/process \
  -H 'Content-Type: application/json' \
  -d '{"payload": "hello from outside"}'
```

Expected response:

```json
{
  "source": "service-a",
  "downstream": {
    "processed": true,
    "service": "service-b",
    "output": "Processed: \"hello from outside\""
  }
}
```

### Step 5.2 — Test heavy path: external → A → C (Cloud Run) → back into cluster

```bash
curl -X POST https://myapp.com/api/heavy \
  -H 'Content-Type: application/json' \
  -d '{"jobType": "image-processing", "payload": {"file": "photo.jpg"}}'
```

Expected response:

```json
{
  "source": "service-a",
  "downstream": {
    "jobType": "image-processing",
    "status": "completed",
    "service": "service-c"
  }
}
```

### Step 5.3 — Confirm the internal ingress is NOT reachable from the public internet

Run this from your local machine (which is outside the VPC). It should time out or be refused:

```bash
curl --connect-timeout 5 http://INTERNAL_LB_IP/health
```

Expected: `curl: (28) Connection timed out` — this is correct and expected behaviour.

### Step 5.4 — Confirm the internal ingress IS reachable from inside the cluster

```bash
kubectl run verify-internal \
  --image curlimages/curl \
  --restart Never \
  --rm -it \
  --namespace $K8S_NAMESPACE \
  -- curl http://$INTERNAL_GATEWAY_HOST/health
```

Expected:

```json
{ "status": "ok", "service": "service-a" }
```

---

## Phase 6 — Adding a New Service in the Future

This is where the architecture pays off. Adding service number 10, 50, or 100 requires
almost no extra work.

### Step 6.1 — Deploy the new service with a ClusterIP

Create your new service with a standard Kubernetes `Deployment` and `Service` of type
`ClusterIP`. No load balancer needed. No changes to DNS.

### Step 6.2 — Add one path to the internal ingress

Open `k8s/ingress/ingress.yaml`. In the `internal-ingress` rules section, add a path:

```yaml
- path: /service-x
  pathType: Prefix
  backend:
    service:
      name: service-x
      port:
        number: 8080
```

Apply the change:

```bash
kubectl apply -f k8s/ingress/ingress.yaml --namespace $K8S_NAMESPACE
```

### Step 6.3 — Call it from Cloud Run

In Service C (or any Cloud Run service), reach the new service using the same base URL:

```javascript
const SERVICE_X_URL = `${process.env.INTERNAL_GATEWAY_URL}/service-x`;
```

No new environment variables. No new DNS records. No new load balancers. One path added to
one file.

---

## Deploying Individual Services

Each service has its own `deploy.sh` in its folder. Run them from the repo root:

```bash
# Deploy only Service A (e.g. after a code change)
bash services/service-a/deploy.sh

# Deploy only Service B
bash services/service-b/deploy.sh

# Deploy only Service C
bash services/service-c/deploy.sh

# Deploy with a specific version tag instead of "latest"
bash services/service-a/deploy.sh v1.4.2
```

---

## Troubleshooting

**Pods stuck in `CrashLoopBackOff`**

```bash
kubectl describe pod -l app=service-a --namespace $K8S_NAMESPACE
kubectl logs deployment/service-a --namespace $K8S_NAMESPACE --previous
```

**Internal ingress has no IP after 10+ minutes**

Check that the `kubernetes.io/ingress.regional-static-ip-name` annotation in
`k8s/ingress/ingress.yaml` exactly matches your `$INTERNAL_IP_NAME` value, and that
the IP was reserved in the correct region.

**Cloud Run returns 403 when calling Service A or B through internal ingress**

The ingress does not require authentication by default. A 403 usually means a firewall
rule is blocking traffic. Check that your VPC allows ingress on port 80 from the Cloud Run
subnet range.

**`nslookup internal.myapp.com` returns NXDOMAIN from inside Cloud Run**

The Cloud DNS private zone must be attached to the same VPC network that Cloud Run is
using for egress. Verify the `--networks` flag in Step 3.3 matches `$VPC_NETWORK`.

**Service C cannot reach `http://internal.myapp.com`**

Check that Cloud Run was deployed with `--vpc-egress=all-traffic` and that `--network`
and `--subnet` match your `$VPC_NETWORK` and `$VPC_SUBNET` values. You can verify:

```bash
gcloud run services describe service-c \
  --region $REGION \
  --project $PROJECT_ID \
  --format "value(spec.template.metadata.annotations)"
```

---

## Repository Structure

```
monorepo/
├── .env.example              ← copy to .env and fill in your values
├── .env                      ← your actual config (do not commit this)
│
├── services/
│   ├── service-a/            ← API Gateway (GKE)
│   │   ├── index.js
│   │   ├── package.json
│   │   ├── Dockerfile
│   │   └── deploy.sh         ← builds image + deploys to GKE
│   │
│   ├── service-b/            ← Business Logic (GKE)
│   │   ├── index.js
│   │   ├── package.json
│   │   ├── Dockerfile
│   │   └── deploy.sh
│   │
│   └── service-c/            ← Heavy Processor (Cloud Run)
│       ├── index.js
│       ├── package.json
│       ├── Dockerfile
│       └── deploy.sh         ← builds image + deploys to Cloud Run
│
└── k8s/
    ├── service-a/
    │   └── deployment.yaml   ← Deployment + ClusterIP Service
    ├── service-b/
    │   └── deployment.yaml
    └── ingress/
        └── ingress.yaml      ← External ingress + Internal ingress
```
