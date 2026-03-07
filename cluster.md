# GKE Cluster Management Commands

### A Beginner-Friendly Reference Guide for Google Cloud (gcloud CLI)

> 💡 **Before you start:** Replace anything in `< >` brackets with your actual values.
> For example, `<cluster-name>` becomes whatever your cluster is named (e.g. `my-app-cluster`).

---

## 📋 Table of Contents

1. [Check Your Clusters](#1-check-your-clusters)
2. [Check Your Nodes](#2-check-your-nodes)
3. [Check Resource Usage (CPU & Memory)](#3-check-resource-usage-cpu--memory)
4. [Resize Your Cluster (Add or Remove Nodes)](#4-resize-your-cluster-add-or-remove-nodes)
5. [Enable Autoscaling](#5-enable-autoscaling)
6. [Disable Autoscaling](#6-disable-autoscaling)
7. [Change Machine Type (Upgrade CPU & Memory)](#7-change-machine-type-upgrade-cpu--memory)
8. [Your Exact Cluster Values (Ready to Use)](#8-your-exact-cluster-values-ready-to-use)

---

## 1. Check Your Clusters

**What this does:** Lists all GKE clusters in your GCP project, along with their name, location, machine type, number of nodes, and status.

```bash
gcloud container clusters list
```

**Example output:**

```
NAME                LOCATION       MACHINE_TYPE   NUM_NODES  STATUS
my-app-cluster      us-central1-a  e2-standard-4  1          RUNNING
```

---

**What this does:** Shows detailed information about a specific cluster — including node pools, machine types, autoscaling settings, and more.

```bash
gcloud container clusters describe <cluster-name> \
  --zone=<zone>
```

**Your command:**

```bash
gcloud container clusters describe my-app-cluster \
  --zone=us-central1-a
```

---

## 2. Check Your Nodes

**What this does:** Lists all the node pools in your cluster. A node pool is a group of machines (nodes) that all share the same settings (machine type, size, etc.).

```bash
gcloud container node-pools list \
  --cluster=<cluster-name> \
  --zone=<zone>
```

**Example:**

```bash
gcloud container node-pools list \
  --cluster=my-app-cluster \
  --zone=us-central1-a
```

---

**What this does:** Lists all the actual virtual machines (nodes) that belong to your GKE cluster across your project.

```bash
gcloud compute instances list \
  --filter="labels.goog-gke-node=true"
```

---

## 3. Check Resource Usage (CPU & Memory)

> ⚠️ These commands use `kubectl`, not `gcloud`. Make sure kubectl is connected to your cluster first (see below).

**Step 1 — Connect kubectl to your cluster:**

```bash
gcloud container clusters get-credentials my-app-cluster \
  --zone=us-central1-a
```

---

**What this does:** Shows how much CPU and memory each node is currently using in real time.

```bash
kubectl top nodes
```

**Example output:**

```
NAME                  CPU(cores)  CPU%   MEMORY(bytes)  MEMORY%
gke-node-abc123       850m        21%    5432Mi         34%
```

---

**What this does:** Shows a detailed breakdown of how much CPU and memory is requested vs. available on each node. This helps you see if a node is full.

```bash
kubectl describe nodes
```

Look for the section called **"Allocated resources"** — it will show something like:

```
Resource    Requests    Limits
cpu         3800m/4     0/4       ← 3800 out of 4000 millicores used (95% full!)
memory      12Gi/16Gi   0/16Gi
```

---

**What this does:** Shows CPU and memory usage per pod (each microservice).

```bash
kubectl top pods --all-namespaces --sort-by=cpu
```

---

## 4. Resize Your Cluster (Add or Remove Nodes)

**What this does:** Increases or decreases the number of nodes (machines) in your cluster. Adding nodes gives your cluster more total CPU and memory.

> 💡 This is the **quickest fix** when pods can't schedule due to insufficient CPU.

```bash
gcloud container clusters resize <cluster-name> \
  --node-pool=<node-pool-name> \
  --num-nodes=<number> \
  --zone=<zone>
```

**Example — scale up to 2 nodes (doubles your CPU and memory):**

```bash
gcloud container clusters resize my-app-cluster \
  --node-pool=default-pool \
  --num-nodes=2 \
  --zone=us-central1-a
```

**Example — scale up to 3 nodes:**

```bash
gcloud container clusters resize my-app-cluster \
  --node-pool=default-pool \
  --num-nodes=3 \
  --zone=us-central1-a
```

> ⚠️ You will be prompted to confirm. Type `y` and press Enter.

---

## 5. Enable Autoscaling

**What this does:** Tells GKE to automatically add nodes when your cluster is running out of resources, and remove them when things are quiet. This is ideal for a large app with many microservices — you won't have to manually resize every time.

```bash
gcloud container node-pools update <node-pool-name> \
  --cluster=<cluster-name> \
  --enable-autoscaling \
  --min-nodes=<minimum number of nodes> \
  --max-nodes=<maximum number of nodes> \
  --zone=<zone>
```

**Example (scales between 1 and 5 nodes automatically):**

```bash
gcloud container node-pools update default-pool \
  --cluster=my-app-cluster \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=5 \
  --zone=us-central1-a
```

> 💡 `--min-nodes=1` means GKE will always keep at least 1 node running.
> `--max-nodes=5` means it will never go above 5 nodes (to control cost).

---

## 6. Disable Autoscaling

**What this does:** Turns off autoscaling if you want to manage node count manually.

```bash
gcloud container node-pools update <node-pool-name> \
  --cluster=<cluster-name> \
  --no-enable-autoscaling \
  --zone=<zone>
```

**Example:**

```bash
gcloud container node-pools update default-pool \
  --cluster=my-app-cluster \
  --no-enable-autoscaling \
  --zone=us-central1-a
```

---

## 7. Change Machine Type (Upgrade CPU & Memory)

**What this does:** Upgrades your nodes to a more powerful machine type (more CPU cores and/or RAM).

> ⚠️ GKE does **not** let you change the machine type of an existing node pool directly. The process is:
>
> 1. Create a **new node pool** with the new machine type
> 2. Migrate your workloads to the new pool
> 3. Delete the old pool

---

### Step 1 — Create a new node pool with a better machine type

```bash
gcloud container node-pools create <new-pool-name> \
  --cluster=<cluster-name> \
  --machine-type=<machine-type> \
  --num-nodes=<number> \
  --zone=<zone>
```

**Example (upgrading to e2-standard-8: 8 vCPU, 32GB RAM):**

```bash
gcloud container node-pools create upgraded-pool \
  --cluster=my-app-cluster \
  --machine-type=e2-standard-8 \
  --num-nodes=2 \
  --zone=us-central1-a
```

---

### Step 2 — Drain the old node pool (safely move all workloads off it)

```bash
kubectl cordon <old-node-name>
kubectl drain <old-node-name> --ignore-daemonsets --delete-emptydir-data
```

> 💡 To get the old node names, run: `kubectl get nodes`

---

### Step 3 — Delete the old node pool

```bash
gcloud container node-pools delete default-pool \
  --cluster=my-app-cluster \
  --zone=us-central1-a
```

> ⚠️ Only do this **after** confirming all your pods are running on the new pool.

---

### Common Machine Types & Their Specs

| Machine Type     | vCPU | Memory | Best For                        |
| ---------------- | ---- | ------ | ------------------------------- |
| `e2-standard-2`  | 2    | 8 GB   | Very small/test workloads       |
| `e2-standard-4`  | 4    | 16 GB  | Small clusters ← _you are here_ |
| `e2-standard-8`  | 8    | 32 GB  | Medium workloads                |
| `e2-standard-16` | 16   | 64 GB  | Large microservice applications |
| `n2-standard-8`  | 8    | 32 GB  | Better CPU performance          |
| `n2-standard-16` | 16   | 64 GB  | High-performance large clusters |

---

## 8. Quick Reference — Placeholder Values

Use this table to keep track of your own cluster details as you fill them in:

| Setting      | Placeholder        | Example          |
| ------------ | ------------------ | ---------------- |
| Cluster Name | `<cluster-name>`   | `my-app-cluster` |
| Zone         | `<zone>`           | `us-central1-a`  |
| Machine Type | `<machine-type>`   | `e2-standard-4`  |
| Node Pool    | `<node-pool-name>` | `default-pool`   |
| Num Nodes    | `<number>`         | `2`              |

---

> 💡 **Recommended next steps for a large microservice app:**
>
> 1. Run `gcloud container clusters resize` to add at least 1 more node immediately
> 2. Enable autoscaling so this doesn't happen again as your app grows
> 3. Consider upgrading to `e2-standard-8` or higher if CPU issues persist

List each pod and its resources

```bash
kubectl get pods -n dev -o json | jq -r '
  .items[] |
  .metadata.name + " | req: " +
  .spec.containers[0].resources.requests.memory + " | lim: " +
  .spec.containers[0].resources.limits.memory'
```

Add limit range to cluster to prevent excessive and corrupt memory values, update to your namespace or use the default namespace

limit-range.yml

```bash
apiVersion: v1
kind: LimitRange
metadata:
  name: dev-limit-range
  namespace: dev
spec:
  limits:
  - type: Container
    max:
      memory: 4Gi
      cpu: 500m
    defaultRequest:
      memory: 256Mi
      cpu: 50m
    default:
      memory: 512Mi
      cpu: 100m
```

Register cred in docker

```bash
# Check if it exists
kubectl get secret regcred -n dev

# If missing, recreate it
kubectl create secret docker-registry regcred \
  --docker-server=us-central1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat /path/to/gcp-key.json)" \
  --docker-email=your@email.com \
  -n dev
```

Safe delete for csi, delete all crashing pods to load secrets again

```bash
kubectl get pods -n dev --no-headers | grep -E "CrashLoopBackOff|Error" | awk '{print $1}' | \
  xargs -I {} sh -c 'kubectl delete pod {} -n dev && sleep 10'
```
