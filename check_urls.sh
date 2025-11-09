#!/bin/bash

# check_urls.sh - Check accessibility of all application URLs
# This script tests all service endpoints and displays their status

set +e

echo "🔍 Checking Application URLs..."
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Get public IP
print_status "Detecting public IP address..."
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null)
fi
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="localhost"
    print_warning "Could not detect public IP, using localhost"
fi

echo ""
echo "=========================================="
echo "🌐 APPLICATION URLs"
echo "=========================================="
echo ""

# Function to check URL
check_url() {
    local name=$1
    local url=$2
    local expected_code=${3:-200}
    
    printf "%-20s %s ... " "$name" "$url"
    
    response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)
    
    # Success codes: 200, 302, 307 (redirects), 403 (service exists but needs auth)
    if [ "$response" = "200" ] || [ "$response" = "302" ] || [ "$response" = "307" ]; then
        print_success "OK (HTTP $response)"
        return 0
    elif [ "$response" = "403" ]; then
        print_success "OK - Needs Authentication (HTTP $response)"
        return 0
    elif [ -z "$response" ] || [ "$response" = "000" ]; then
        print_error "UNREACHABLE"
        return 1
    else
        print_warning "HTTP $response"
        return 1
    fi
}

# Check all services
FLASK_URL="http://${PUBLIC_IP}:30080"
USER_URL="http://${PUBLIC_IP}:30081/api/users"
PRODUCT_URL="http://${PUBLIC_IP}:30082/api/products"
ARGOCD_URL="http://${PUBLIC_IP}:30083"
GITEA_URL="http://${PUBLIC_IP}:30084"
MINIO_URL="http://${PUBLIC_IP}:30085"
REGISTRY_URL="http://${PUBLIC_IP}:30500/v2/"

check_url "Flask App" "$FLASK_URL"
check_url "User Service" "$USER_URL"
check_url "Product Service" "$PRODUCT_URL"
check_url "ArgoCD" "$ARGOCD_URL"
check_url "Gitea" "$GITEA_URL"
check_url "MinIO" "$MINIO_URL"
check_url "Docker Registry" "$REGISTRY_URL"

echo ""
echo "=========================================="
echo "📊 KUBERNETES STATUS"
echo "=========================================="
echo ""

# Check cluster status
print_status "Cluster Status:"
if kubectl cluster-info &>/dev/null; then
    print_success "Cluster is running"
else
    print_error "Cluster is not accessible"
fi

echo ""
print_status "Nodes:"
kubectl get nodes 2>/dev/null || print_error "Cannot get nodes"

echo ""
print_status "Pods in dev namespace:"
kubectl get pods -n dev 2>/dev/null || print_error "Cannot get pods"

echo ""
print_status "Services in dev namespace:"
kubectl get svc -n dev 2>/dev/null || print_error "Cannot get services"

echo ""
echo "=========================================="
echo "🔐 CREDENTIALS"
echo "=========================================="
echo ""
echo "Gitea:  admin / admin123"
echo "MinIO:  minioadmin / minioadmin123"
echo ""
echo "ArgoCD Password:"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
if [ -n "$ARGOCD_PASSWORD" ]; then
    echo "  Username: admin"
    echo "  Password: $ARGOCD_PASSWORD"
else
    echo "  Run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
fi

echo ""
echo "=========================================="
echo "⚠️  TROUBLESHOOTING"
echo "=========================================="
echo ""

# Check for common issues
ISSUES_FOUND=0

# Check if pods are running
NOT_RUNNING=$(kubectl get pods -n dev 2>/dev/null | grep -v Running | grep -v NAME | grep -v Completed | wc -l)
if [ "$NOT_RUNNING" -gt 0 ]; then
    print_warning "Found $NOT_RUNNING pod(s) not in Running state"
    kubectl get pods -n dev | grep -v Running | grep -v NAME | grep -v Completed
    ISSUES_FOUND=1
fi

# Check for ImagePullBackOff
IMAGE_PULL_ERRORS=$(kubectl get pods -n dev 2>/dev/null | grep -c ImagePullBackOff)
if [ "$IMAGE_PULL_ERRORS" -gt 0 ]; then
    print_error "Found ImagePullBackOff errors - run: ./fix_registry.sh"
    ISSUES_FOUND=1
fi

# Check for CrashLoopBackOff
CRASH_ERRORS=$(kubectl get pods -n dev 2>/dev/null | grep -c CrashLoopBackOff)
if [ "$CRASH_ERRORS" -gt 0 ]; then
    print_error "Found CrashLoopBackOff errors - check logs with: kubectl logs -n dev <pod-name>"
    ISSUES_FOUND=1
fi

# Check if services are exposed
NODEPORT_SERVICES=$(kubectl get svc -n dev -o jsonpath='{.items[*].spec.type}' 2>/dev/null | grep -c NodePort)
if [ "$NODEPORT_SERVICES" -eq 0 ]; then
    print_warning "No NodePort services found - services may not be accessible externally"
    ISSUES_FOUND=1
fi

# Check AWS Security Group reminder
echo ""
if [ "$ISSUES_FOUND" -eq 0 ]; then
    print_success "No issues detected!"
    echo ""
    print_status "If URLs are unreachable from browser, check AWS Security Group:"
    echo "  - Ensure ports 30080-30085 and 30500 are open"
    echo "  - Source: 0.0.0.0/0 (or your IP)"
else
    echo ""
    print_warning "Issues detected! Check the messages above."
    echo ""
    print_status "Common fixes:"
    echo "  - ImagePullBackOff: ./fix_registry.sh"
    echo "  - CrashLoopBackOff: kubectl logs -n dev <pod-name>"
    echo "  - Unreachable URLs: Check AWS Security Group ports"
fi

echo ""
echo "=========================================="
echo "📝 QUICK COMMANDS"
echo "=========================================="
echo ""
echo "View pod logs:     kubectl logs -n dev <pod-name>"
echo "Describe pod:      kubectl describe pod -n dev <pod-name>"
echo "Restart pod:       kubectl delete pod -n dev <pod-name>"
echo "View events:       kubectl get events -n dev --sort-by='.lastTimestamp'"
echo "Port forward:      kubectl port-forward -n dev svc/<service-name> 8080:80"
echo ""
