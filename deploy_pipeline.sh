#!/bin/bash

# deploy_pipeline.sh - Build Docker images and deploy applications
# This script builds Docker images for Flask app and microservices, pushes to registry, commits manifests, and triggers ArgoCD sync

set -e

echo "🚀 Deploying DevOps Pipeline..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
REGISTRY="localhost:5000"
VERSION="latest"
CLUSTER_NAME="devops-pipeline"

# Check if cluster is running
if ! kind get clusters | grep -q ${CLUSTER_NAME}; then
    print_error "Kind cluster ${CLUSTER_NAME} not found. Please run bootstrap_cluster.sh first."
    exit 1
fi

# Set kubectl context
kubectl config use-context kind-${CLUSTER_NAME}

# Build and push Flask app
print_status "Building Flask application..."
cd apps/flask-app
docker build -t flask-app:${VERSION} .
docker tag flask-app:${VERSION} ${REGISTRY}/flask-app:${VERSION}
kind load docker-image flask-app:${VERSION} --name ${CLUSTER_NAME}
print_success "Flask app built and loaded into cluster"

# Build and push User Service
print_status "Building User Service..."
cd ../microservice-1
docker build -t user-service:${VERSION} .
docker tag user-service:${VERSION} ${REGISTRY}/user-service:${VERSION}
kind load docker-image user-service:${VERSION} --name ${CLUSTER_NAME}
print_success "User service built and loaded into cluster"

# Build and push Product Service
print_status "Building Product Service..."
cd ../microservice-2
docker build -t product-service:${VERSION} .
docker tag product-service:${VERSION} ${REGISTRY}/product-service:${VERSION}
kind load docker-image product-service:${VERSION} --name ${CLUSTER_NAME}
print_success "Product service built and loaded into cluster"

cd ../..

# Update image references in manifests
print_status "Updating image references in manifests..."
find environments -name "*.yaml" -exec sed -i "s|image: .*:latest|image: ${REGISTRY}/\1:${VERSION}|g" {} \;

# Apply ArgoCD project and applications
print_status "Applying ArgoCD configurations..."
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/argocd-apps.yaml

# Wait for ArgoCD applications to be created
print_status "Waiting for ArgoCD applications to be created..."
sleep 10

# Sync applications
print_status "Syncing ArgoCD applications..."
kubectl patch application devops-pipeline-dev -n argocd --type merge --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application devops-pipeline-staging -n argocd --type merge --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}'

# Force sync dev environment
print_status "Force syncing dev environment..."
kubectl patch application devops-pipeline-dev -n argocd --type merge --patch '{"operation":{"sync":{"syncStrategy":{"force":true}}}}'

# Wait for deployments to be ready
print_status "Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/flask-app -n dev
kubectl wait --for=condition=available --timeout=300s deployment/user-service -n dev
kubectl wait --for=condition=available --timeout=300s deployment/product-service -n dev

# Create ingress for Flask app
print_status "Creating ingress for Flask app..."
cat > flask-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-app-ingress
  namespace: dev
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: flask-app.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: flask-app-service
            port:
              number: 80
EOF

kubectl apply -f flask-ingress.yaml
rm flask-ingress.yaml

# Check if running as root and set SUDO prefix accordingly
SUDO_HOSTS=""
if [[ $EUID -eq 0 ]]; then
   SUDO_HOSTS=""
else
   SUDO_HOSTS="sudo"
fi

# Add ingress host to /etc/hosts
if ! grep -q "flask-app.local" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 flask-app.local" | ${SUDO_HOSTS} tee -a /etc/hosts
fi

# Run security scan with Trivy
print_status "Running security scan with Trivy..."
trivy image --severity HIGH,CRITICAL flask-app:${VERSION} || print_warning "Security scan found vulnerabilities"
trivy image --severity HIGH,CRITICAL user-service:${VERSION} || print_warning "Security scan found vulnerabilities"
trivy image --severity HIGH,CRITICAL product-service:${VERSION} || print_warning "Security scan found vulnerabilities"

print_success "Pipeline deployment completed successfully!"
print_status "Access URLs:"
echo "  Flask App: http://flask-app.local"
echo "  ArgoCD: http://argocd.local"
print_status "Next steps:"
echo "  1. Run: ./check_env.sh"
echo "  2. Run: ./switch_blue_green.sh"
echo "  3. Run: ./backup_restore_demo.sh"
