# Step by step instructions to set up and secure google cloud project for security

1. Set reusable variables in shell

```bash
PROJECT_ID="secure-devops-setup"
PROJECT_NUMBER="$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
KSA_NAME="secret-accessor"  # Kubernetes Service Account name
NAMESPACE="default"  # or your preferred namespace
GKE_SA="gke-runtime-sa"
RUN_SA="run-runtime-sa"

REGION="us-central1"
ZONE="us-central1-a"

ARTIFACT_REPO="prod-repo"
GKE_CLUSTER_NAME="prod-cluster"
NAMESPACE="default" # if you use specific namespaces for apps in kubernetes

# GitHub repo allowed to deploy
GITHUB_ORG="miahsbrain" # your-github-username-or-org
GITHUB_REPO="" # your-repo-name if you only want specific repo access on kubernetes

# Employee email (no secret access)
EMPLOYEE_EMAIL="employee@example.com"
```

2. Select and set the active project on the shell to the project we want to modify

```bash
echo "Setting GCP project..."
gcloud config set project "$PROJECT_ID"
```

3. Enable all the required apis

```bash
gcloud services enable \
  container.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com
```

4. Create service accounts for runtime environments

```bash
gcloud iam service-accounts create $GKE_SA \
  --display-name="GKE Runtime Service Account" \
  || true

gcloud iam service-accounts create $RUN_SA \
  --display-name="Cloud Run Runtime Service Account" \
  || true
```

5. Grant both runtime service account access to secrets

```bash
for SA in $GKE_SA $RUN_SA; do
  gcloud secrets add-iam-policy-binding prod-db-password \
    --member="serviceAccount:${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    || true
done
```

For multiple secret bindings, use a loop, get all secrets with

```bash
# List all secrets
SECRETS=$(gcloud secrets list --project=${PROJECT_ID} --format="value(name)")
```

6. Create test secret and write to the secret

```bash
echo "Creating example secret..."
gcloud secrets create prod-db-password \
  --replication-policy="automatic" \
  || echo "Secret already exists"

# Add the secret
echo -n "super-secure-runtime-password" | \
gcloud secrets versions add prod-db-password --data-file=-
```

7. Create kubernetes cluster (varies)

```bash
gcloud container clusters create ${GKE_CLUSTER_NAME} \
  --zone=${ZONE} \
  --num-nodes=1 \
  --disk-size=50 \
  --machine-type=e2-standard-4 \
  --enable-secret-manager \
  --workload-pool=${PROJECT_ID}.svc.id.goog

# If existing cluster
# Update to include google secret manager
gcloud container clusters update ${GKE_CLUSTER_NAME} \
  --enable-secret-manager \
  --region=${REGION}

# Upscale cluster if you run out of memory for csis
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --node-pool default-pool \
  --num-nodes 2 \
  --zone us-central1-a
```

8. Authenticate cluster in shell and check that all services are running

```bash
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} \
  --zone=${ZONE} \
  --project=${PROJECT_ID}

# Verify all kube pods are running
kubectl get pods -n kube-system
```

9. Install csi drivers and google provider daemonset from official google repo

```bash
# Apply the Secrets Store CSI Driver
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.5/deploy/rbac-secretproviderclass.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.5/deploy/csidriver.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.5/deploy/secrets-store.csi.x-k8s.io_secretproviderclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.5/deploy/secrets-store.csi.x-k8s.io_secretproviderclasspodstatuses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.5/deploy/secrets-store-csi-driver.yaml
```

```bash
# Apply GCP provider, daemonset needed for the containers to mount
kubectl apply -f \
https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml
```

10. Create desired namespace in kubernetes (varies) and create kubernetes service account

```bash
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

kubectl create serviceaccount ${KSA_NAME} \
  --namespace=${NAMESPACE}
```

11. Bind kubernetes service account to gke runtime service account (workload identity binding)

```bash
gcloud iam service-accounts add-iam-policy-binding \
  ${GKE_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]"
```

12. Annotate the kubernetes service account

```bash
kubectl annotate serviceaccount ${KSA_NAME} \
  --namespace=${NAMESPACE} \
  iam.gke.io/gcp-service-account=${GKE_SA}@${PROJECT_ID}.iam.gserviceaccount.com

# Verify annotation was applied
kubectl get serviceaccount ${KSA_NAME} -n ${NAMESPACE} -o yaml
```

## Setup complete - Deployment guides

### Cloud run

