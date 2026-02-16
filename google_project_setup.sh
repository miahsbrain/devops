#!/usr/bin/env bash
set -euo pipefail

#############################################
# CONFIG — CHANGE THESE VALUES
#############################################

PROJECT_ID="secure-devops-setup"
PROJECT_NUMBER="$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
KSA_NAME="secret-accessor"  # Kubernetes Service Account name
NAMESPACE="default"  # or your preferred namespace
GSA_NAME="gke-secret-accessor"  # Google Service Account name

REGION="us-central1"
ZONE="us-central1-a"

ARTIFACT_REPO="prod-repo"
GKE_CLUSTER_NAME="prod-cluster"

# GitHub repo allowed to deploy
GITHUB_ORG="miahsbrain" # your-github-username-or-org
GITHUB_REPO="" # your-repo-name if you only want specific repo access on kubernetes

# Employee email (no secret access)
EMPLOYEE_EMAIL="employee@example.com"

#############################################
# SET PROJECT
#############################################

echo "Setting GCP project..."
gcloud config set project "$PROJECT_ID"

#############################################
# ENABLE REQUIRED APIS
#############################################

echo "Enabling required APIs..."
gcloud services enable \
  container.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com

#############################################
# CREATE ARTIFACT REGISTRY
#############################################

echo "Creating Artifact Registry..."
gcloud artifacts repositories create "$ARTIFACT_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Production Docker images" \
  || echo "Artifact Registry already exists"

#############################################
# CREATE SERVICE ACCOUNTS
#############################################

echo "Creating service accounts..."

gcloud iam service-accounts create gke-runtime-sa \
  --display-name="GKE Runtime Service Account" \
  || true

gcloud iam service-accounts create run-runtime-sa \
  --display-name="Cloud Run Runtime Service Account" \
  || true

gcloud iam service-accounts create github-ci-sa \
  --display-name="GitHub CI/CD Service Account" \
  || true

#############################################
# CREATE SECRET (EXAMPLE)
#############################################

echo "Creating example secret..."
gcloud secrets create prod-db-password \
  --replication-policy="automatic" \
  || echo "Secret already exists"

# Add the secret
echo -n "super-secure-runtime-password" | \
gcloud secrets versions add prod-db-password --data-file=-

#############################################
# GRANT SECRET ACCESS (RUNTIME ONLY)
#############################################

echo "Granting secret access to runtime service accounts..."

for SA in gke-runtime-sa run-runtime-sa; do
  gcloud secrets add-iam-policy-binding prod-db-password \
    --member="serviceAccount:${SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    || true
done

#############################################
# CREATE GKE CLUSTER (WORKLOAD IDENTITY ENABLED)
#############################################

echo "Creating GKE cluster..."
gcloud container clusters create "$GKE_CLUSTER_NAME" \
  --zone="$ZONE" \
  --num-nodes=2 \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  || echo "GKE cluster already exists"

# Use this to createtest cluster
gcloud container clusters create ${GKE_CLUSTER_NAME} \
  --zone=${ZONE} \
  --num-nodes=1 \
  --disk-size=50 \
  --machine-type=e2-standard-4 \
  --enable-secret-manager \
  --workload-pool=${PROJECT_ID}.svc.id.goog


# Create with secret manager (only recent gke version) creates 100gb disk per compute instance and duplicates across three zones = 600gb
gcloud container clusters create ${GKE_CLUSTER_NAME} \
  --enable-secret-manager \
  --disk-size=50 \
  --num-nodes=2 \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --region=${REGION}

# Update to include google secret manager
gcloud container clusters update ${GKE_CLUSTER_NAME} \
  --enable-secret-manager \
  --region=${REGION}

# Upscale cluster if you run out of memory for csis
gcloud container clusters resize ${GKE_CLUSTER_NAME} \
  --node-pool default-pool \
  --num-nodes 2 \
  --zone us-central1-a

# Update nodes to use bigger ram when pods are pending
gcloud container node-pools update default-pool \
  --enable-secret-manager \
  --cluster ${GKE_CLUSTER_NAME} \
  --zone ${ZONE} \
  --machine-type e2-standard-4 \

# Veeify all kube pods are running
kubectl get pods -n kube-system

# Apply GCP provider, daemonset needed for the containers to mount
kubectl apply -f \
https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml

#############################################
# CONFIGURE KUBECTL
#############################################

gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" \
  --zone="$ZONE"

#############################################
# CREATE K8S SERVICE ACCOUNT
#############################################

kubectl create serviceaccount gke-app-sa \
  || echo "K8s service account already exists"

#############################################
# BIND K8S SA → GCP SA (WORKLOAD IDENTITY)
#############################################

gcloud iam service-accounts add-iam-policy-binding \
  gke-runtime-sa@"$PROJECT_ID".iam.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[default/gke-app-sa]" \
  --role="roles/iam.workloadIdentityUser" \
  || true

kubectl annotate serviceaccount gke-app-sa \
  iam.gke.io/gcp-service-account=gke-runtime-sa@"$PROJECT_ID".iam.gserviceaccount.com \
  --overwrite


#############################################
# CLOUD RUN — RUNTIME IAM
#############################################

echo "Configuring Cloud Run runtime permissions..."

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:run-runtime-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  || true

#############################################
# INVITE EMPLOYEE (NO SECRET ACCESS)
#############################################

echo "Granting employee limited access..."

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/container.developer" \
  || true

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/run.developer" \
  || true

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:${EMPLOYEE_EMAIL}" \
  --role="roles/artifactregistry.writer" \
  || true

#############################################
# GITHUB OIDC — WORKLOAD IDENTITY FEDERATION
#############################################

echo "Setting up GitHub Workload Identity Federation..."

gcloud iam workload-identity-pools create github-pool \
  --location="global" \
  --display-name="GitHub Actions Pool" \
  || true

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  || true

#############################################
# ALLOW GITHUB TO IMPERSONATE CI SA
#############################################

gcloud iam service-accounts add-iam-policy-binding \
  github-ci-sa@"$PROJECT_ID".iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}" \
  || true

# Enable entire github account or org
gcloud iam service-accounts add-iam-policy-binding \
  github-ci-sa@"$PROJECT_ID".iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository_owner/${GITHUB_ORG}"

#############################################
# GRANT CI DEPLOY PERMISSIONS
#############################################

echo "Granting CI deploy permissions..."

for ROLE in roles/run.admin roles/container.developer roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:github-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="$ROLE" \
    || true
done

#############################################
# SECURITY HARDENING (RECOMMENDED)
#############################################

echo "Disabling service account key creation (org/project level)..."
gcloud iam service-accounts disable \
  github-ci-sa@"$PROJECT_ID".iam.gserviceaccount.com \
  || true

echo "Bootstrap completed successfully."


# Delete cluster if needed
gcloud container clusters delete prod-cluster --zone us-central1-a --quiet
gcloud container clusters delete prod-cluster --region us-central1 --quiet
