# GCP Permissions Reference

> Minimal IAM roles and permissions for operating as a **Cloud Run + GKE DevOps Engineer**
> and **Cloud Architect** on Google Cloud Platform.
>
> All roles listed are predefined GCP roles unless marked `[custom]`.
> Apply at the **project level** unless noted otherwise.

---

## Quick Reference — Role Summary

| Role                                    | What it covers                                           |
| --------------------------------------- | -------------------------------------------------------- |
| `roles/container.developer`             | Deploy, manage, and debug GKE workloads                  |
| `roles/container.admin`                 | Create and delete GKE clusters                           |
| `roles/run.developer`                   | Deploy and manage Cloud Run services                     |
| `roles/run.admin`                       | Full Cloud Run including IAM on services                 |
| `roles/compute.networkAdmin`            | VPC, subnets, firewall rules, routes                     |
| `roles/compute.loadBalancerAdmin`       | Internal/external load balancers, NEGs, forwarding rules |
| `roles/dns.admin`                       | Cloud DNS zones and records                              |
| `roles/compute.securityAdmin`           | Firewall rules, SSL certs, security policies             |
| `roles/iam.serviceAccountUser`          | Act as / attach service accounts to resources            |
| `roles/iam.serviceAccountAdmin`         | Create and manage service accounts                       |
| `roles/artifactregistry.writer`         | Push Docker images                                       |
| `roles/artifactregistry.reader`         | Pull Docker images                                       |
| `roles/artifactregistry.admin`          | Create and manage repos                                  |
| `roles/storage.admin`                   | GCS buckets (build artifacts, Terraform state)           |
| `roles/logging.viewer`                  | Read logs in Cloud Logging                               |
| `roles/monitoring.viewer`               | View metrics and dashboards                              |
| `roles/monitoring.editor`               | Create alerting policies and dashboards                  |
| `roles/serviceusage.serviceUsageAdmin`  | Enable/disable GCP APIs                                  |
| `roles/resourcemanager.projectIamAdmin` | Grant IAM roles to others on the project                 |

---

## 1. Service Mesh Setup (This Project)

Minimum roles needed to run `setup-mesh.sh` against a client project.

### Required Roles

```
roles/compute.networkAdmin
roles/compute.loadBalancerAdmin
roles/compute.securityAdmin
roles/container.admin
roles/run.admin
roles/dns.admin
roles/iam.serviceAccountUser
roles/artifactregistry.admin
roles/serviceusage.serviceUsageAdmin
```

### What each one unlocks in the mesh setup

| Phase           | Action                                                                | Role Required                                         |
| --------------- | --------------------------------------------------------------------- | ----------------------------------------------------- |
| Phase 0         | Enable GCP APIs                                                       | `serviceusage.serviceUsageAdmin`                      |
| Phase 1         | Create VPC, subnets, Cloud NAT, Cloud Router                          | `compute.networkAdmin`                                |
| Phase 1         | Create firewall rules                                                 | `compute.securityAdmin`                               |
| Phase 2         | Create GKE cluster                                                    | `container.admin`                                     |
| Phase 2         | Get cluster credentials (`gcloud container clusters get-credentials`) | `container.admin`                                     |
| Phase 3         | Reserve static internal IPs                                           | `compute.networkAdmin`                                |
| Phase 4         | Create NEG, backend service, URL map, HTTP proxy, forwarding rule     | `compute.loadBalancerAdmin`                           |
| Phase 5         | `kubectl apply` — deploy nginx gateway pod and service                | `container.developer` (included in `container.admin`) |
| Phase 6         | `kubectl apply` — deploy nginx public controller                      | `container.developer`                                 |
| Phase 7         | `kubectl apply` — internal ALB bridge ClusterIP + Endpoints           | `container.developer`                                 |
| Phase 8         | Create DNS zone and wildcard records                                  | `dns.admin`                                           |
| Phase 9–10      | Apply Kubernetes manifests                                            | `container.developer`                                 |
| Deploy services | Push images to Artifact Registry                                      | `artifactregistry.admin`                              |
| Deploy services | Deploy Cloud Run services                                             | `run.admin`                                           |
| Deploy services | Attach service accounts to Cloud Run                                  | `iam.serviceAccountUser`                              |

---

## 2. GKE DevOps Engineer

Day-to-day role for managing workloads on an existing cluster. Does **not** create or delete clusters.

```
roles/container.developer
roles/artifactregistry.writer
roles/logging.viewer
roles/monitoring.viewer
roles/iam.serviceAccountUser
```

### What you can do

- `kubectl apply`, `kubectl get`, `kubectl logs`, `kubectl exec`, `kubectl port-forward`
- Build and push Docker images to Artifact Registry
- Read application logs in Cloud Logging
- View metrics in Cloud Monitoring
- Attach service accounts to pods and deployments

### What you cannot do

- Create or delete GKE clusters (`container.admin` required)
- Modify VPC or firewall rules (`compute.networkAdmin` required)
- Grant IAM roles to others (`resourcemanager.projectIamAdmin` required)

---

## 3. Cloud Run DevOps Engineer

Day-to-day role for deploying and managing Cloud Run services.

```
roles/run.developer
roles/artifactregistry.writer
roles/logging.viewer
roles/monitoring.viewer
roles/iam.serviceAccountUser
```

