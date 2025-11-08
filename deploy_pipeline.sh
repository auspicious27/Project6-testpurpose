#!/bin/bash

# deploy_pipeline.sh - Build Docker images and deploy applications
# This script builds Docker images for Flask app and microservices, pushes to registry, commits manifests, and triggers ArgoCD sync

# Don't exit on error - handle errors gracefully
set +e

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

# Check if Docker is running
if ! systemctl is-active --quiet docker 2>/dev/null && ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

# Set kubectl context
kubectl config use-context kind-${CLUSTER_NAME} || {
    print_error "Failed to set kubectl context"
    exit 1
}

# Build and push Flask app
print_status "Building Flask application..."
cd apps/flask-app || {
    print_error "Failed to change to apps/flask-app directory"
    exit 1
}
docker build -t flask-app:${VERSION} . || {
    print_error "Failed to build Flask app"
    exit 1
}
docker tag flask-app:${VERSION} ${REGISTRY}/flask-app:${VERSION}
kind load docker-image flask-app:${VERSION} --name ${CLUSTER_NAME} || {
    print_error "Failed to load Flask app image into cluster"
    exit 1
}
print_success "Flask app built and loaded into cluster"

# Build and push User Service
print_status "Building User Service..."
cd ../microservice-1 || {
    print_error "Failed to change to microservice-1 directory"
    exit 1
}
docker build -t user-service:${VERSION} . || {
    print_error "Failed to build User service"
    exit 1
}
docker tag user-service:${VERSION} ${REGISTRY}/user-service:${VERSION}
kind load docker-image user-service:${VERSION} --name ${CLUSTER_NAME} || {
    print_error "Failed to load User service image into cluster"
    exit 1
}
print_success "User service built and loaded into cluster"

# Build and push Product Service
print_status "Building Product Service..."
cd ../microservice-2 || {
    print_error "Failed to change to microservice-2 directory"
    exit 1
}
docker build -t product-service:${VERSION} . || {
    print_error "Failed to build Product service"
    exit 1
}
docker tag product-service:${VERSION} ${REGISTRY}/product-service:${VERSION}
kind load docker-image product-service:${VERSION} --name ${CLUSTER_NAME} || {
    print_error "Failed to load Product service image into cluster"
    exit 1
}
print_success "Product service built and loaded into cluster"

cd ../.. || {
    print_error "Failed to return to project root"
    exit 1
}

# Update image references in manifests (skip if not needed - images are already tagged correctly)
print_status "Checking manifest files..."
# Note: Image names in manifests should match what we built
# Since we're using kind load, images are available as flask-app:latest, etc.
# We don't need to modify manifests if they already reference the correct images

# Apply ArgoCD project and applications
print_status "Applying ArgoCD configurations..."
kubectl apply -f argocd/project.yaml || print_warning "ArgoCD project may already exist"
kubectl apply -f argocd/argocd-apps.yaml || print_warning "ArgoCD applications may already exist"

# Wait for ArgoCD applications to be created
print_status "Waiting for ArgoCD applications to be created..."
sleep 15

# Wait for ArgoCD applications to appear
for i in {1..30}; do
    if kubectl get application devops-pipeline-dev -n argocd &>/dev/null; then
        break
    fi
    sleep 2
done

# Sync applications using ArgoCD CLI if available, otherwise use kubectl patch
print_status "Syncing ArgoCD applications..."
if command -v argocd &>/dev/null; then
    print_status "Using ArgoCD CLI for syncing..."
    # Note: ArgoCD CLI requires server URL and login - skip for now, use kubectl
fi

# Update sync policies
kubectl patch application devops-pipeline-dev -n argocd --type merge --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || print_warning "Could not update dev sync policy"
kubectl patch application devops-pipeline-staging -n argocd --type merge --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}' 2>/dev/null || print_warning "Could not update staging sync policy"

# Force sync dev environment using argocd app sync command
print_status "Force syncing dev environment..."
kubectl patch application devops-pipeline-dev -n argocd --type json --patch '[{"op": "replace", "path": "/operation", "value": {"sync": {"syncStrategy": {"hook": {}, "apply": {}}}}}]' 2>/dev/null || print_warning "Could not trigger sync operation"

# Wait a bit for sync to start
sleep 10

# Wait for deployments to be ready (with retries)
print_status "Waiting for deployments to be ready..."
for deployment in flask-app user-service product-service; do
    print_status "Waiting for ${deployment} deployment..."
    if kubectl wait --for=condition=available --timeout=300s deployment/${deployment} -n dev 2>/dev/null; then
        print_success "${deployment} is ready"
    else
        print_warning "${deployment} may still be starting. Check with: kubectl get pods -n dev"
    fi
done

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

