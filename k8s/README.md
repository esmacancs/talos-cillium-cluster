# Domain Auction System — Kubernetes Deployment Guide

## Overview

Full-stack domain auction platform with:
- **Frontend**: React + Vite (served via nginx)
- **Backend**: Express.js + TypeScript + Prisma ORM
- **Database**: PostgreSQL 16
- **Ingress**: Cilium Gateway API HTTPRoutes

---

## Architecture

```
                        Cilium Gateway (192.168.121.175)
                               |            |
                    domain.local          domain-api.local
                               |            |
                    +----------+    +-------+--------+
                    |  Frontend |    |    Backend     |
                    |  (nginx)  |    |  (Express)     |
                    |  :80      |    |  :4000         |
                    +-----------+    +-------+--------+
                                            |
                                     +------+--------+
                                     |   PostgreSQL   |
                                     |   :5432        |
                                     +---------------+
```

---

## Repository Structure

```
/tmp/domain/k8s/
├── namespace.yaml              # Kubernetes namespace
├── db-statefulset.yaml         # PostgreSQL StatefulSet + PVC
├── db-service.yaml             # PostgreSQL headless service
├── backend-deployment.yaml     # Express API deployment
├── backend-service.yaml        # Backend LoadBalancer service
├── frontend-configmap.yaml     # nginx configuration
├── frontend-deployment.yaml    # React frontend deployment
├── frontend-service.yaml       # Frontend LoadBalancer service
├── httproutes.yaml             # Cilium HTTPRoutes for ingress
├── setup.sh                    # One-click deploy script (optional)
└── README.md                   # This file
```

---

## Container Images

| Component | Image |
|-----------|-------|
| Backend | `registry.odp.om/csharma/coe/domain-backend:latest` |
| Backend (mirror) | `ghcr.io/esmacancs/domain-backend:latest` |
| Frontend | `registry.odp.om/csharma/coe/domain-frontend:latest` |
| Frontend (mirror) | `ghcr.io/esmacancs/domain-frontend:latest` |

---

## Prerequisites

- Kubernetes cluster v1.25+
- kubectl configured for the target cluster
- Ingress controller:
  - **Cilium Gateway API** (for HTTPRoutes), OR
  - **NGINX Ingress Controller** (alternative)
- StorageClass with dynamic provisioning (tested with `csi-rbd-sc`, `longhorn`)

---

## Step-by-Step Deployment

### 1. Copy manifests to target cluster

```bash
scp -r root@<source-host>:/tmp/domain/k8s/ /tmp/domain/k8s/
```

### 2. Set variables

```bash
export NAMESPACE="hajeer-test"       # Target namespace
export STORAGE_CLASS="csi-rbd-sc"    # Your StorageClass name
export DB_PASSWORD="YourStr0ngP@ss"  # PostgreSQL password
export JWT_SECRET=$(openssl rand -hex 32)
```

### 3. Create namespace

```bash
kubectl create namespace ${NAMESPACE}
```

### 4. Create Docker registry pull secret

For **registry.odp.om** (primary):
```bash
kubectl create secret docker-registry odp-pull-secret -n ${NAMESPACE} \
  --docker-server=registry.odp.om \
  --docker-username=csharma \
  --docker-password='<YOUR_GITLAB_PAT>'
```

For **ghcr.io** (alternative):
```bash
kubectl create secret docker-registry ghcr-pull-secret -n ${NAMESPACE} \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json
```

### 5. Create application secrets

```bash
kubectl create secret generic db-secrets -n ${NAMESPACE} \
  --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}"

kubectl create secret generic app-secrets -n ${NAMESPACE} \
  --from-literal=DATABASE_URL="postgresql://postgres:${DB_PASSWORD}@domain-db:5432/domain?schema=public" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=OMPAY_API_KEY="<YOUR_OMPAY_KEY>" \
  --from-literal=OMPAY_API_SECRET="<YOUR_OMPAY_SECRET>" \
  --from-literal=OMPAY_API_BASE_URL="https://api.uat.truepay.ompay.om" \
  --from-literal=S3_ENDPOINT="https://oss.odp.om" \
  --from-literal=S3_REGION="us-east-1" \
  --from-literal=S3_ACCESS_KEY="<YOUR_S3_KEY>" \
  --from-literal=S3_SECRET_KEY="<YOUR_S3_SECRET>" \
  --from-literal=S3_BUCKET_DOCUMENTS="documents" \
  --from-literal=S3_BUCKET_INVOICES="invoices" \
  --from-literal=S3_FORCE_PATH_STYLE="true" \
  --from-literal=SMTP_HOST="mail.smtp2go.com" \
  --from-literal=SMTP_PORT="2525" \
  --from-literal=SMTP_SECURE="false" \
  --from-literal=SMTP_REQUIRE_TLS="true" \
  --from-literal=SMTP_USERNAME="<YOUR_SMTP_USER>" \
  --from-literal=SMTP_PASSWORD="<YOUR_SMTP_PASS>" \
  --from-literal=SMTP_FROM="no-reply@omandatapark.com"
```

