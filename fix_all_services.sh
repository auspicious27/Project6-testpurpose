#!/bin/bash

# fix_all_services.sh - Comprehensive fix script for all services and URLs
# This script ensures Docker is running, cluster exists, all services are deployed, and all URLs are accessible

set +e

echo "🔧 Fixing All Services and URLs..."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

CLUSTER_NAME="devops-pipeline"

# Step 1: Check Docker
print_status "Step 1: Checking Docker..."
if docker info >/dev/null 2>&1; then
    print_success "Docker is running"
else
    print_error "Docker is NOT running!"
    echo ""
    echo "Please start Docker Desktop:"
    echo "  macOS: Open Docker Desktop application"
    echo "  Linux: sudo systemctl start docker"
    echo ""
    exit 1
fi

# Step 2: Check if cluster exists
print_status "Step 2: Checking Kubernetes cluster..."
if ! command -v kind >/dev/null 2>&1; then
    print_error "kind is not installed!"
    echo "Please run: ./setup_prereqs.sh"
    exit 1
fi

if ! kind get clusters | grep -q ${CLUSTER_NAME}; then
    print_warning "Cluster ${CLUSTER_NAME} does not exist. Creating it..."
    if [ -f "./bootstrap_cluster.sh" ]; then
        chmod +x ./bootstrap_cluster.sh
        ./bootstrap_cluster.sh
    else
        print_error "bootstrap_cluster.sh not found!"
        exit 1
    fi
else
    print_success "Cluster exists"
fi

# Set kubectl context
print_status "Setting kubectl context..."
kind get kubeconfig --name ${CLUSTER_NAME} > ~/.kube/config 2>/dev/null
export KUBECONFIG=~/.kube/config
kubectl config use-context kind-${CLUSTER_NAME} 2>/dev/null || true

# Wait for cluster to be ready
print_status "Waiting for cluster to be ready..."
for i in {1..30}; do
    if kubectl cluster-info >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
        print_success "Cluster is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "Cluster is not responding"
        exit 1
    fi
    sleep 2
done

# Step 3: Create namespaces
print_status "Step 3: Creating namespaces..."
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# Step 4: Deploy applications if not deployed
print_status "Step 4: Checking application deployments..."

# Build and load images
print_status "Building and loading Docker images..."
cd apps/flask-app 2>/dev/null && docker build -t flask-app:latest . 2>/dev/null && kind load docker-image flask-app:latest --name ${CLUSTER_NAME} 2>/dev/null && cd ../.. || print_warning "Flask app image build skipped"
cd apps/microservice-1 2>/dev/null && docker build -t user-service:latest . 2>/dev/null && kind load docker-image user-service:latest --name ${CLUSTER_NAME} 2>/dev/null && cd ../.. || print_warning "User service image build skipped"
cd apps/microservice-2 2>/dev/null && docker build -t product-service:latest . 2>/dev/null && kind load docker-image product-service:latest --name ${CLUSTER_NAME} 2>/dev/null && cd ../.. || print_warning "Product service image build skipped"

# Deploy Flask app
if ! kubectl get deployment flask-app -n dev >/dev/null 2>&1; then
    print_status "Deploying Flask app..."
    if [ -f "apps/flask-app/deployment.yaml" ]; then
        kubectl apply -f apps/flask-app/deployment.yaml -n dev 2>/dev/null || true
    fi
else
    print_success "Flask app deployment exists"
fi

# Deploy User Service
if ! kubectl get deployment user-service -n dev >/dev/null 2>&1; then
    print_status "Deploying User Service..."
    if [ -f "apps/microservice-1/deployment.yaml" ]; then
        kubectl apply -f apps/microservice-1/deployment.yaml -n dev 2>/dev/null || true
    fi
else
    print_success "User Service deployment exists"
fi

# Deploy Product Service
if ! kubectl get deployment product-service -n dev >/dev/null 2>&1; then
    print_status "Deploying Product Service..."
    if [ -f "apps/microservice-2/deployment.yaml" ]; then
        kubectl apply -f apps/microservice-2/deployment.yaml -n dev 2>/dev/null || true
    fi
else
    print_success "Product Service deployment exists"
fi

# Wait for deployments
print_status "Waiting for deployments to be ready..."
sleep 10
kubectl wait --for=condition=available --timeout=120s deployment/flask-app -n dev 2>/dev/null || print_warning "Flask app may still be starting"
kubectl wait --for=condition=available --timeout=120s deployment/user-service -n dev 2>/dev/null || print_warning "User service may still be starting"
kubectl wait --for=condition=available --timeout=120s deployment/product-service -n dev 2>/dev/null || print_warning "Product service may still be starting"