```bash
docker build -t us-central1-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/hello-run:latest .

# Must have google cloud to run this
docker push us-central1-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/hello-run:latest

# On server
gcloud run deploy hello-run \
  --image=us-central1-docker.pkg.dev/${PROJECT_ID}/prod-repo/hello-run:latest \
  --region=us-central1 \
  --platform=managed \
  --allow-unauthenticated \
  --service-account=${RUN_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
  --set-secrets=DB_PASSWORD=prod-db-password:latest
```

### Kubernetes

The secret provider class must be present in each service manifests. Example test

```bash
cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: app-secrets
  namespace: ${NAMESPACE}
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/prod-db-password/versions/latest"
        path: "db-password"
EOF
```

Test pod example

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: csi-test-pod
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${KSA_NAME}
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: secrets-store
      mountPath: "/mnt/secrets"
      readOnly: true
  volumes:
  - name: secrets-store
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "app-secrets"
EOF
```

Exec into pod and check secret

```bash
# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/csi-test-pod -n ${NAMESPACE} --timeout=60s

# Check the mounted secret
kubectl exec -it csi-test-pod -n ${NAMESPACE} -- cat /mnt/secrets/db-password
```

Read and use secrets in app (python)

```bash
# app.py
import os

def read_secret(secret_name):
    """Read secret from mounted file"""
    secret_path = f"/mnt/secrets/{secret_name}"
    try:
        with open(secret_path, 'r') as f:
            return f.read().strip()
    except FileNotFoundError:
        raise Exception(f"Secret {secret_name} not found at {secret_path}")

# Use the secrets
DB_PASSWORD = read_secret('db-password')
API_KEY = read_secret('api-key')
JWT_SECRET = read_secret('jwt-secret')

# Example: Database connection
import psycopg2

conn = psycopg2.connect(
    host="your-db-host",
    database="mydb",
    user="dbuser",
    password=DB_PASSWORD  # Secret from file
)

# Example: API client
import requests

headers = {
    'Authorization': f'Bearer {API_KEY}'
}
response = requests.get('https://api.example.com/data', headers=headers)
```

Read and use secrets in app (Javascript/Typescript)

```js
// app.js
const fs = require("fs");
const path = require("path");

// Helper function to read secrets
function readSecret(secretName) {
  const secretPath = path.join("/mnt/secrets", secretName);
  try {
    return fs.readFileSync(secretPath, "utf8").trim();
  } catch (error) {
    throw new Error(`Failed to read secret ${secretName}: ${error.message}`);
  }
}

// Read secrets
const DB_PASSWORD = readSecret("db-password");
const API_KEY = readSecret("api-key");
const JWT_SECRET = readSecret("jwt-secret");

// Example: Database connection with Sequelize
const { Sequelize } = require("sequelize");

const sequelize = new Sequelize("database", "username", DB_PASSWORD, {
  host: "localhost",
  dialect: "postgres",
});

// Example: Express with JWT
const express = require("express");
const jwt = require("jsonwebtoken");
const app = express();

app.post("/login", (req, res) => {
  const token = jwt.sign({ userId: 123 }, JWT_SECRET, { expiresIn: "1h" });
  res.json({ token });
});

// Example: External API call
const axios = require("axios");

axios.get("https://api.example.com/data", {
  headers: { Authorization: `Bearer ${API_KEY}` },
});
```

### Extra security

Create alert for exec access

```bash
cat <<EOF | gcloud logging sinks create exec-alert-sink \
  pubsub.googleapis.com/projects/${PROJECT_ID}/topics/security-alerts \
  --log-filter='
    resource.type="k8s_cluster"
    protoPayload.methodName="io.k8s.core.v1.pods.exec"
    resource.labels.cluster_name="${GKE_CLUSTER_NAME}"
  '
EOF
```

Create network policies to control what has access to what

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-app-egress
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: my-app
  policyTypes:
  - Egress
  egress:
  # Allow DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
  # Allow database only
  - to:
    - podSelector:
        matchLabels:
          app: postgres
    ports:
    - protocol: TCP
      port: 5432
  # Block everything else (including internet)
EOF
```

### Devops Role Access control

1. Create custom GCP role without access to secrets

