#!/bin/bash
set -e

REGISTRY="ghcr.io/esmacancs"
BACKEND_IMAGE="${REGISTRY}/domain-backend:latest"
FRONTEND_IMAGE="${REGISTRY}/domain-frontend:latest"

echo "=== Step 1: Build Docker images ==="
echo "Building backend..."
docker build -t "${BACKEND_IMAGE}" ../backend
echo "Building frontend..."
docker build -t "${FRONTEND_IMAGE}" ../frontend

echo ""
echo "=== Step 2: Push Docker images ==="
docker push "${BACKEND_IMAGE}"
docker push "${FRONTEND_IMAGE}"

echo ""
echo "=== Step 3: Create namespace ==="
kubectl apply -f namespace.yaml

echo ""
echo "=== Step 4: Create secrets ==="
echo "Enter your values (press Enter to skip and use defaults):"
read -p "DB Password: " DB_PASS
read -p "JWT Secret: " JWT_SECRET
read -p "OMPay API Key: " OMPAY_KEY
read -p "OMPay API Secret: " OMPAY_SECRET
read -p "S3 Access Key: " S3_KEY
read -p "S3 Secret Key: " S3_SECRET
read -p "SMTP Username: " SMTP_USER
read -p "SMTP Password: " SMTP_PASS

kubectl create secret generic db-secrets -n domain-auction \
  --from-literal=POSTGRES_PASSWORD="${DB_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic app-secrets -n domain-auction \
  --from-literal=DATABASE_URL="postgresql://postgres:${DB_PASS}@domain-db:5432/domain?schema=public" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=OMPAY_API_KEY="${OMPAY_KEY}" \
  --from-literal=OMPAY_API_SECRET="${OMPAY_SECRET}" \
  --from-literal=OMPAY_API_BASE_URL="https://api.uat.truepay.ompay.om" \
  --from-literal=S3_ENDPOINT="https://oss.odp.om" \
  --from-literal=S3_REGION="us-east-1" \
  --from-literal=S3_ACCESS_KEY="${S3_KEY}" \
  --from-literal=S3_SECRET_KEY="${S3_SECRET}" \
  --from-literal=S3_BUCKET_DOCUMENTS="documents" \
  --from-literal=S3_BUCKET_INVOICES="invoices" \
  --from-literal=S3_FORCE_PATH_STYLE="true" \
  --from-literal=SMTP_HOST="mail.smtp2go.com" \
  --from-literal=SMTP_PORT="2525" \
  --from-literal=SMTP_SECURE="false" \
  --from-literal=SMTP_REQUIRE_TLS="true" \
  --from-literal=SMTP_USERNAME="${SMTP_USER}" \
  --from-literal=SMTP_PASSWORD="${SMTP_PASS}" \
  --from-literal=SMTP_FROM="no-reply@omandatapark.com" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Step 5: Deploy PostgreSQL ==="
kubectl apply -f db-statefulset.yaml
kubectl apply -f db-service.yaml
echo "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=domain-db -n domain-auction --timeout=120s

echo ""
echo "=== Step 6: Deploy Backend ==="
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-service.yaml

echo ""
echo "=== Step 7: Deploy Frontend ==="
kubectl apply -f frontend-configmap.yaml
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service.yaml

echo ""
echo "=== Deployment Complete ==="
echo "Waiting for all pods to be ready..."
kubectl wait --for=condition=ready pod -l app=domain-backend -n domain-auction --timeout=180s
kubectl wait --for=condition=ready pod -l app=domain-frontend -n domain-auction --timeout=120s

echo ""
echo "=== Status ==="
kubectl get pods -n domain-auction
kubectl get svc -n domain-auction
echo ""
echo "Frontend will be available at the EXTERNAL-IP of domain-frontend service"
echo "Backend will be available at the EXTERNAL-IP of domain-backend service"
