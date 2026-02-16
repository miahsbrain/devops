PROJECT_ID=secure-devops-setup

docker build -t us-central1-docker.pkg.dev/PROJECT_ID/prod-repo/hello-gke:1.0 .

# Set up gcloud before running
docker push us-central1-docker.pkg.dev/PROJECT_ID/prod-repo/hello-gke:1.0

# Verify image
gcloud artifacts docker images list us-central1-docker.pkg.dev/PROJECT_ID/prod-repo

# Connect to kubectl
gcloud container clusters get-credentials prod-cluster \
  --zone us-central1-a

# Install secret manager csi driver in kubernetes
# Install RBAC and controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.0/deploy/rbac-secretproviderclass.yaml

# Install CSI driver
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.0/deploy/csidriver.yaml

# Install the CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.0/deploy/secrets-store.csi.x-k8s.io_secretproviderclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/v1.4.0/deploy/secrets-store.csi.x-k8s.io_secretproviderclasspodstatuses.yaml

# Install google cloud manager provider plugin
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml

# Verify crds and provider
kubectl get crd | grep secrets-store
kubectl get daemonset -n kube-system
kubectl get pods -n kube-system


# Deploy to gke
kubectl apply -f k8s/

# Get external IP
kubectl get svc hello-gke