```bash
# Update the custom role - REMOVE all secret manager permissions
cat <<EOF > devops-role-no-secrets.yaml
title: "DevOps Engineer No Secrets"
description: "DevOps access with ZERO secret access"
stage: "GA"
includedPermissions:
# GKE Cluster access
- container.clusters.get
- container.clusters.list
- container.operations.get
- container.operations.list

# View nodes (but not SSH)
- container.nodes.get
- container.nodes.list

# Artifact Registry (for images)
- artifactregistry.repositories.get
- artifactregistry.repositories.list
- artifactregistry.dockerimages.get
- artifactregistry.dockerimages.list
- artifactregistry.files.get
- artifactregistry.files.list
- artifactregistry.tags.get
- artifactregistry.tags.list

# Cloud Build (CI/CD)
- cloudbuild.builds.create
- cloudbuild.builds.get
- cloudbuild.builds.list

# Logging (view logs)
- logging.logEntries.list
- logging.logs.list
- logging.privateLogEntries.list

# Monitoring (view metrics)
- monitoring.timeSeries.list
- monitoring.dashboards.get
- monitoring.dashboards.list

# Service Account usage (for deployments)
- iam.serviceAccounts.actAs
- iam.serviceAccounts.get
- iam.serviceAccounts.list

# Compute Engine (view only)
- compute.instances.get
- compute.instances.list
- compute.zones.get
- compute.zones.list

# Storage (for build artifacts)
- storage.buckets.get
- storage.buckets.list
- storage.objects.create
- storage.objects.get
- storage.objects.list

# EXPLICITLY REMOVED:
# NO secretmanager.secrets.* permissions
# NO secretmanager.versions.* permissions
EOF

# Update the role
gcloud iam roles update devopsEngineer \
  --project=${PROJECT_ID} \
  --file=devops-role-no-secrets.yaml
```

2. Grant other project level access

```bash
# Grant the custom role
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/devopsEngineer"

# Grant additional standard roles needed
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/container.developer"

# Grant Cloud Build Editor (for CI/CD)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/cloudbuild.builds.editor"

# Grant Artifact Registry Writer (to push images)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/artifactregistry.writer"

# Grant Log Viewer
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/logging.viewer"

# Grant Monitoring Viewer
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/monitoring.viewer"
```

3. Create kubernetes role based access control to block exec and access to secrets (make one for each environment)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: devops-developer-no-secrets
  namespace: default
rules:
# Deployments - full access
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Services - full access
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# ConfigMaps - full access
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Pods - read only + logs (NO exec, NO attach, NO portforward)
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/status"]
  verbs: ["get", "list", "watch"]

# Ingress
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# HPA
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Jobs & CronJobs
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Service Accounts - view only
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["get", "list", "watch"]

# Events (for debugging)
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]

# PersistentVolumeClaims
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# EXPLICITLY EXCLUDED:
# NO secrets (not even list)
# NO pods/exec
# NO pods/attach
# NO pods/portforward
# NO nodes
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: devops-developer-binding
  namespace: development
subjects:
- kind: User
  name: ${EMPLOYEE_EMAIL}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: devops-developer-no-secrets
  apiGroup: rbac.authorization.k8s.io
EOF
```

Test that employee indeed has no access

```bash
# Verify employee has NO secret access in GCP
gcloud secrets get-iam-policy prod-db-password --project=${PROJECT_ID} | grep ${EMPLOYEE_EMAIL}
# Should return nothing

# Verify employee has NO secret access in K8s
kubectl auth can-i get secrets --as=${EMPLOYEE_EMAIL} -n development
# Should return: no

kubectl auth can-i list secrets --as=${EMPLOYEE_EMAIL} -n development
# Should return: no

kubectl auth can-i get secrets --as=${EMPLOYEE_EMAIL} -n production
# Should return: no

# Verify they CAN deploy
kubectl auth can-i create deployments --as=${EMPLOYEE_EMAIL} -n development
# Should return: yes

# Verify they CANNOT exec
kubectl auth can-i create pods/exec --as=${EMPLOYEE_EMAIL} -n development
# Should return: no
```

### CICD

Create cicd service account with minimal access

```bash
# Create a GCP service account for CI/CD
gcloud iam service-accounts create cicd-deployer \
  --display-name="CI/CD Deployment Account" \
  --project=${PROJECT_ID}

# Grant it minimal permissions
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:cicd-deployer@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/container.developer"

# Create Kubernetes service account
kubectl create serviceaccount cicd-deployer -n development

# Bind to the same role
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cicd-deployer-binding
  namespace: development
subjects:
- kind: ServiceAccount
  name: cicd-deployer
  namespace: development
roleRef:
  kind: Role
  name: devops-developer
  apiGroup: rbac.authorization.k8s.io
EOF

# Allow the employee to impersonate this service account
gcloud iam service-accounts add-iam-policy-binding \
  cicd-deployer@${PROJECT_ID}.iam.gserviceaccount.com \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project=${PROJECT_ID}
```