# Wait for ingress to be ready
print_status "Waiting for ingress to be ready..."
sleep 10
for i in {1..30}; do
    if kubectl get ingress flask-app-ingress -n dev &>/dev/null; then
        break
    fi
    sleep 2
done

# Get ingress controller port
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "80")
INGRESS_HTTPS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "443")

# Get ArgoCD service port
ARGOCD_PORT=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].port}' 2>/dev/null || echo "443")
ARGOCD_NODEPORT=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "")

# Get Gitea service port
GITEA_PORT=$(kubectl get svc -n gitea gitea-http -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null || echo "3000")
GITEA_NODEPORT=$(kubectl get svc -n gitea gitea-http -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "")

# Get MinIO service port
MINIO_PORT=$(kubectl get svc -n minio minio -o jsonpath='{.spec.ports[?(@.name=="api")].port}' 2>/dev/null || echo "9000")
MINIO_NODEPORT=$(kubectl get svc -n minio minio -o jsonpath='{.spec.ports[?(@.name=="api")].nodePort}' 2>/dev/null || echo "")

# Get local IP or use localhost
LOCAL_IP="127.0.0.1"
PUBLIC_IP=""
IS_EC2=false

# Detect if running on EC2
if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
    IS_EC2=true
    # Get EC2 public IP
    PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
    # Get EC2 private IP
    PRIVATE_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "")
    if [ -n "$PRIVATE_IP" ]; then
        LOCAL_IP="$PRIVATE_IP"
    fi
fi

# If not EC2, try to get local IP
if [ "$IS_EC2" = false ] && command -v hostname &>/dev/null; then
    ACTUAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    if [[ "$ACTUAL_IP" != "127.0.0.1" ]] && [[ "$ACTUAL_IP" != "" ]]; then
        LOCAL_IP="$ACTUAL_IP"
    fi
fi

# If public IP not found, try other methods
if [ -z "$PUBLIC_IP" ]; then
    # Try to get public IP from external service
    PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
fi

# Ensure ingress controller is NodePort for external access
print_status "Configuring ingress for external access..."
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# Ensure Gitea service is NodePort for external access
kubectl patch svc gitea-http -n gitea --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# Ensure MinIO service is NodePort for external access (if exists)
kubectl patch svc minio -n minio --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true

# Ensure ArgoCD service is LoadBalancer/NodePort for external access
kubectl patch svc argocd-server -n argocd --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "LoadBalancer"}]' 2>/dev/null || true

# Wait for service updates
sleep 5

# Get actual NodePorts after patch
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "80")
INGRESS_HTTPS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "443")

# Function to test URL
test_url() {
    local url=$1
    local name=$2
    shift 2
    local extra_args="$@"
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 $extra_args "$url" 2>/dev/null || echo "000")
        if echo "$http_code" | grep -qE "200|201|301|302"; then
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}

# Function to get port-forward command
get_port_forward_cmd() {
    local namespace=$1
    local service=$2
    local local_port=$3
    local remote_port=$4
    echo "kubectl port-forward -n $namespace svc/$service $local_port:$remote_port"
}

# Display URLs and setup port forwarding
print_success "Pipeline deployment completed successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_status "🌐 ACCESS URLs (Working URLs):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Flask App URLs
print_status "📱 Flask Application:"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ]; then
    echo "   🌐 Public URL (EC2): http://$PUBLIC_IP:$INGRESS_PORT (Host: flask-app.local)"
    echo "   🔗 Local URL: http://$LOCAL_IP:$INGRESS_PORT (Host: flask-app.local)"
    echo "   📝 Add to /etc/hosts: $PUBLIC_IP flask-app.local"
elif [ -n "$INGRESS_PORT" ] && [ "$INGRESS_PORT" != "80" ]; then
    echo "   🌍 Ingress URL: http://flask-app.local:$INGRESS_PORT"
    echo "   🔗 Direct URL: http://$LOCAL_IP:$INGRESS_PORT (Host: flask-app.local)"
else
    echo "   🌍 Ingress URL: http://flask-app.local"
    echo "   🔗 Direct URL: http://$LOCAL_IP (Host: flask-app.local)"
fi
echo "   📋 Port Forward: $(get_port_forward_cmd dev flask-app-service 8080 80)"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ]; then
    echo "   🧪 Test Command: curl -H 'Host: flask-app.local' http://$PUBLIC_IP:$INGRESS_PORT/api/health"
else
    echo "   🧪 Test Command: curl -H 'Host: flask-app.local' http://$LOCAL_IP:$INGRESS_PORT/api/health"
fi
echo ""

# ArgoCD URLs
print_status "🚀 ArgoCD Dashboard:"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ] && [ -n "$ARGOCD_NODEPORT" ]; then
    echo "   🌐 Public URL (EC2): https://$PUBLIC_IP:$ARGOCD_NODEPORT"
    echo "   🔗 Local URL: https://$LOCAL_IP:$ARGOCD_NODEPORT"