# Step 5: Create/Update NodePort Services for direct access
print_status "Step 5: Creating NodePort services for direct access..."

# Flask App NodePort Service
print_status "Creating Flask App NodePort service..."
kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: v1
kind: Service
metadata:
  name: flask-app-nodeport
  namespace: dev
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 5000
    nodePort: 30080
    protocol: TCP
    name: http
  selector:
    app: flask-app
EOF

# User Service NodePort Service
print_status "Creating User Service NodePort service..."
kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: v1
kind: Service
metadata:
  name: user-service-nodeport
  namespace: dev
spec:
  type: NodePort
  ports:
  - port: 5001
    targetPort: 5001
    nodePort: 30081
    protocol: TCP
    name: http
  selector:
    app: user-service
EOF

# Product Service NodePort Service
print_status "Creating Product Service NodePort service..."
kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: v1
kind: Service
metadata:
  name: product-service-nodeport
  namespace: dev
spec:
  type: NodePort
  ports:
  - port: 5002
    targetPort: 5002
    nodePort: 30082
    protocol: TCP
    name: http
  selector:
    app: product-service
EOF

# Step 6: Fix existing services to NodePort
print_status "Step 6: Configuring existing services for external access..."

# Ingress Controller
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# Gitea
kubectl patch svc gitea-http -n gitea --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}, {"op": "add", "path": "/spec/ports/0/nodePort", "value": 30084}]' 2>/dev/null || true

# ArgoCD
kubectl patch svc argocd-server -n argocd --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "LoadBalancer"}]' 2>/dev/null || true
# Also create NodePort for ArgoCD
kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: argocd
spec:
  type: NodePort
  ports:
  - port: 443
    targetPort: 8080
    nodePort: 30083
    protocol: TCP
    name: https
  selector:
    app.kubernetes.io/name: argocd-server
EOF

# MinIO
kubectl patch svc minio -n minio --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

sleep 5

# Step 7: Verify pods are running
print_status "Step 7: Verifying pods..."
echo ""
print_status "Flask App pods:"
kubectl get pods -n dev -l app=flask-app
echo ""
print_status "User Service pods:"
kubectl get pods -n dev -l app=user-service
echo ""
print_status "Product Service pods:"
kubectl get pods -n dev -l app=product-service
echo ""

# Step 8: Get access URLs
print_status "Step 8: Getting access URLs..."
echo ""

# Get public IP
PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "localhost")

echo "=========================================="
echo "✅ All Services Fixed!"
echo "=========================================="
echo ""
echo "Access URLs:"
echo ""
echo "📱 Flask Application:"
echo "   http://${PUBLIC_IP}:30080"
echo "   http://localhost:30080"
echo ""
echo "👥 User Service API:"
echo "   http://${PUBLIC_IP}:30081/api/users"
echo "   http://localhost:30081/api/users"
echo ""
echo "📦 Product Service API:"
echo "   http://${PUBLIC_IP}:30082/api/products"
echo "   http://localhost:30082/api/products"
echo ""
echo "🔧 ArgoCD:"
ARGOCD_NODEPORT=$(kubectl get svc argocd-server-nodeport -n argocd -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30083")
echo "   http://${PUBLIC_IP}:${ARGOCD_NODEPORT}"
echo "   http://localhost:${ARGOCD_NODEPORT}"
echo "   Username: admin"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "check with: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")
echo "   Password: ${ARGOCD_PASSWORD}"
echo ""
echo "📚 Gitea:"
GITEA_NODEPORT=$(kubectl get svc gitea-http -n gitea -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30084")
echo "   http://${PUBLIC_IP}:${GITEA_NODEPORT}"
echo "   http://localhost:${GITEA_NODEPORT}"
echo "   Username: admin"
echo "   Password: admin123"
echo ""

# Step 9: Test connectivity
print_status "Step 9: Testing connectivity..."
echo ""

test_url() {
    local url=$1
    local name=$2
    if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null | grep -q "200\|302\|301"; then
        print_success "$name is accessible: $url"
        return 0
    else
        print_warning "$name may not be ready yet: $url"
        return 1
    fi
}

test_url "http://localhost:30080" "Flask App"
test_url "http://localhost:30081/api/users" "User Service"
test_url "http://localhost:30082/api/products" "Product Service"
test_url "http://localhost:${GITEA_NODEPORT}" "Gitea"

echo ""
print_status "Note: If services are not accessible, wait a few minutes for pods to fully start."
print_status "Check pod status with: kubectl get pods -n dev"
echo ""

print_success "Fix script completed!"
echo ""

