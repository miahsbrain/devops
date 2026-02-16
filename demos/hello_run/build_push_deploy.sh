PROJECT_ID=secure-devops-setup
REGISTRY=prod-repo

docker build -t us-central1-docker.pkg.dev/${PROJECT_ID}/${REGISTRY}/hello-run:latest .

# Must have google cloud to run this
docker push us-central1-docker.pkg.dev/${PROJECT_ID}/${REGISTRY}/hello-run:latest
gcloud run deploy hello-run \
  --image=us-central1-docker.pkg.dev/${PROJECT_ID}/prod-repo/hello-run:latest \
  --region=us-central1 \
  --platform=managed \
  --allow-unauthenticated \
  --service-account=run-runtime-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --set-secrets=DB_PASSWORD=prod-db-password:latest


# Setup local gcloud
# first install
gcloud init
gcloud auth configure-docker us-central1-docker.pkg.dev # Configure for docker
