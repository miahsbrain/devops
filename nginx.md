# GKE Nginx Ingress + Cert-Manager Setup Guide

## Prerequisites

- `kubectl` configured and pointing to your cluster
- `gcloud` CLI authenticated

---

## Step 1: Reserve a Static IP

```bash
gcloud compute addresses create ingress-ip \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID

# Verify the IP was created
gcloud compute addresses describe ingress-ip \
  --region=us-central1 \
  --project=YOUR_PROJECT_ID
```

Note the `address` value — you'll need it throughout this guide.

---

## Step 2: Install Nginx Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
```

### Assign the Static IP

```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"loadBalancerIP": "YOUR_STATIC_IP"}}'
```

### Verify

```bash
# Watch until EXTERNAL-IP matches your static IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

Expected output:

```
NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
ingress-nginx-controller   LoadBalancer   34.x.x.x        YOUR_STATIC_IP   80:xxxxx/TCP,443:xxxxx/TCP
```

#### Debug Commands

```bash
# Check nginx controller pods are running
kubectl get pods -n ingress-nginx

# Check controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Describe the service for event errors
kubectl describe svc ingress-nginx-controller -n ingress-nginx
```

---

## Step 3: Install Cert-Manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

### Verify

```bash
# Wait for all cert-manager pods to be Running
kubectl get pods -n cert-manager -w
```

Expected output — all 3 pods should be `Running`:

```
cert-manager-xxxx            1/1   Running
cert-manager-cainjector-xxxx 1/1   Running
cert-manager-webhook-xxxx    1/1   Running
```

#### Debug Commands

```bash
# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check webhook logs
kubectl logs -n cert-manager deployment/cert-manager-webhook
```

---

## Step 4: Create a ClusterIssuer (Let's Encrypt)

Create `cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
```

> Use `letsencrypt-staging` server for testing to avoid rate limits:
> `https://acme-staging-v02.api.letsencrypt.org/directory`

Apply it:

```bash
kubectl apply -f cluster-issuer.yaml
```

### Verify

```bash
kubectl get clusterissuer letsencrypt-prod
kubectl describe clusterissuer letsencrypt-prod
```

The `READY` column should be `True`.

---

## Step 5: Create an Ingress Resource

### Option A — Using nip.io (no real domain)

Your domain will be `YOUR_STATIC_IP.nip.io` e.g. `136.114.0.235.nip.io`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: account-termination-ms-ingress
  namespace: dev
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - 136.114.0.235.nip.io
      secretName: account-termination-ms-tls
  rules:
    - host: 136.114.0.235.nip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: account-termination-ms-cluster-ip-service
                port:
                  number: 5048
```

### Option B — Using a real domain

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: account-termination-ms-ingress
  namespace: dev
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.yourdomain.com
      secretName: account-termination-ms-tls
  rules:
    - host: api.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: account-termination-ms-cluster-ip-service
                port:
                  number: 5048
```

> If using a real domain, create an A record pointing to your static IP in your DNS provider.

Apply it:

```bash
kubectl apply -f ingress.yaml
```

### Verify

```bash
kubectl get ingress -n dev
kubectl describe ingress account-termination-ms-ingress -n dev
```

---

## Step 6: Verify SSL Certificate

```bash
# Check certificate was issued
kubectl get certificate -n dev

# Watch certificate status (takes 1-2 mins)
kubectl get certificate -n dev -w

# Check certificate details and any errors
kubectl describe certificate account-termination-ms-tls -n dev

# Check the challenge (used during issuance)
kubectl get challenge -n dev
kubectl describe challenge -n dev
```

The certificate `READY` column should go from `False` to `True`.

---

## General Debug Commands

```bash
# Check all resources in dev namespace
kubectl get all -n dev

# Check ingress controller is receiving traffic
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller -f

# Check cert-manager issued any certificates
kubectl get certificates -A

# Check cert-manager orders (ACME challenge lifecycle)
kubectl get orders -A
kubectl describe order -n dev

# Test your endpoint
curl -v https://YOUR_DOMAIN
```
