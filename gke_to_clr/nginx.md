```bash
# k8s/ingress/ingress.yaml
#
# Nginx-based ingress setup.
#
# How it works:
#   - One nginx IngressClass is defined for the whole cluster
#   - The nginx controller is exposed via TWO Services:
#       1. External LoadBalancer  — public IP, internet traffic
#       2. Internal LoadBalancer  — VPC-only IP, Cloud Run traffic
#   - Two Ingress objects point to the same backends (service-a, service-b)
#     but are served by the same nginx controller
#
# This means:
#   - No GCE IngressClass headaches
#   - One nginx controller handles everything
#   - Cloud Run reaches the internal LB IP via VPC egress
#   - Adding a new service = add one path to both Ingress objects
# ─────────────────────────────────────────────────────────────

# ── IngressClass ──────────────────────────────────────────────
# Tells Kubernetes that "nginx" ingresses are handled by
# the nginx ingress controller already installed in your cluster.
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: k8s.io/ingress-nginx

---
# ── Internal LoadBalancer Service for nginx ───────────────────
# This is the single stable VPC-internal IP that Cloud Run calls.
# It points at the nginx controller pods — nginx then routes to
# service-a or service-b based on the path.
#
# This is the ONLY internal load balancer in the entire setup.
# Every new service you add only needs a path in the Ingress below —
# not a new load balancer.
#
# The annotation cloud.google.com/load-balancer-type: "Internal"
# tells GKE to provision a private internal LB (no public IP).
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-internal
  namespace: ingress-nginx
  annotations:
    cloud.google.com/load-balancer-type: "Internal"
    # Bind to the static internal IP you reserved in Step 1.7
    # This keeps the IP stable even if the Service is recreated
    cloud.google.com/load-balancer-ip: ""   # ← paste your INTERNAL_LB_IP here
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/component: controller
  ports:
    - name: http
      port: 80
      targetPort: http
    - name: https
      port: 443
      targetPort: https

---
# ── External Ingress ──────────────────────────────────────────
# Handles public internet traffic.
# nginx routes requests to service-a or service-b based on path.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: external-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: service-a
                port:
                  number: 8080
          - path: /service-b
            pathType: Prefix
            backend:
              service:
                name: service-b
                port:
                  number: 8080

---
# ── Internal Ingress ──────────────────────────────────────────
# Handles traffic from Cloud Run via VPC egress.
# Cloud Run calls http://internal.devops-gateway.private/...
# which resolves (via Cloud DNS private zone) to the internal
# LB IP above, which hits nginx, which routes here.
#
# No host rule is set — nginx matches purely on path.
# This means any request reaching the internal LB gets routed
# regardless of the hostname Cloud Run sends.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: internal-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: internal.devops-gateway.private
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: service-a
                port:
                  number: 8080
          - path: /service-b
            pathType: Prefix
            backend:
              service:
                name: service-b
                port:
                  number: 8080
          # ── Adding a new service ───────────────────────────────
          # Uncomment and fill in — no new load balancers needed
          # - path: /service-x
          #   pathType: Prefix
          #   backend:
          #     service:
          #       name: service-x
          #       port:
          #         number: 8080
```

GCR AND Ingress

```bash
# k8s/ingress/ingress.yaml
#
# Mixed GCE + nginx ingress setup.
#
# How it works:
#
#   GCE internal load balancer  — provisions a stable VPC-only IP automatically
#   from your reserved static address (devops-internal-ip). Forwards all traffic
#   to the nginx controller Service inside the cluster.
#
#   nginx ingress controller — handles all actual path routing to your services,
#   exactly the same way it handles your existing external traffic. You only need
#   to know nginx config, nothing GCE-specific.
#
# Traffic flow:
#
#   Internet             → nginx (external, whatever you already have set up)
#   Cloud Run (VPC egress) → GCE Internal LB IP → nginx → service-a / service-b
#
# Adding a new service in the future:
#   - Add a path to the internal-ingress rules below
#   - No new load balancers, no new IPs, no DNS changes
# ─────────────────────────────────────────────────────────────

# ── GCE Internal LoadBalancer Service ────────────────────────
# This is the only GCE-specific object in the file.
# It tells GKE to create an internal load balancer that sits in front
# of your nginx controller pods and gets assigned the static IP you
# reserved (devops-internal-ip). No public IP is created.
#
# Cloud Run calls this IP via VPC egress. nginx receives the request
# and routes it based on the Ingress rules below.
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-internal
  namespace: ingress-nginx
  annotations:
    # Provisions an internal VPC load balancer instead of a public one
    cloud.google.com/load-balancer-type: "Internal"
    # Automatically assigns the static IP you reserved in Step 1.7
    # GCP wires this up for you — no manual IP lookup needed
    cloud.google.com/load-balancer-ip-annotation: "devops-internal-ip"
spec:
  type: LoadBalancer
  # Points at your existing nginx controller pods
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/component: controller
  ports:
    - name: http
      port: 80
      targetPort: http
    - name: https
      port: 443
      targetPort: https

---
# ── External Ingress ──────────────────────────────────────────
# Your existing nginx ingress for public internet traffic.
# This is the same pattern you already use — nothing changes here.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: external-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.com
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: service-a
                port:
                  number: 8080
          - path: /service-b(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: service-b
                port:
                  number: 8080

---
# ── Internal Ingress ──────────────────────────────────────────
# nginx routes requests arriving from Cloud Run via the internal LB.
# Cloud Run calls http://internal.devops-gateway.private/...
# which resolves (via Cloud DNS private zone) to the GCE internal LB IP,
# which forwards to nginx, which matches the rules here.
#
# Uses the same nginx IngressClass as everything else in your cluster.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: internal-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - host: internal.devops-gateway.private
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: service-a
                port:
                  number: 8080
          - path: /service-b(/|$)(.*)
            pathType: Prefix
            backend:
              service:
                name: service-b
                port:
                  number: 8080
          # ── Adding a new service ───────────────────────────────
          # Uncomment and fill in — no new load balancers needed
          # - path: /service-x(/|$)(.*)
          #   pathType: Prefix
          #   backend:
          #     service:
          #       name: service-x
          #       port:
          #         number: 8080
```
