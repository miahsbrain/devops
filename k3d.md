# K3d Useful Commands Cheatsheet

## Cluster Management

```bash
# Create a single node cluster
k3d cluster create <cluster-name> --agents 1

# Create cluster with port forwarding (access via localhost)
k3d cluster create <cluster-name> --agents 1 \
  --port "3000:3000@loadbalancer" \
  --port "5000:5000@loadbalancer" \
  --port "8080:80@loadbalancer"

# List clusters
k3d cluster list

# Stop a cluster
k3d cluster stop <cluster-name>

# Start a stopped cluster
k3d cluster start <cluster-name>

# Delete a cluster
k3d cluster delete <cluster-name>

# Switch kubectl context to k3d cluster
kubectl config use-context k3d-<cluster-name>

# View all contexts
kubectl config get-contexts
```

---

## Building & Importing Images

```bash
# Build image locally with Docker
docker build -t <image-name>:<tag> .

# Example
docker build -t inhouzio_app_ms:latest .

# Import local image into k3d cluster
# (skips needing a registry — k3d injects it directly)
k3d image import <image-name>:<tag> -c <cluster-name>

# Example
k3d image import inhouzio_app_ms:latest -c inhouzio-test

# Verify image is available in the cluster
kubectl run test --image=inhouzio_app_ms:latest --image-pull-policy=Never --rm -it -- sh
```

> **Important:** When using a locally imported image, set `imagePullPolicy: Never` in your
> deployment so Kubernetes doesn't try to pull it from a registry:
>
> ```yaml
> containers:
>   - name: inhouzio-app-ms
>     image: inhouzio_app_ms:latest
>     imagePullPolicy: Never
> ```

---

## Applying Manifests

```bash
# Apply a single file
kubectl apply -f <file>.yaml

# Apply entire directory
kubectl apply -f .

# Apply with Kustomize
kubectl apply -k .
kubectl apply -k overlays/staging
kubectl apply -k overlays/prod

# Preview kustomize output without applying
kubectl kustomize .
kubectl kustomize overlays/staging

# Delete resources
kubectl delete -k .
kubectl delete -f <file>.yaml
```

---

## Port Forwarding

```bash
# Forward a service to localhost
kubectl port-forward svc/<service-name> <local-port>:<service-port>

# Example — access app on localhost:5000
kubectl port-forward svc/inhouzio-app-ms-cluster-ip-service 5000:5000

# Forward in a specific namespace
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>

# Forward a pod directly
kubectl port-forward pod/<pod-name> <local-port>:<container-port>

# Run in background
kubectl port-forward svc/<service-name> <local-port>:<service-port> &

# Kill port-forward running in background
pkill -f "kubectl port-forward"
```

---

## Accessing App on Localhost via LoadBalancer

When you create the cluster with `--port` mappings, the app is directly accessible
on `localhost` without needing `port-forward`:

```bash
# Create cluster with port mapped to host
k3d cluster create inhouzio-test --agents 1 \
  --port "5000:5000@loadbalancer"

# Then create a LoadBalancer service instead of ClusterIP
# Change type in your service.yaml:
# spec:
#   type: LoadBalancer   ← instead of ClusterIP
#   ports:
#     - port: 5000
#       targetPort: 5000

# Apply and access directly
kubectl apply -k .
curl http://localhost:5000
# or open http://localhost:5000 in browser
```

---

## Secrets

```bash
# Create a secret from literal values
kubectl create secret generic <secret-name> \
  --from-literal=<KEY>=<value>

# Example
kubectl create secret generic stripeapikey \
  --from-literal=STRIPEAPIKEY=sk_test_xxx

# Create secret in a specific namespace
kubectl create secret generic <secret-name> \
  --from-literal=<KEY>=<value> \
  -n <namespace>

# View secrets (base64 encoded)
kubectl get secret <secret-name> -o yaml

# Decode a secret value
kubectl get secret <secret-name> -o jsonpath='{.data.<KEY>}' | base64 --decode
```

---

## Debugging & Logs

```bash
# Get all resources in current namespace
kubectl get all

# Get all resources in a namespace
kubectl get all -n <namespace>

# Get pods
kubectl get pods
kubectl get pods -n <namespace>
kubectl get pods -w          # watch for changes

# Describe a pod (events, errors, resource usage)
kubectl describe pod <pod-name>

# View pod logs
kubectl logs <pod-name>
kubectl logs <pod-name> -f   # follow/stream logs
kubectl logs <pod-name> --previous  # logs from crashed pod

# Exec into a running pod
kubectl exec -it <pod-name> -- sh
kubectl exec -it <pod-name> -- bash

# Get events (useful for debugging crashes)
kubectl get events --sort-by='.lastTimestamp'

# Check resource usage
kubectl top pods
kubectl top nodes
```

---

## Namespaces

```bash
# Create namespace
kubectl create namespace <name>

# List namespaces
kubectl get namespaces

# Set default namespace for current context
kubectl config set-context --current --namespace=<name>

# Run all commands in a specific namespace with -n flag
kubectl get pods -n <namespace>
kubectl apply -k . -n <namespace>
```

---

## Quick Reset

```bash
# Nuke everything and start fresh
k3d cluster delete inhouzio-test
k3d cluster create inhouzio-test --agents 1 --port "5000:5000@loadbalancer"
k3d image import inhouzio_app_ms:latest -c inhouzio-test
kubectl apply -k .
```
