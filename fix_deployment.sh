#!/bin/bash

# fix_deployment.sh - Fix common deployment issues
# This script fixes: missing namespaces, MinIO installation, ArgoCD sync, and URL access

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

print_status "🔧 Fixing Deployment Issues..."

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi

# Check if cluster exists
if ! kubectl cluster-info &>/dev/null; then
    print_error "Kubernetes cluster not found. Please run bootstrap_cluster.sh first."
    exit 1
fi

# Fix 1: Create missing namespaces
print_status "1. Creating missing namespaces..."
for ns in dev staging production; do
    if ! kubectl get namespace "$ns" &>/dev/null; then
        print_status "Creating namespace: $ns"
        kubectl create namespace "$ns" || print_warning "Could not create namespace $ns"
    else
        print_success "Namespace $ns already exists"
    fi
done

# Fix 2: Reinstall MinIO if it failed
print_status "2. Checking MinIO installation..."
if ! kubectl get deployment minio -n minio &>/dev/null 2>&1; then
    print_status "MinIO not found. Reinstalling..."
    
    # Uninstall existing MinIO if partially installed
    helm uninstall minio -n minio 2>/dev/null || true
    sleep 5
    
    # Create MinIO values with correct ingress configuration
    cat > /tmp/minio-values-fix.yaml << EOF
mode: standalone
auth:
  rootUser: minioadmin
  rootPassword: minioadmin123
defaultBuckets: "velero-backups"
persistence:
  enabled: true
  size: 20Gi
service:
  type: NodePort
  port: 9000
ingress:
  enabled: true
  ingressClassName: nginx
  host: minio.local
  path: /
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
EOF

    # Install MinIO
    helm repo add minio https://charts.min.io/ 2>/dev/null || true
    helm repo update
    
    helm install minio minio/minio \
      --namespace minio \
      --values /tmp/minio-values-fix.yaml \
      --timeout 10m \
      --wait=false || print_warning "MinIO installation had warnings"
    
    print_status "Waiting for MinIO to be ready..."
    sleep 30
    kubectl wait --for=condition=available --timeout=300s deployment/minio -n minio 2>/dev/null || \
    print_warning "MinIO may still be starting"
else
    print_success "MinIO is already installed"
fi

# Fix 3: Register GitHub repo in ArgoCD (if needed)
print_status "3. Registering GitHub repository in ArgoCD..."
REPO_URL="https://github.com/auspicious27/Project6-testpurpose.git"

# Check if repo is already registered
if kubectl get secret -n argocd | grep -q "repo-.*github"; then
    print_success "GitHub repository already registered"
else
    print_status "Repository may need to be registered. ArgoCD should auto-detect public repos."
fi

# Fix 4: Sync ArgoCD applications
print_status "4. Syncing ArgoCD applications..."
APPS=("devops-pipeline-dev" "devops-pipeline-staging" "devops-pipeline-prod" "devops-pipeline-blue-green")

for app in "${APPS[@]}"; do
    if kubectl get application "$app" -n argocd &>/dev/null; then
        print_status "Syncing $app..."
        
        # Enable automated sync
        kubectl patch application "$app" -n argocd --type merge --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
        
        # Trigger refresh
        kubectl patch application "$app" -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
        
        # Trigger sync
        kubectl patch application "$app" -n argocd --type json -p='[{"op": "add", "path": "/operation", "value": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}]' 2>/dev/null || true
    fi
done

sleep 15

# Fix 5: Ensure services are NodePort for external access
print_status "5. Configuring services for external access..."

# Ingress Controller
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# Gitea
kubectl patch svc gitea-http -n gitea --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# MinIO
kubectl patch svc minio -n minio --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# ArgoCD
kubectl patch svc argocd-server -n argocd --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "LoadBalancer"}]' 2>/dev/null || true

sleep 5

# Fix 6: Check application deployments
print_status "6. Checking application deployments..."
if kubectl get deployment flask-app -n dev &>/dev/null; then
    print_success "Flask app deployment found"
    kubectl rollout status deployment/flask-app -n dev --timeout=60s 2>/dev/null || print_warning "Flask app may still be deploying"
else
    print_warning "Flask app deployment not found. ArgoCD may still be syncing."
    print_status "Run: ./sync_argocd_apps.sh to manually sync"
fi

# Fix 7: Create ingress if missing
print_status "7. Ensuring ingress is created..."
if ! kubectl get ingress flask-app-ingress -n dev &>/dev/null; then
    if kubectl get svc flask-app-service -n dev &>/dev/null; then
        print_status "Creating Flask app ingress..."
        cat > /tmp/flask-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-app-ingress
  namespace: dev
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
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
        kubectl apply -f /tmp/flask-ingress.yaml
        rm -f /tmp/flask-ingress.yaml
        print_success "Ingress created"
    else
        print_warning "Flask app service not found. Cannot create ingress yet."
    fi
else
    print_success "Ingress already exists"
fi

# Display status
print_success "Fix operations completed!"
echo ""
print_status "📊 Current Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check namespaces
print_status "Namespaces:"
kubectl get namespaces | grep -E "dev|staging|production|argocd|gitea|minio" || true

# Check ArgoCD apps
print_status ""
print_status "ArgoCD Applications:"
kubectl get applications -n argocd || true

# Check pods in dev
print_status ""
print_status "Pods in dev namespace:"
kubectl get pods -n dev || print_warning "No pods in dev namespace yet"

# Get service ports
print_status ""
print_status "Service Ports:"
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "N/A")
ARGOCD_PORT=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "N/A")
GITEA_PORT=$(kubectl get svc -n gitea gitea-http -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "N/A")
MINIO_PORT=$(kubectl get svc -n minio minio -o jsonpath='{.spec.ports[?(@.name=="api")].nodePort}' 2>/dev/null || echo "N/A")

echo "  Ingress Controller: $INGRESS_PORT"
echo "  ArgoCD: $ARGOCD_PORT"
echo "  Gitea: $GITEA_PORT"
echo "  MinIO: $MINIO_PORT"

# Get EC2 IP if available
PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
if [ -n "$PUBLIC_IP" ]; then
    echo ""
    print_status "🌐 EC2 Public IP: $PUBLIC_IP"
    if [ "$INGRESS_PORT" != "N/A" ]; then
        echo "  Flask App: http://$PUBLIC_IP:$INGRESS_PORT (with Host: flask-app.local)"
    fi
    if [ "$ARGOCD_PORT" != "N/A" ]; then
        echo "  ArgoCD: https://$PUBLIC_IP:$ARGOCD_PORT"
    fi
fi

echo ""
print_status "Next steps:"
echo "  1. If applications are not syncing, run: ./sync_argocd_apps.sh"
echo "  2. Check ArgoCD UI to see sync status"
echo "  3. Configure AWS Security Group to allow ports: $INGRESS_PORT, $ARGOCD_PORT, $GITEA_PORT, $MINIO_PORT"
echo "  4. Wait a few minutes for ArgoCD to sync applications"

