#!/bin/bash

# test_urls.sh - Quick test script to verify all URLs are working

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
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

echo ""
echo "🧪 Testing All Service URLs..."
echo ""

# Get public IP
PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "localhost")

test_url() {
    local url=$1
    local name=$2
    local expected_code=${3:-200}
    
    print_status "Testing $name..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)
    
    if [ "$HTTP_CODE" = "$expected_code" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
        print_success "$name is working! (HTTP $HTTP_CODE)"
        echo "   URL: $url"
        return 0
    else
        print_error "$name is NOT working (HTTP $HTTP_CODE)"
        echo "   URL: $url"
        return 1
    fi
}

# Test Flask App
test_url "http://localhost:30080" "Flask Application" "200"
test_url "http://localhost:30080/api/health" "Flask App Health" "200"

# Test User Service
test_url "http://localhost:30081/api/users" "User Service API" "200"

# Test Product Service
test_url "http://localhost:30082/api/products" "Product Service API" "200"

# Test Gitea
GITEA_NODEPORT=$(kubectl get svc gitea-http -n gitea -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30084")
test_url "http://localhost:${GITEA_NODEPORT}" "Gitea" "200"

# Test ArgoCD
ARGOCD_NODEPORT=$(kubectl get svc argocd-server-nodeport -n argocd -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30083")
test_url "http://localhost:${ARGOCD_NODEPORT}" "ArgoCD" "200"

echo ""
echo "=========================================="
echo "📋 Access URLs Summary:"
echo "=========================================="
echo ""
echo "Flask App:        http://${PUBLIC_IP}:30080"
echo "User Service:     http://${PUBLIC_IP}:30081/api/users"
echo "Product Service:  http://${PUBLIC_IP}:30082/api/products"
echo "Gitea:            http://${PUBLIC_IP}:${GITEA_NODEPORT} (admin/admin123)"
echo "ArgoCD:           http://${PUBLIC_IP}:${ARGOCD_NODEPORT}"
echo ""
echo "If services are not working, run: ./fix_all_services.sh"
echo ""

