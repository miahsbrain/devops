# Kubernetes Secrets Guide

### Two Ways to Load Secrets into Your App — A Beginner-Friendly Reference

> 💡 **What is a secret?** A secret is any sensitive value your app needs to run — like a database password, an API key, or an encryption key. You never want to hardcode these directly in your code or deployment files.

---

## Table of Contents

1. [The Two Approaches](#1-the-two-approaches)
2. [Approach A — Environment Variables via Kubernetes Secrets](#2-approach-a--environment-variables-via-kubernetes-secrets)
3. [Approach B — Mounted Files via GCP Secret Manager (Recommended)](#3-approach-b--mounted-files-via-gcp-secret-manager-recommended)
4. [The `readSecret` Function Explained](#4-the-readsecret-function-explained)
5. [How to Add a New Secret](#5-how-to-add-a-new-secret)
6. [Common Mistakes to Avoid](#6-common-mistakes-to-avoid)
7. [Quick Reference Cheatsheet](#7-quick-reference-cheatsheet)

---

## 1. The Two Approaches

There are two ways secrets can be loaded into your app inside Kubernetes. This project uses **Approach B**, but it helps to understand both.

|                           | Approach A                                 | Approach B                                 |
| ------------------------- | ------------------------------------------ | ------------------------------------------ |
| **Method**                | Kubernetes Secrets → Environment Variables | GCP Secret Manager → Mounted Files         |
| **How app reads it**      | `process.env.MY_SECRET`                    | `fs.readFileSync('/mnt/secrets/mysecret')` |
| **Where secret lives**    | Inside the Kubernetes cluster              | In GCP Secret Manager (external)           |
| **Security**              | Moderate                                   | Higher (single source of truth)            |
| **Used in this project?** | ❌ No                                      | ✅ Yes                                     |

---

## 2. Approach A — Environment Variables via Kubernetes Secrets

> 📖 This section is for understanding only. This project does **not** use this approach.

### How it works

1. You create a Kubernetes secret manually
2. Your deployment references it as an environment variable
3. Your app reads it with `process.env.SECRET_NAME`

### Step 1 — Create the Kubernetes secret

```bash
kubectl create secret generic my-database-password \
  --from-literal=PASSWORD="super-secret-value" \
  -n your-namespace
```

### Step 2 — Reference it in your deployment YAML

```yaml
containers:
  - name: my-app
    env:
      - name: DATABASE_PASSWORD # The name your app sees
        valueFrom:
          secretKeyRef:
            name: my-database-password # The Kubernetes secret name
            key: PASSWORD # The key inside the secret
```

### Step 3 — Read it in your app

```javascript
const password = process.env.DATABASE_PASSWORD;
```

### ⚠️ Why we don't use this approach

- Secrets must be manually created in every cluster/namespace
- Easy to forget to create them → causes `CreateContainerConfigError` crashes
- Secrets are stored inside Kubernetes, not in a central secure place
- Hard to rotate (update) secrets across many microservices

---

## 3. Approach B — Mounted Files via GCP Secret Manager ✅

> ✅ This is the approach this project uses.

### How it works

```
GCP Secret Manager
       ↓
  (CSI Driver pulls secrets at pod startup)
       ↓
  Files appear at /mnt/secrets/ inside the container
       ↓
  App reads files using readSecret() function
```

Think of it like a USB drive that gets plugged into your container when it starts — the secrets appear as plain text files at a specific folder path.

---

### The 3 pieces you need

#### Piece 1 — The `SecretProviderClass`

This tells Kubernetes **which secrets to pull from GCP** and what to name the files.

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: gcp-secrets
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: "projects/<your-gcp-project-id>/secrets/<secret-name>/versions/latest"
        fileName: "<secret-name>"
```

**Real example:**

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: gcp-secrets
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: "projects/my-project-id/secrets/mongourl/versions/latest"
        fileName: "mongourl"
      - resourceName: "projects/my-project-id/secrets/sendgridapikey/versions/latest"
        fileName: "sendgridapikey"
      - resourceName: "projects/my-project-id/secrets/stripeapikey/versions/latest"
        fileName: "stripeapikey"
```

> 💡 `versions/latest` means it always pulls the most recent version of the secret from GCP.

---

#### Piece 2 — The Volume Mount in your Deployment

This tells Kubernetes to **attach the secrets folder** to your container. Without this, the files never appear inside the container.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      component: my-app
  template:
    metadata:
      labels:
        component: my-app
    spec:
      containers:
        - name: my-app
          image: <your-image>
          ports:
            - containerPort: 3000
          # ✅ Step 1 — Tell the container WHERE to mount the secrets folder
          volumeMounts:
            - name: secrets-store
              mountPath: "/mnt/secrets" # Files will appear here inside the container
              readOnly: true

      # ✅ Step 2 — Define the volume and link it to the SecretProviderClass
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: gcp-secrets # Must match the name in Piece 1
```

> ⚠️ The `secretProviderClass` value must **exactly match** the `metadata.name` in your `SecretProviderClass` file.

---

#### Piece 3 — Reading the secret in your app

Once the files are mounted, your app reads them like normal files. No `process.env` needed for secrets.

```javascript
const fs = require("fs");
const path = require("path");

function readSecret(name, envFallback) {
  const secretsPath = process.env.SECRETS_PATH || "/mnt/secrets";
  const filePath = path.join(secretsPath, name);
  try {
    // Try to read from the mounted file (used in production/Kubernetes)
    return fs.readFileSync(filePath, "utf8").trim();
  } catch {
    // If file doesn't exist, fall back to environment variable (used in local dev)
    return process.env[envFallback] || "";
  }
}
```

**Using it in your config:**

```javascript
module.exports = () => {
  return {
    mongoUrl: readSecret("mongourl", "MONGO_URL"),
    stripeApiKey: readSecret("stripeapikey", "STRIPE_API_KEY"),
    sendGridApiKey: readSecret("sendgridapikey", "SENDGRID_API_KEY"),
    sessionSecret: readSecret("sessionsecret", "SESSION_SECRET"),
  };
};
```

> 💡 The first argument (`"mongourl"`) must **exactly match** the `fileName` in your `SecretProviderClass`.
> The second argument (`"MONGO_URL"`) is the environment variable fallback for **local development**.

---

## 4. The `readSecret` Function Explained

```javascript
function readSecret(name, envFallback) {
```

| Parameter     | What it does                                                                |
| ------------- | --------------------------------------------------------------------------- |
| `name`        | The filename to look for inside `/mnt/secrets/`                             |
| `envFallback` | The `process.env` variable to use if the file doesn't exist (for local dev) |

### What happens at each stage

```
In Kubernetes (production):
  readSecret("mongourl", "MONGO_URL")
       ↓
  Looks for file: /mnt/secrets/mongourl
       ↓
  Returns the file contents (your actual Mongo connection string)

On your local machine (development):
  readSecret("mongourl", "MONGO_URL")
       ↓
  File not found → falls back to process.env.MONGO_URL
       ↓
  Returns your local .env value
```

This means the **same code works in both environments** without any changes. ✅

---

## 5. How to Add a New Secret

Let's say you need to add a new secret called `twilioApiKey`.

### Step 1 — Add the secret to GCP Secret Manager

```bash
# Create the secret in GCP
echo -n "your-actual-twilio-key" | gcloud secrets create twilioApiKey \
  --data-file=- \
  --project=<your-gcp-project-id>
```

Or do it via the GCP Console: **Secret Manager → Create Secret → paste your value**.

---

### Step 2 — Add it to your `SecretProviderClass`

```yaml
parameters:
  secrets: |
    # ... existing secrets ...
    - resourceName: "projects/<your-gcp-project-id>/secrets/twilioApiKey/versions/latest"
      fileName: "twilioApiKey"    # This becomes the filename inside /mnt/secrets/
```

---

### Step 3 — Read it in your config using `readSecret`

```javascript
module.exports = () => {
  return {
    // ... existing config ...
    twilioApiKey: readSecret("twilioApiKey", "TWILIO_API_KEY"),
  };
};
```

---

### Step 4 — For local development, add it to your `.env` file

```bash
# .env (never commit this file to git)
TWILIO_API_KEY=your-local-twilio-key
```

---

### Step 5 — Apply the changes

```bash
kubectl apply -k kus/dev
kubectl rollout restart deployment/my-app-deployment -n dev
```

---

## 6. Common Mistakes to Avoid

### ❌ Mistake 1 — Using `secretKeyRef` when you're using mounted files

If your app uses `readSecret()` (file-based), do NOT add `secretKeyRef` env vars in your deployment. They conflict and cause `CreateContainerConfigError`.

```yaml
# ❌ Don't do this if using readSecret()
env:
  - name: MONGO_URL
    valueFrom:
      secretKeyRef:
        name: mongourl
        key: MONGOURL
```

```yaml
# ✅ Do this instead — no env var needed, readSecret() handles it
volumeMounts:
  - name: secrets-store
    mountPath: "/mnt/secrets"
    readOnly: true
```

---

### ❌ Mistake 2 — Forgetting the volume mount

The `SecretProviderClass` alone does nothing. The secrets only get pulled when a pod actually **mounts the volume**. Always make sure your deployment has both the `volumeMounts` and `volumes` sections.

---

### ❌ Mistake 3 — fileName mismatch

The `fileName` in `SecretProviderClass` must exactly match the first argument passed to `readSecret()`.

```yaml
# SecretProviderClass
fileName: "mongourl" # ← must match ↓
```

```javascript
readSecret("mongourl", ...)  # ← must match ↑
```

---

### ❌ Mistake 4 — Adding `secretObjects` when you don't need Kubernetes secrets

`secretObjects` creates Kubernetes secrets from the mounted files. Only add this if you specifically need `secretKeyRef` env vars. If your app uses `readSecret()`, you do **not** need `secretObjects`.

---

## 7. Quick Reference Cheatsheet

### Check if secrets exist in GCP

```bash
gcloud secrets list --project=<your-gcp-project-id>
```

### View a secret's value in GCP

```bash
gcloud secrets versions access latest \
  --secret=<secret-name> \
  --project=<your-gcp-project-id>
```

### Verify files are mounted inside a running pod

```bash
kubectl exec -it <pod-name> -n <namespace> -- ls /mnt/secrets
```

### Read a specific secret file inside a pod

```bash
kubectl exec -it <pod-name> -n <namespace> -- cat /mnt/secrets/mongourl
```

### Apply changes and restart a deployment

```bash
kubectl apply -k kus/dev
kubectl rollout restart deployment/<deployment-name> -n <namespace>
kubectl rollout status deployment/<deployment-name> -n <namespace>
```

### Check pod errors

```bash
kubectl describe pod <pod-name> -n <namespace> | grep -A5 Events
```

---

> 💡 **Summary:** Store secrets in GCP Secret Manager → pull them into the container as files via `SecretProviderClass` + volume mount → read them in your app using `readSecret()`. Never use `secretKeyRef` if your app reads from files.