### 6. Update manifests for your environment

Before applying, update these values in the YAML files:

**db-statefulset.yaml**:
- `namespace:` → your namespace
- `storageClassName:` → your StorageClass

**backend-deployment.yaml**:
- `namespace:` → your namespace
- `image:` → your registry image
- `imagePullSecrets:` → your pull secret name

**frontend-deployment.yaml**:
- `namespace:` → your namespace
- `image:` → your registry image
- `imagePullSecrets:` → your pull secret name

**httproutes.yaml**:
- `namespace:` → your namespace

### 7. Deploy all resources

```bash
kubectl apply -f /tmp/domain/k8s/namespace.yaml
kubectl apply -f /tmp/domain/k8s/db-statefulset.yaml
kubectl apply -f /tmp/domain/k8s/db-service.yaml
kubectl apply -f /tmp/domain/k8s/backend-deployment.yaml
kubectl apply -f /tmp/domain/k8s/backend-service.yaml
kubectl apply -f /tmp/domain/k8s/frontend-configmap.yaml
kubectl apply -f /tmp/domain/k8s/frontend-deployment.yaml
kubectl apply -f /tmp/domain/k8s/frontend-service.yaml
```

Or apply all at once:
```bash
kubectl apply -f /tmp/domain/k8s/
```

### 8. Wait for pods to be ready

```bash
kubectl wait --for=condition=ready pod -l app=domain-db -n ${NAMESPACE} --timeout=180s
kubectl wait --for=condition=ready pod -l app=domain-backend -n ${NAMESPACE} --timeout=300s
kubectl wait --for=condition=ready pod -l app=domain-frontend -n ${NAMESPACE} --timeout=120s
```

### 9. Seed the database

```bash
kubectl exec deployment/domain-backend -n ${NAMESPACE} -- sh -c "
node -e \"
const bcrypt = require('bcrypt');
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();
async function main() {
  const hash = await bcrypt.hash('admin123', 10);
  await prisma.user.upsert({ where: { email: 'admin@example.com' }, update: {}, create: { email: 'admin@example.com', name: 'Otech Seller', passwordHash: hash, role: 'SELLER', approvalStatus: 'APPROVED' } });
  const hash2 = await bcrypt.hash('superadmin123', 10);
  await prisma.user.upsert({ where: { email: 'superadmin@example.com' }, update: {}, create: { email: 'superadmin@example.com', name: 'Super Admin', passwordHash: hash2, role: 'SUPER_ADMIN', approvalStatus: 'APPROVED' } });
  console.log('Seeded!');
  await prisma.\\\$disconnect();
}
main().catch(e => { console.error(e); process.exit(1); });
\"
"
```

### 10. Verify deployment

```bash
kubectl get pods,svc -n ${NAMESPACE}
```

Expected output:
```
NAME                                   READY   STATUS    RESTARTS   AGE
pod/domain-backend-xxxxx-xxxxx         1/1     Running   0          2m
pod/domain-db-0                        1/1     Running   0          3m
pod/domain-frontend-xxxxx-xxxxx        1/1     Running   0          2m
pod/domain-frontend-xxxxx-xxxxx        1/1     Running   0          2m

NAME                      TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)        AGE
service/domain-backend    LoadBalancer   10.x.x.x       192.168.x.x    4000:xxxx/TCP  2m
service/domain-db         ClusterIP      None           <none>          5432/TCP       3m
service/domain-frontend   LoadBalancer   10.x.x.x       192.168.x.x    80:xxxx/TCP    2m
```

---

## Ingress / Access

### Option A: Cilium Gateway API (recommended)

Deploy HTTPRoutes:
```bash
kubectl apply -f /tmp/domain/k8s/httproutes.yaml
```

