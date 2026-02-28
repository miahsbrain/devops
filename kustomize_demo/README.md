# Kustomize Demo 🚀

A complete hands-on demo showing how Kustomize works with `staging` and `prod` overlays.

## Project Structure

```
kustomize-demo/
├── base/                        # Shared "source of truth"
│   ├── kustomization.yaml       # Lists all base resources
│   ├── deployment.yaml          # Base deployment (1 replica, no limits)
│   ├── service.yaml             # ClusterIP service
│   └── configmap.yaml           # Base config + HTML page
│
├── overlays/
│   ├── staging/
│   │   ├── kustomization.yaml   # Staging overrides
│   │   └── resource-patch.yaml  # Low CPU/mem limits for staging
│   │
│   └── prod/
│       ├── kustomization.yaml   # Prod overrides
│       ├── resource-patch.yaml  # Higher CPU/mem for prod
│       └── strategy-patch.yaml  # RollingUpdate with zero downtime
│
├── setup.sh                     # Run this to deploy everything
└── cleanup.sh                   # Tear it all down
```

## Quick Start

```bash
# 1. Make scripts executable
chmod +x setup.sh cleanup.sh

# 2. Run setup (creates cluster + deploys staging + prod)
./setup.sh

# 3. In a new terminal — access staging
kubectl port-forward svc/web-app 8081:80 -n staging
# Open: http://localhost:8081

# 4. In a new terminal — access prod
kubectl port-forward svc/web-app 8082:80 -n prod
# Open: http://localhost:8082

# 5. Cleanup when done
./cleanup.sh
```

## Key Kustomize Concepts This Demo Shows

### 1. `base/` — The DRY foundation
All environments share the same Deployment, Service, and ConfigMap definitions.
No duplication. Changes here flow to ALL overlays automatically.

### 2. Overlays — Environment-specific overrides
An overlay is just a folder with a `kustomization.yaml` that references the base and adds changes.

### 3. Patches — Two styles shown here

**JSON 6902 patch** (inline, surgical):
```yaml
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
    target:
      kind: Deployment
      name: web-app
```

**Strategic Merge Patch** (via file — looks like a partial manifest):
```yaml
# resource-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  template:
    spec:
      containers:
        - name: web-app
          resources:
            limits:
              cpu: "500m"
```
Kustomize merges this ON TOP of the base — only the fields you specify are changed.

### 4. ConfigMapGenerator — Hash-based cache busting
```yaml
configMapGenerator:
  - name: web-app-config
    behavior: merge       # merge = extend base values
    literals:
      - ENVIRONMENT=staging
```
Kustomize automatically appends a hash to ConfigMap names (e.g., `web-app-config-k7m8n`).
This forces Kubernetes to **restart pods** when config changes — no more stale config!

### 5. Namespace isolation
Each overlay sets its own `namespace:` — staging pods go to `staging` namespace,
prod pods go to `prod` namespace. Clean separation, same manifests.

### 6. Common Labels & Annotations
```yaml
commonLabels:
  environment: staging
commonAnnotations:
  team: "platform-eng"
```
Applied to EVERY resource in the overlay automatically.

## What Changes Between Environments?

| Feature             | Staging          | Prod                    |
|---------------------|------------------|-------------------------|
| Namespace           | `staging`        | `prod`                  |
| Replicas            | 1                | 3                       |
| CPU request/limit   | 50m / 200m       | 100m / 500m             |
| Memory request/limit| 64Mi / 128Mi     | 128Mi / 256Mi           |
| ENVIRONMENT env var | `staging`        | `prod`                  |
| LOG_LEVEL           | `debug`          | `warn`                  |
| Update strategy     | default          | RollingUpdate (0 downtime) |
| HTML page color     | Yellow           | Green                   |

## Useful Commands

```bash
# Preview what kustomize WOULD apply (without applying)
kubectl kustomize overlays/staging
kubectl kustomize overlays/prod

# Diff: what would change if you re-apply?
kubectl diff -k overlays/staging
kubectl diff -k overlays/prod

# Watch pods in real time
kubectl get pods -n staging -w
kubectl get pods -n prod -w

# See the final rendered deployment for prod
kubectl kustomize overlays/prod | grep -A 50 "kind: Deployment"

# Describe a pod to see labels/annotations kustomize added
kubectl describe pod -n prod -l app=web-app | head -40
```

## Cleanup

```bash
./cleanup.sh
# or manually:
k3d cluster delete kustomize-demo
```