### What you can do

- Deploy, update, and delete Cloud Run services
- Manage Cloud Run revisions and traffic splits
- Set environment variables, secrets, VPC connectors on services
- Push Docker images to Artifact Registry
- View logs and metrics

### What you cannot do

- Modify Cloud Run IAM policies (`run.admin` required)
- Create or delete VPC connectors (`compute.networkAdmin` required)
- Create DNS records (`dns.admin` required)

### Difference between `run.developer` and `run.admin`

| Action                                       | `run.developer` | `run.admin` |
| -------------------------------------------- | --------------- | ----------- |
| Deploy / update services                     | ✅              | ✅          |
| Delete services                              | ✅              | ✅          |
| Set IAM policy on a service (make it public) | ❌              | ✅          |
| View IAM policy on a service                 | ✅              | ✅          |

---

## 4. Networking Engineer

Role for managing VPC infrastructure, load balancers, DNS, and firewall rules.

```
roles/compute.networkAdmin
roles/compute.loadBalancerAdmin
roles/compute.securityAdmin
roles/dns.admin
```

### What you can do

**VPC & Subnets**

- Create, modify, delete VPCs and subnets
- Manage secondary IP ranges
- Create proxy-only subnets for Internal ALB
- Enable Private Google Access on subnets

**Load Balancers**

- Create Internal and External ALBs
- Manage forwarding rules, target proxies, URL maps, backend services
- Create and manage NEGs (Zonal, Serverless, Internet)
- Manage health checks

**Firewall**

- Create, modify, delete firewall rules
- Manage firewall policies
- Create SSL certificates

**DNS**

- Create private and public DNS zones
- Add, modify, delete DNS records (A, CNAME, MX, TXT, etc.)
- Manage DNS peering

**NAT & Routing**

- Create and manage Cloud Routers
- Create and manage Cloud NAT
- Manage static and dynamic routes

### What you cannot do

- Create GKE clusters (`container.admin` required)
- Deploy Cloud Run services (`run.developer` required)
- Modify IAM policies (`resourcemanager.projectIamAdmin` required)

---

## 5. Cloud Architect (Full Access)

Full operational access across all layers. Does **not** include project creation/deletion or billing management.

```
roles/container.admin
roles/run.admin
roles/compute.networkAdmin
roles/compute.loadBalancerAdmin
roles/compute.securityAdmin
roles/dns.admin
roles/iam.serviceAccountAdmin
roles/iam.serviceAccountUser
roles/artifactregistry.admin
roles/storage.admin
roles/logging.admin
roles/monitoring.editor
roles/serviceusage.serviceUsageAdmin
roles/resourcemanager.projectIamAdmin
```

### What you can do

Everything in sections 2–4 plus:

- Create and delete GKE clusters
- Create, configure, and delete VPCs, subnets, NAT, routers
- Create and manage service accounts and their keys
- Grant and revoke IAM roles on the project
- Enable and disable GCP APIs
- Create and manage Artifact Registry repositories
- Full Cloud Storage access (Terraform state, build artifacts)
- Full log management and alerting setup

### What you cannot do

- Create or delete the GCP project itself (`resourcemanager.projectCreator` required — usually only `Owner`)
- Manage billing (`billing.admin` required — separate from project IAM)
- Access the GCP Organization level (`roles/resourcemanager.organizationAdmin` required — granted at org, not project)

---

## 6. Read-Only / Auditor

For reviewing infrastructure without making changes. Useful for security audits, client handoffs, onboarding.

```
roles/viewer
roles/container.viewer
roles/run.viewer
roles/dns.reader
roles/logging.viewer
roles/monitoring.viewer
```

> `roles/viewer` is a basic role that grants read access to most GCP services.
> The additional roles fill in gaps where `viewer` doesn't cover.

---

## How to Grant These Roles

### Via gcloud (replace values as needed)

```bash
# Grant a role to a user
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="user:engineer@example.com" \
  --role="roles/container.developer"

# Grant a role to a service account
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:deploy-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.developer"

# Grant multiple roles at once (loop)
ROLES=(
  "roles/container.developer"
  "roles/run.developer"
  "roles/artifactregistry.writer"
  "roles/logging.viewer"
  "roles/iam.serviceAccountUser"
)
for ROLE in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding PROJECT_ID \
    --member="user:engineer@example.com" \
    --role="${ROLE}"
done
```

### Via GCP Console

`IAM & Admin` → `IAM` → `Grant Access` → enter email → add roles → Save

---

## Notes on Working in Client Projects

- Always request roles at the **project level**, not organization level, unless you specifically need cross-project access
- Prefer **service accounts** over personal accounts for CI/CD pipelines and automation scripts
- `iam.serviceAccountUser` is required any time you attach a service account to a resource (Cloud Run service, GKE node pool, Cloud Build trigger). Without it, deploy commands fail with a permission denied even if you have `run.admin`
- `serviceusage.serviceUsageAdmin` is needed to enable APIs. On a fresh project, almost every `gcloud` command will fail until the relevant API is enabled. This is often the first permission to check if you get unexpected errors on a new project
- `resourcemanager.projectIamAdmin` lets you grant roles to others. If the client needs to grant you access themselves and you're setting up CI/CD service accounts, you'll need this role to complete the setup — request it upfront