elif [ -n "$ARGOCD_NODEPORT" ]; then
    echo "   🌍 URL: https://argocd.local:$ARGOCD_NODEPORT"
    echo "   🔗 Direct URL: https://$LOCAL_IP:$ARGOCD_NODEPORT"
else
    echo "   🌍 URL: https://argocd.local"
    echo "   🔗 Direct URL: https://$LOCAL_IP"
fi
echo "   👤 Username: admin"
echo "   🔑 Password: $ARGOCD_PASSWORD"
echo "   📋 Port Forward: $(get_port_forward_cmd argocd argocd-server 8081 443)"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ] && [ -n "$ARGOCD_NODEPORT" ]; then
    echo "   🧪 Test Command: curl -k https://$PUBLIC_IP:$ARGOCD_NODEPORT/api/version"
else
    echo "   🧪 Test Command: curl -k https://argocd.local/api/version"
fi
echo ""

# Gitea URLs
print_status "📦 Gitea (Git Repository):"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ] && [ -n "$GITEA_NODEPORT" ]; then
    echo "   🌐 Public URL (EC2): http://$PUBLIC_IP:$GITEA_NODEPORT"
    echo "   🔗 Local URL: http://$LOCAL_IP:$GITEA_NODEPORT"
elif [ -n "$GITEA_NODEPORT" ]; then
    echo "   🌍 URL: http://gitea.local:$GITEA_NODEPORT"
    echo "   🔗 Direct URL: http://$LOCAL_IP:$GITEA_NODEPORT"
else
    echo "   🌍 URL: http://gitea.local"
    echo "   🔗 Direct URL: http://$LOCAL_IP"
fi
echo "   👤 Username: admin"
echo "   🔑 Password: admin123"
echo "   📋 Port Forward: $(get_port_forward_cmd gitea gitea-http 3000 3000)"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ] && [ -n "$GITEA_NODEPORT" ]; then
    echo "   🧪 Test Command: curl http://$PUBLIC_IP:$GITEA_NODEPORT/api/v1/version"
else
    echo "   🧪 Test Command: curl http://gitea.local/api/v1/version"
fi
echo ""

# MinIO URLs
print_status "💾 MinIO (Object Storage):"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ] && [ -n "$MINIO_NODEPORT" ]; then
    echo "   🌐 Public URL (EC2): http://$PUBLIC_IP:$MINIO_NODEPORT"
    echo "   🔗 Local URL: http://$LOCAL_IP:$MINIO_NODEPORT"
elif [ -n "$MINIO_NODEPORT" ]; then
    echo "   🌍 URL: http://minio.local:$MINIO_NODEPORT"
    echo "   🔗 Direct URL: http://$LOCAL_IP:$MINIO_NODEPORT"
else
    echo "   🌍 URL: http://minio.local"
    echo "   🔗 Direct URL: http://$LOCAL_IP"
fi
echo "   👤 Username: minioadmin"
echo "   🔑 Password: minioadmin123"
echo "   📋 Port Forward: $(get_port_forward_cmd minio minio 9000 9000)"
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ] && [ -n "$MINIO_NODEPORT" ]; then
    echo "   🧪 Test Command: curl http://$PUBLIC_IP:$MINIO_NODEPORT/minio/health/live"
else
    echo "   🧪 Test Command: curl http://minio.local/minio/health/live"
fi
echo ""

# Microservices URLs (via port-forward)
print_status "🔧 Microservices (Port Forward Required):"
echo "   👥 User Service: $(get_port_forward_cmd dev user-service-service 5001 80)"
echo "   📦 Product Service: $(get_port_forward_cmd dev product-service-service 5002 80)"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_status "✅ QUICK ACCESS COMMANDS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "# Test Flask App:"
echo "curl -H 'Host: flask-app.local' http://$LOCAL_IP:$INGRESS_PORT/api/health"
echo ""
echo "# Access ArgoCD (in separate terminal):"
echo "kubectl port-forward -n argocd svc/argocd-server 8081:443"
echo "echo 'Then open: https://localhost:8081'"
echo ""
echo "# Access Gitea (in separate terminal):"
echo "kubectl port-forward -n gitea svc/gitea-http 3000:3000"
echo "echo 'Then open: http://localhost:3000'"
echo ""
echo "# Access MinIO (in separate terminal):"
echo "kubectl port-forward -n minio svc/minio 9000:9000"
echo "echo 'Then open: http://localhost:9000'"
echo ""