Add DNS entries. On your client machine:
```bash
echo "<CILIUM_GATEWAY_IP> domain.local domain-api.local" >> /etc/hosts
```

Or configure Caddy (if using):
```
domain.local {
    reverse_proxy <CILIUM_GATEWAY_IP>:80
}
domain-api.local {
    reverse_proxy <CILIUM_GATEWAY_IP>:80
}
```

Access:
- Frontend: https://domain.local
- Backend API: https://domain-api.local

### Option B: NGINX Ingress Controller

Create Ingress resources instead of HTTPRoutes:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: domain-frontend
  namespace: hajeer-test
spec:
  ingressClassName: nginx
  rules:
    - host: domain.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: domain-frontend
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: domain-backend
  namespace: hajeer-test
spec:
  ingressClassName: nginx
  rules:
    - host: api.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: domain-backend
                port:
                  number: 4000
```

---

## Login Credentials

| Role | Email | Password |
|------|-------|----------|
| Seller | admin@example.com | admin123 |
| Super Admin | superadmin@example.com | superadmin123 |

---

## Environment Variables Reference

### Backend (.env)

| Variable | Description | Required |
|----------|-------------|----------|
| `DATABASE_URL` | PostgreSQL connection string | Yes |
| `JWT_SECRET` | Secret for JWT token signing | Yes |
| `PORT` | Backend listen port (default: 4000) | No |
| `CORS_ORIGIN` | Allowed CORS origins (comma-separated) | No |
| `OMPAY_API_KEY` | OMPay payment gateway key | For payments |
| `OMPAY_API_SECRET` | OMPay payment gateway secret | For payments |
| `OMPAY_API_BASE_URL` | OMPay API base URL | For payments |
| `S3_ENDPOINT` | S3-compatible storage endpoint | For documents |
| `S3_REGION` | S3 region | For documents |
| `S3_ACCESS_KEY` | S3 access key | For documents |
| `S3_SECRET_KEY` | S3 secret key | For documents |
| `S3_BUCKET_DOCUMENTS` | S3 bucket for documents | For documents |
| `S3_BUCKET_INVOICES` | S3 bucket for invoices | For documents |
| `SMTP_HOST` | SMTP relay host | For emails |
| `SMTP_PORT` | SMTP relay port | For emails |
| `SMTP_USERNAME` | SMTP username | For emails |
| `SMTP_PASSWORD` | SMTP password | For emails |
| `SMTP_FROM` | Sender email address | For emails |

### Frontend

| Variable | Description |
|----------|-------------|
| `VITE_API_URL` | Backend API URL (baked at build time) |

---

## Troubleshooting

### Pods stuck in ErrImagePull
```bash
kubectl describe pod <pod-name> -n ${NAMESPACE}
# Check if pull secret exists and is valid
kubectl get secret odp-pull-secret -n ${NAMESPACE}
```

### Backend CrashLoopBackOff
```bash
kubectl logs deployment/domain-backend -n ${NAMESPACE} --tail=50
# Common issues:
# - Missing JWT_SECRET
# - Cannot connect to PostgreSQL
# - Prisma migration failed
```

### PostgreSQL CrashLoopBackOff
```bash
kubectl logs domain-db-0 -n ${NAMESPACE} --previous
# Common issue: PVC has lost+found directory
# Fix: Ensure PGDATA env var is set to a subdirectory
```

### Frontend shows "Cannot reach the API"
1. Check backend is running: `kubectl get pods -n ${NAMESPACE} -l app=domain-backend`
2. Check CORS_ORIGIN includes your frontend URL (both http and https)
3. Check VITE_API_URL was set correctly at build time
4. Test backend directly: `curl https://domain-api.local/`

### Database not seeded
Run the seed command from Step 9 above.

---

## Rebuilding Images

If you need to rebuild and push images:

```bash
# Backend
docker build -t registry.odp.om/csharma/coe/domain-backend:latest /tmp/domain/backend
docker push registry.odp.om/csharma/coe/domain-backend:latest

# Frontend (update /tmp/domain/frontend/.env with correct VITE_API_URL first)
docker build --no-cache -t registry.odp.om/csharma/coe/domain-frontend:latest /tmp/domain/frontend
docker push registry.odp.om/csharma/coe/domain-frontend:latest
```

---

## Cleanup

```bash
kubectl delete -f /tmp/domain/k8s/
kubectl delete namespace ${NAMESPACE}
```
