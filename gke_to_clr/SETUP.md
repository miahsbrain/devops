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
- [Docker](https://docs.docker.com/get-docker/) — for building and pushing container images

Verify they are all installed:

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

## Understanding Regions vs Zones

Before setting your configuration, it helps to understand the difference between a **region**
and a **zone** — they are used in different commands and for different resources.

**Region** — a geographic area made up of multiple data centres (e.g. `us-central1`).
Resources like Cloud Run services, static IP addresses, Cloud DNS zones, Artifact Registry
repositories, and regional load balancers are all created at the region level.

**Zone** — a single data centre inside a region (e.g. `us-central1-a`).
Resources like GKE node pools, Compute Engine VMs, and zonal disks are created at the zone
level. A zone always belongs to one region — `us-central1-a` lives inside `us-central1`.

In this setup:

- `$ZONE` (`us-central1-a`) is used when creating the GKE cluster and connecting `kubectl`
- `$REGION` (`us-central1`) is used for everything else — Cloud Run, static IP, DNS, Artifact Registry

---

## Configuration — Set Your Variables Once

All commands in this guide use variables so you only need to change things in one place.

**Copy the example config file:**

```bash
cp .env.example .env
```

The `.env` file already has the correct values for this project pre-filled. Open it to review
or adjust anything. Here is a summary of every variable and what it controls:

| Variable                | What it controls                                 | Value                                                        |
| ----------------------- | ------------------------------------------------ | ------------------------------------------------------------ |
| `PROJECT_ID`            | Your GCP project                                 | `__secure-devops-setup`                                      |
| `REGION`                | Cloud Run, static IP, DNS, Artifact Registry     | `us-central1`                                                |
| `ZONE`                  | GKE cluster location                             | `us-central1-a`                                              |
| `VPC_NETWORK`           | The private network everything shares            | `devops-vpc`                                                 |
| `VPC_SUBNET`            | Subnet inside that network                       | `devops-subnet`                                              |
| `CLUSTER_NAME`          | GKE cluster name                                 | `devops-cluster`                                             |
| `K8S_NAMESPACE`         | Kubernetes namespace for all services            | `default`                                                    |
| `ARTIFACT_REPO`         | Artifact Registry repository name                | `prod-repo`                                                  |
| `IMAGE_REGISTRY`        | Full Docker image path (auto-derived from above) | `us-central1-docker.pkg.dev/__secure-devops-setup/prod-repo` |
| `INTERNAL_GATEWAY_HOST` | Private hostname Cloud Run uses to reach GKE     | `internal.devops-gateway.private`                            |
| `INTERNAL_IP_NAME`      | Name of the reserved internal IP                 | `devops-internal-ip`                                         |
| `DNS_ZONE_NAME`         | Name of the Cloud DNS private zone               | `devops-internal-zone`                                       |

**Load your variables into the current terminal session:**

```bash
source .env
```

> You need to run `source .env` every time you open a new terminal before running the commands
> below. The deploy scripts load this file automatically, but the manual commands in this guide
> require you to source it first.

---

## Phase 1 — Enable APIs and Create Prerequisites

These are one-time steps. Run them once per project, not once per deployment.

### Step 1.1 — Enable the required Google Cloud APIs

Google Cloud APIs are off by default. This command turns on everything this setup needs:

```bash
gcloud services enable \
  container.googleapis.com \
  run.googleapis.com \
  compute.googleapis.com \
  dns.googleapis.com \
  artifactregistry.googleapis.com \
  vpcaccess.googleapis.com \
  --project=$PROJECT_ID
```

Wait about 30 seconds after running this before continuing.

### Step 1.2 — Create the Artifact Registry repository

Artifact Registry is where your Docker images are stored. This is a regional resource.

```bash
gcloud artifacts repositories create $ARTIFACT_REPO \
  --repository-format=docker \
  --location=$REGION \
  --project=$PROJECT_ID \
  --description="Docker images for devops services"
```

Then configure Docker to authenticate with it:

```bash
gcloud auth configure-docker $REGION-docker.pkg.dev
```

Verify the repository exists:

```bash
gcloud artifacts repositories list \
  --location=$REGION \
  --project=$PROJECT_ID
```

### Step 1.3 — VPC Network Setup

A VPC (Virtual Private Cloud) is the private network that your GKE cluster, Cloud Run
service, and internal load balancer all share. Everything needs to be on the same VPC for
internal traffic to flow between them.

Follow the path that matches your situation.

---

#### Path A — I already have a VPC

**A1. List your existing networks**

```bash
gcloud compute networks list --project $PROJECT_ID
```

Find your network in the output and note the exact name. Update `VPC_NETWORK` in your `.env`
to match it exactly.

**A2. Check the network mode**

Your VPC must use **custom subnet mode**, not auto mode. Auto mode networks automatically
create subnets in every region which can conflict with the IP ranges GKE needs.

```bash
gcloud compute networks describe $VPC_NETWORK \
  --project $PROJECT_ID \
  --format="value(autoCreateSubnetworks)"
```

If the output is `false` — you are on custom mode. Move to **A3**.

If the output is `true` — you are on auto mode. You have two options:

- **Recommended:** Create a new custom mode VPC using Path B below. Auto mode networks
  cannot be converted to custom mode.
- **Alternative:** You can use an auto mode network but you must pick a subnet CIDR that
  does not conflict with the auto-created ranges (`10.128.0.0/9`). Proceed with caution.

**A3. Find or create a subnet in your region**

Your VPC needs a subnet in `$REGION` for the GKE nodes and Cloud Run egress traffic to use.
List existing subnets in your network:

```bash
gcloud compute networks subnets list \
  --network $VPC_NETWORK \
  --project $PROJECT_ID
```

Look for a subnet where the `REGION` column matches `$REGION` (i.e. `us-central1`).

If a suitable subnet exists — note its name and update `VPC_SUBNET` in your `.env` to match.
Then skip to **A4**.

If no subnet exists in your region — create one:

```bash
gcloud compute networks subnets create $VPC_SUBNET \
  --network $VPC_NETWORK \
  --region $REGION \
  --range 10.0.0.0/20 \
  --project $PROJECT_ID
```

> The `--range 10.0.0.0/20` gives you 4096 IP addresses. Adjust this range if it conflicts
> with other subnets already in your network. A `/20` is sufficient for most workloads.

**A4. Verify Cloud Router and NAT exist (required for private nodes)**

If you plan to use private GKE nodes (recommended — no public IPs on your nodes), your
subnet needs a Cloud Router and Cloud NAT so nodes can pull images and make outbound calls
without a public IP.

Check if a Cloud Router already exists in your region:

```bash
gcloud compute routers list \
  --project $PROJECT_ID \
  --filter="region:$REGION"
```

If one exists, check whether it has a NAT gateway attached:

```bash
gcloud compute routers get-nat-mapping-info ROUTER_NAME \
  --region $REGION \
  --project $PROJECT_ID
```

If you see NAT entries — you are good. **Skip to Step 1.4.**

If you have a router but no NAT, or no router at all — create them now:

```bash
# Create the Cloud Router (skip if one already exists)
gcloud compute routers create devops-router \
  --network $VPC_NETWORK \
  --region $REGION \
  --project $PROJECT_ID

# Attach a NAT gateway to it
gcloud compute routers nats create devops-nat \
  --router devops-router \
  --region $REGION \
  --project $PROJECT_ID \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges
```

Your existing VPC is ready. **Skip to Step 1.4.**

---

#### Path B — I need to create a new VPC

**B1. Create a custom mode VPC network**

```bash
gcloud compute networks create $VPC_NETWORK \
  --subnet-mode custom \
  --project $PROJECT_ID
```

Custom mode means subnets are only created where and how you specify — nothing is
created automatically.

**B2. Create a subnet in your region**

This subnet is where your GKE nodes and Cloud Run egress traffic will live:

```bash
gcloud compute networks subnets create $VPC_SUBNET \
  --network $VPC_NETWORK \
  --region $REGION \
  --range 10.0.0.0/20 \
  --project $PROJECT_ID
```

**B3. Create a Cloud Router**

The Cloud Router manages dynamic routing for the VPC. It is also needed for the NAT
gateway in the next step:

```bash
gcloud compute routers create devops-router \
  --network $VPC_NETWORK \
  --region $REGION \
  --project $PROJECT_ID
```

**B4. Create a Cloud NAT gateway**

Private GKE nodes have no public IP addresses. Cloud NAT lets them make outbound internet
requests (e.g. to pull Docker base images) without being directly reachable from the internet:

```bash
gcloud compute routers nats create devops-nat \
  --router devops-router \
  --region $REGION \
  --project $PROJECT_ID \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges
```

**B5. Create a firewall rule allowing internal traffic**

This rule allows all traffic between resources inside the VPC — GKE pods talking to each
other, Cloud Run reaching the internal ingress, and so on:

```bash
gcloud compute firewall-rules create devops-allow-internal \
  --network $VPC_NETWORK \
  --project $PROJECT_ID \
  --allow tcp,udp,icmp \
  --source-ranges 10.0.0.0/8 \
  --description "Allow internal traffic between all resources in the VPC"
```

**B6. Verify the network is ready**

```bash
gcloud compute networks describe $VPC_NETWORK \
  --project $PROJECT_ID \
  --format="value(name,autoCreateSubnetworks,subnetworks)"
```

You should see your network name, `false` for autoCreateSubnetworks, and at least one
subnet listed. Your VPC is ready to use.

---

### Step 1.4 — GKE Cluster Setup

Follow the path that matches your situation.

---

#### Path A — I already have a cluster

**A1. Find your cluster name and type**

List all clusters in your project to confirm the name and whether it is zonal or regional:

```bash
gcloud container clusters list --project $PROJECT_ID
```

The output shows a `LOCATION` column. If it shows a zone (e.g. `us-central1-a`) it is a
zonal cluster. If it shows a region (e.g. `us-central1`) it is a regional cluster. Update
`CLUSTER_NAME` and `ZONE` or `REGION` in your `.env` to match what you see here.

**A2. Check that it is VPC-native**

This setup requires VPC-native mode (also called alias IP). A cluster that is not VPC-native
cannot support the internal ingress.

For a zonal cluster:

```bash
gcloud container clusters describe $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --format="value(ipAllocationPolicy.useIpAliases)"
```

For a regional cluster:

```bash
gcloud container clusters describe $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --format="value(ipAllocationPolicy.useIpAliases)"
```

If the output is `true` — your cluster is VPC-native. Skip to **A3**.

If the output is `false` or empty — your cluster is not VPC-native. VPC-native mode cannot
be enabled on an existing cluster after creation. You have two options:

- **Recommended:** Create a new cluster using Path B below. Migrate your workloads to it.
- **Alternative:** If you cannot create a new cluster right now, you can still use this
  architecture but the internal ingress will need a `NodePort` workaround instead of a
  standard `gce-internal` ingress. This is more complex and not covered in this guide.

**A3. Check the cluster is on the right VPC**

Confirm your existing cluster is on the same VPC that Cloud Run will use for egress,
otherwise Cloud Run will not be able to reach the internal ingress even with DNS working:

```bash
gcloud container clusters describe $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --format="value(network,subnetwork)"
```

The output should show `$VPC_NETWORK` and `$VPC_SUBNET`. If it shows a different network,
update `VPC_NETWORK` and `VPC_SUBNET` in your `.env` to match your cluster's actual network
before continuing — all subsequent steps depend on these values being correct.

**A4. Check the Kubernetes version supports internal ingress**

The `gce-internal` ingress class requires GKE 1.17 or later. Check your cluster version:

```bash
gcloud container clusters describe $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --format="value(currentMasterVersion)"
```

If the version is below `1.17`, upgrade the cluster master:

```bash
# Zonal cluster
gcloud container clusters upgrade $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --master

# Regional cluster
gcloud container clusters upgrade $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --master
```

This takes 5–10 minutes and does not affect running workloads.

Your existing cluster is ready. **Skip to Step 1.5** to whitelist your machine before connecting.

---

#### Path B — I need to create a new cluster

Choose one of the two options below based on your availability needs.

**Option B1 — Zonal cluster**

All nodes live in a single zone (`$ZONE`). Simpler to manage and lower cost. Suitable for
development environments or workloads that do not need cross-zone redundancy.

```bash
gcloud container clusters create $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --network $VPC_NETWORK \
  --subnetwork $VPC_SUBNET \
  --enable-ip-alias \
  --enable-private-nodes \
  --master-ipv4-cidr 172.16.0.0/28 \
  --num-nodes 1
```

**Option B2 — Regional cluster**

Nodes are spread across all zones in `$REGION`. If one zone goes down the cluster keeps
running. Use this for production workloads that need high availability.

```bash
gcloud container clusters create $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --network $VPC_NETWORK \
  --subnetwork $VPC_SUBNET \
  --enable-ip-alias \
  --enable-private-nodes \
  --master-ipv4-cidr 172.16.0.0/28 \
  --num-nodes 1
```

> `--num-nodes 1` means 1 node **per zone**. Since `us-central1` has 3 zones, you get
> 3 nodes total. Increase this number if you need more capacity per zone.

Cluster creation takes 5–10 minutes either way.

### Step 1.5 — Authorize your machine to reach the cluster control plane

Because the cluster was created with `--enable-private-nodes`, the control plane is not
publicly reachable by default. Any machine that needs to run `kubectl` commands — including
your local machine — must be explicitly whitelisted by IP address. Without this step,
`kubectl` will hang with an `i/o timeout` error even though your credentials are correct.

**Get your current public IP:**

```bash
curl -s https://ifconfig.me
```

**Whitelist it on the cluster:**

Zonal cluster:

```bash
gcloud container clusters update $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --enable-master-authorized-networks \
  --master-authorized-networks $(curl -s https://ifconfig.me)/32
```

Regional cluster:

```bash
gcloud container clusters update $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --enable-master-authorized-networks \
  --master-authorized-networks $(curl -s https://ifconfig.me)/32
```

> **Your IP is dynamic.** Most home and office internet connections change IP address when
> you reconnect. If `kubectl` suddenly stops working after it was working before, re-run
> the command above with your new IP. For a team or a CI/CD environment, whitelist a static
> IP instead — such as a VPN gateway or a bastion host — so you only need to do this once:
>
> ```bash
> # Example: whitelist a static office or VPN IP instead of a dynamic one
> gcloud container clusters update $CLUSTER_NAME \
>   --zone $ZONE \
>   --project $PROJECT_ID \
>   --enable-master-authorized-networks \
>   --master-authorized-networks 203.0.113.5/32
> ```

Check whitelisted IPs

```bash
gcloud container clusters describe $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --format="table(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)"
```

### Step 1.6 — Connect kubectl to your cluster

This tells `kubectl` which cluster to talk to. Use the command that matches your cluster type:

**Zonal cluster:**

```bash
gcloud container clusters get-credentials $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID
```

**Regional cluster:**

```bash
gcloud container clusters get-credentials $CLUSTER_NAME \
  --region $REGION \
  --project $PROJECT_ID
```

Verify it worked — you should see a list of nodes:

```bash
kubectl get nodes
```

If you still see an `i/o timeout` error after running this, your IP has not been whitelisted
yet. Go back to Step 1.5 and re-run the authorize command.

If you see a different error, double-check `$CLUSTER_NAME`, `$ZONE`, and `$PROJECT_ID`
in your `.env`.

### Step 1.7 — Reserve a static internal IP address

This IP will be permanently assigned to the internal ingress load balancer. Reserving it
upfront means the IP never changes, even if you recreate the ingress.

Static IP addresses are regional resources — always use `$REGION` here:

```bash
gcloud compute addresses create $INTERNAL_IP_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --subnet $VPC_SUBNET \
  --purpose SHARED_LOADBALANCER_VIP
```

Print and **write down the IP address** — you will need it in Phase 3:

```bash
gcloud compute addresses describe $INTERNAL_IP_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --format "value(address)"
```

It looks something like `10.128.0.45`. We refer to this as `INTERNAL_LB_IP` from here on.

---

## Phase 2 — Deploy Service A and Service B to GKE

### Step 2.1 — Register Kubernetes Service objects first

Apply the manifests for both GKE services before building the images. This creates the
ClusterIP Service objects, which the ingress needs as routing targets. The pods will fail to
start at this point because the Docker images do not exist yet — that is expected and fine.

```bash
kubectl apply -f k8s/service-a/deployment.yaml --namespace $K8S_NAMESPACE
kubectl apply -f k8s/service-b/deployment.yaml --namespace $K8S_NAMESPACE
```

### Step 2.2 — Build and deploy Service A

Run this from the root of the monorepo:

```bash
bash services/service-a/deploy.sh
```

The script does four things:

1. Authenticates Docker with Artifact Registry
2. Builds the Docker image from `services/service-a/Dockerfile`
3. Pushes the image to `$IMAGE_REGISTRY/service-a:latest`
4. Applies the Kubernetes manifest and waits until pods are healthy

### Step 2.3 — Build and deploy Service B

```bash
bash services/service-b/deploy.sh
```

### Step 2.4 — Verify both services are running

```bash
kubectl get pods --namespace $K8S_NAMESPACE
```

Pods for `service-a` and `service-b` should both show status `Running`. If any pod shows
`CrashLoopBackOff`, check its logs:

```bash
kubectl logs deployment/service-a --namespace $K8S_NAMESPACE
kubectl logs deployment/service-b --namespace $K8S_NAMESPACE
```

### Step 2.5 — Confirm ClusterIP DNS works inside the cluster

Verify that Service A can reach Service B using the Kubernetes internal DNS name.
This DNS name only resolves from inside the cluster — that is by design.

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

This phase creates the single private entry point that Cloud Run uses to reach all services
inside GKE without going through the public internet.

### Step 3.1 — Apply the ingress manifest

#### A.1 — Install the nginx ingress controller

Install using the official manifest — no Helm required:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
```

Wait for the controller pod to be ready:

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Verify the controller is running and has been assigned a public IP:

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
kubectl get ingressclass
```

You should see a `LoadBalancer` service with an `EXTERNAL-IP` — that is your public entry
point for external traffic. You should also see an `nginx` IngressClass created automatically
by the manifest.

#### A.2 — Get your reserved internal IP

Unlike GCE ingress which looks up the IP by name automatically, the nginx internal Service
requires the actual IP address. Retrieve it now:

```bash
gcloud compute addresses describe $INTERNAL_IP_NAME \
  --region $REGION \
  --project $PROJECT_ID \
  --format "value(address)"
```

Save this value — you need it in the next step.

#### A.3 — Apply the nginx ingress manifest

Open `k8s/ingress/ingress-nginx.yaml` and paste your internal IP into the `loadBalancerIP`
field:

```yaml
spec:
  loadBalancerIP: "YOUR_INTERNAL_LB_IP_HERE" # ← replace this
```

Then apply:

```bash
kubectl apply -f k8s/ingress/ingress-nginx.yaml --namespace $K8S_NAMESPACE
```

Watch the internal LoadBalancer Service until it gets the IP assigned:

```bash
kubectl get svc ingress-nginx-internal -n ingress-nginx --watch
```

Once `EXTERNAL-IP` shows your internal IP, the internal load balancer is live. Press
`Ctrl+C`.

Then check the ingresses are healthy:

```bash
kubectl get ingress --namespace $K8S_NAMESPACE
```

## Both should show an `ADDRESS` within a minute or two.

#### B.1 - Update cluster to use google load balancer if not using nginx

```bash
gcloud container clusters update $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --update-addons HttpLoadBalancing=ENABLED

# verify
kubectl get pods -n kube-system | grep -i ingress
```

#### B.2 - Verify the ingress

```bash
kubectl apply -f k8s/ingress/ingress.yaml --namespace $K8S_NAMESPACE
```

Watch until both ingresses show an IP in the `ADDRESS` column:

```bash
kubectl get ingress --namespace $K8S_NAMESPACE --watch
```

This takes 3–5 minutes. Press `Ctrl+C` once both show an IP.

#### B.3 — Confirm the internal ingress got the reserved IP

```bash
kubectl get ingress internal-ingress \
  --namespace $K8S_NAMESPACE \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

This should match the `INTERNAL_LB_IP` you wrote down in Step 1.7. If it shows a different
IP, check that the `kubernetes.io/ingress.regional-static-ip-name` annotation in
`k8s/ingress/ingress.yaml` exactly matches your `$INTERNAL_IP_NAME`, then reapply.

### Step 3.3 — Create a Cloud DNS private zone

A private zone works like regular DNS except it only resolves from inside your VPC.
The public internet cannot see or use names in this zone. DNS zones are global resources —
there is no `--region` or `--zone` flag here.

```bash
gcloud dns managed-zones create $DNS_ZONE_NAME \
  --description "Private DNS zone for internal GKE service routing" \
  --dns-name "$INTERNAL_GATEWAY_HOST." \
  --visibility private \
  --networks $VPC_NETWORK \
  --project $PROJECT_ID
```

> The trailing dot after `$INTERNAL_GATEWAY_HOST.` is required — DNS names always end with a dot.

### Step 3.4 — Create the DNS A record pointing to the internal ingress IP

Replace `INTERNAL_LB_IP` with the IP you saved in Step 1.7:

```bash
gcloud dns record-sets create "$INTERNAL_GATEWAY_HOST." \
  --zone $DNS_ZONE_NAME \
  --type A \
  --ttl 300 \
  --rrdatas INTERNAL_LB_IP \
  --project $PROJECT_ID
```

**This is the only DNS record you will ever need for this architecture.** When you add
service #10, #50, or #100, you only add a path to the ingress — not a new DNS record.

If the internal load balancer IP ever changes, update just this one record:

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

This builds the image, pushes it, and deploys it to Cloud Run with VPC egress enabled.
At the end the script prints the Cloud Run URL and the exact `kubectl` command to store
it as a Kubernetes secret. **Copy and run that command.** It looks like:

```bash
kubectl create secret generic service-urls \
  --from-literal=service-c-url=https://service-c-xxxx-uc.a.run.app \
  --namespace $K8S_NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then restart Service A to pick up the new secret:

```bash
kubectl rollout restart deployment/service-a --namespace $K8S_NAMESPACE
```

### Step 4.2 — Grant Service A permission to invoke Service C

Cloud Run requires authentication by default. This grants Service A's service account the
permission to call Service C. Cloud Run IAM is a regional resource — use `$REGION`:

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud run services add-iam-policy-binding service-c \
  --region $REGION \
  --project $PROJECT_ID \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/run.invoker
```

### Step 4.3 — Verify Cloud Run can resolve the internal DNS hostname

Deploy a one-off Cloud Run job that runs `nslookup` inside the VPC to confirm
`$INTERNAL_GATEWAY_HOST` resolves to the correct IP. Cloud Run jobs are regional:

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

The logs should show `INTERNAL_LB_IP` in the output. If you see `NXDOMAIN`, go back to
Step 3.3 and verify the `--networks` flag matches `$VPC_NETWORK`.

Clean up the test job:

```bash
gcloud run jobs delete dns-check \
  --region $REGION \
  --project $PROJECT_ID \
  --quiet
```

---

## Phase 5 — End-to-End Verification

### Step 5.1 — Test standard path: external → A → B

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

### Step 5.2 — Test heavy path: external → A → C → back into cluster

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

Run this from your local machine, which is outside the VPC. It should time out:

```bash
curl --connect-timeout 5 http://INTERNAL_LB_IP/health
```

Expected: `curl: (28) Connection timed out` — this is correct and intentional.

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

### Step 6.1 — Deploy the new service as ClusterIP only

Create a standard `Deployment` and `Service` of type `ClusterIP` for your new service.
No load balancer. No DNS changes. No changes to any other service.

### Step 6.2 — Add one path to the internal ingress

Open `k8s/ingress/ingress.yaml` and add your new path in the `internal-ingress` rules:

```yaml
- path: /service-x
  pathType: Prefix
  backend:
    service:
      name: service-x
      port:
        number: 8080
```

Apply it:

```bash
kubectl apply -f k8s/ingress/ingress.yaml --namespace $K8S_NAMESPACE
```

### Step 6.3 — Call it from Cloud Run with no extra config

```javascript
const SERVICE_X_URL = `${process.env.INTERNAL_GATEWAY_URL}/service-x`;
```

No new environment variables. No new DNS records. No new load balancers.

---

## Deploying Individual Services

Each service deploys independently from the root of the monorepo:

```bash
# Deploy only Service A (e.g. after a code change)
bash services/service-a/deploy.sh

# Deploy only Service B
bash services/service-b/deploy.sh

# Deploy only Service C
bash services/service-c/deploy.sh

# Deploy with a specific version tag
bash services/service-a/deploy.sh v1.4.2
```

---

## Quick Reference: Region vs Zone per Command

| Command / Resource                                     | Flag to use                          |
| ------------------------------------------------------ | ------------------------------------ |
| `gcloud container clusters create` (zonal)             | `--zone $ZONE`                       |
| `gcloud container clusters create` (regional)          | `--region $REGION`                   |
| `gcloud container clusters get-credentials` (zonal)    | `--zone $ZONE`                       |
| `gcloud container clusters get-credentials` (regional) | `--region $REGION`                   |
| `gcloud compute addresses create`                      | `--region $REGION`                   |
| `gcloud compute addresses describe`                    | `--region $REGION`                   |
| `gcloud artifacts repositories create`                 | `--location $REGION`                 |
| `gcloud run deploy`                                    | `--region $REGION`                   |
| `gcloud run services add-iam-policy-binding`           | `--region $REGION`                   |
| `gcloud run jobs create / execute / delete`            | `--region $REGION`                   |
| `gcloud dns managed-zones create`                      | _(no location flag — DNS is global)_ |
| `gcloud dns record-sets create`                        | _(no location flag)_                 |

---

## Troubleshooting

**`kubectl get nodes` hangs with `i/o timeout`**

Your machine's IP is not whitelisted on the cluster control plane. This always happens on
private clusters unless you explicitly authorize each machine. Run:

```bash
gcloud container clusters update $CLUSTER_NAME \
  --zone $ZONE \
  --project $PROJECT_ID \
  --enable-master-authorized-networks \
  --master-authorized-networks $(curl -s https://ifconfig.me)/32
```

If it worked before but stopped working, your public IP has changed. Re-run the command
above — it replaces the previously whitelisted IP with your current one.

**Pods stuck in `CrashLoopBackOff`**

```bash
kubectl describe pod -l app=service-a --namespace $K8S_NAMESPACE
kubectl logs deployment/service-a --namespace $K8S_NAMESPACE --previous
```

**Internal ingress has no IP after 10+ minutes**

Check that the `kubernetes.io/ingress.regional-static-ip-name` annotation in
`k8s/ingress/ingress.yaml` exactly matches `$INTERNAL_IP_NAME`, and that the address was
reserved using `$REGION` (not a zone — compute addresses are regional).

**Cloud Run returns 403 when calling through the internal ingress**

A 403 typically means a firewall rule is blocking the traffic. Verify your VPC allows
inbound traffic on port 80 from the Cloud Run subnet IP range.

**`nslookup $INTERNAL_GATEWAY_HOST` returns NXDOMAIN from Cloud Run**

The Cloud DNS private zone must be attached to the same VPC network Cloud Run uses for
egress. Verify the `--networks` flag in Step 3.3 matches `$VPC_NETWORK`. Also confirm
Service C was deployed with `--vpc-egress=all-traffic`.

**Service C cannot reach `http://$INTERNAL_GATEWAY_HOST`**

Check that VPC egress is configured on the Cloud Run service:

```bash
gcloud run services describe service-c \
  --region $REGION \
  --project $PROJECT_ID \
  --format "value(spec.template.metadata.annotations)"
```

Look for `run.googleapis.com/vpc-access-egress: all-traffic`. If missing, redeploy
Service C using its `deploy.sh`.

**kubectl is pointing at the wrong cluster**

Re-run the `get-credentials` command from Step 1.4 with the correct `$ZONE` or `$REGION`
and `$CLUSTER_NAME` values.

---

## Repository Structure

```
monorepo/
├── .env.example              ← copy to .env and review values
├── .env                      ← your actual config (never commit this)
├── .gitignore
├── SETUP.md                  ← this file
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