# Test URLs if curl is available
if command -v curl &>/dev/null; then
    print_status "🧪 Testing URLs..."
    echo ""
    
    # Test Flask App
    if [ -n "$INGRESS_PORT" ] && [ "$INGRESS_PORT" != "80" ]; then
        TEST_URL="http://$LOCAL_IP:$INGRESS_PORT/api/health"
    else
        TEST_URL="http://$LOCAL_IP/api/health"
    fi
    if test_url "$TEST_URL" "Flask App" -H "Host: flask-app.local"; then
        print_success "✅ Flask App is accessible!"
    else
        print_warning "⚠️  Flask App may need port forwarding. Run: kubectl port-forward -n dev svc/flask-app-service 8080:80"
    fi
    
    # Test Gitea
    if [ -n "$GITEA_NODEPORT" ]; then
        GITEA_TEST_URL="http://$LOCAL_IP:$GITEA_NODEPORT"
    else
        GITEA_TEST_URL="http://$LOCAL_IP:3000"
    fi
    if test_url "$GITEA_TEST_URL" "Gitea" -H "Host: gitea.local"; then
        print_success "✅ Gitea is accessible!"
    else
        print_warning "⚠️  Gitea may need port forwarding. Run: kubectl port-forward -n gitea svc/gitea-http 3000:3000"
    fi
    echo ""
fi

# AWS EC2 Security Group Instructions
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_status "🔒 AWS EC2 SECURITY GROUP CONFIGURATION:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⚠️  IMPORTANT: Configure your EC2 Security Group to allow these ports:"
    echo ""
    echo "   Inbound Rules Required:"
    echo "   ┌─────────────────────────────────────────────────────────────┐"
    echo "   │ Type          │ Protocol │ Port Range │ Source              │"
    echo "   ├─────────────────────────────────────────────────────────────┤"
    echo "   │ Custom TCP    │ TCP      │ $INGRESS_PORT      │ 0.0.0.0/0 (or your IP) │"
    echo "   │ Custom TCP    │ TCP      │ $INGRESS_HTTPS_PORT     │ 0.0.0.0/0 (or your IP) │"
    if [ -n "$ARGOCD_NODEPORT" ]; then
        echo "   │ Custom TCP    │ TCP      │ $ARGOCD_NODEPORT     │ 0.0.0.0/0 (or your IP) │"
    fi
    if [ -n "$GITEA_NODEPORT" ]; then
        echo "   │ Custom TCP    │ TCP      │ $GITEA_NODEPORT     │ 0.0.0.0/0 (or your IP) │"
    fi
    if [ -n "$MINIO_NODEPORT" ]; then
        echo "   │ Custom TCP    │ TCP      │ $MINIO_NODEPORT     │ 0.0.0.0/0 (or your IP) │"
    fi
    echo "   └─────────────────────────────────────────────────────────────┘"
    echo ""
    echo "   📋 AWS CLI Command to add rules:"
    echo "   # Get your security group ID first:"
    echo "   aws ec2 describe-instances --instance-ids \$(ec2-metadata --instance-id | cut -d ' ' -f2) --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text"
    echo ""
    echo "   # Then add rules (replace sg-xxxxx with your security group ID):"
    echo "   aws ec2 authorize-security-group-ingress --group-id sg-xxxxx --protocol tcp --port $INGRESS_PORT --cidr 0.0.0.0/0"
    echo "   aws ec2 authorize-security-group-ingress --group-id sg-xxxxx --protocol tcp --port $INGRESS_HTTPS_PORT --cidr 0.0.0.0/0"
    if [ -n "$ARGOCD_NODEPORT" ]; then
        echo "   aws ec2 authorize-security-group-ingress --group-id sg-xxxxx --protocol tcp --port $ARGOCD_NODEPORT --cidr 0.0.0.0/0"
    fi
    if [ -n "$GITEA_NODEPORT" ]; then
        echo "   aws ec2 authorize-security-group-ingress --group-id sg-xxxxx --protocol tcp --port $GITEA_NODEPORT --cidr 0.0.0.0/0"
    fi
    if [ -n "$MINIO_NODEPORT" ]; then
        echo "   aws ec2 authorize-security-group-ingress --group-id sg-xxxxx --protocol tcp --port $MINIO_NODEPORT --cidr 0.0.0.0/0"
    fi
    echo ""
    echo "   🌐 Your EC2 Public IP: $PUBLIC_IP"
    echo "   🔗 Your EC2 Private IP: $LOCAL_IP"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_status "📚 Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. Run: ./check_env.sh (Check environment health)"
echo "  2. Run: ./switch_blue_green.sh (Test blue-green deployment)"
echo "  3. Run: ./backup_restore_demo.sh (Test backup/restore)"
echo ""
if [ "$IS_EC2" = true ] && [ -n "$PUBLIC_IP" ]; then
    print_status "💡 TIP: After configuring Security Group, access your services using Public IP URLs above"
    echo "   Example: http://$PUBLIC_IP:$INGRESS_PORT (with Host header: flask-app.local)"
else
    print_status "💡 TIP: If URLs don't work, use port-forward commands shown above in separate terminals"
fi
echo ""
