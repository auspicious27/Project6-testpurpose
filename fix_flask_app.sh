#!/bin/bash

# fix_flask_app.sh - Comprehensive fix for Flask application deployment issues
# This script fixes: pods not running, service not accessible, ingress issues, secret mismatches

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

print_status "🔧 Fixing Flask Application Deployment..."

# Check prerequisites
if ! command -v kubectl &>/dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    print_error "Kubernetes cluster not found"
    exit 1
fi

# Step 1: Ensure dev namespace exists
print_status "1. Ensuring dev namespace exists..."
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f - || kubectl create namespace dev || true
print_success "Namespace dev exists"

# Step 2: Check if images are loaded
print_status "2. Checking if Docker images are loaded in cluster..."
CLUSTER_NAME="devops-pipeline"

if ! kind get clusters | grep -q "$CLUSTER_NAME"; then
    print_warning "Kind cluster not found. Skipping image check."
else
    # Check if images exist
    if ! docker images | grep -q "flask-app.*latest"; then
        print_warning "Flask app image not found locally. Building..."
        cd apps/flask-app
        docker build -t flask-app:latest . || print_error "Failed to build Flask app"
        kind load docker-image flask-app:latest --name "$CLUSTER_NAME" || print_warning "Failed to load image"
        cd ../..
    else
        print_success "Flask app image found"
    fi
fi

# Step 3: Check and fix secrets
print_status "3. Checking secrets..."
if ! kubectl get secret dev-secrets -n dev &>/dev/null; then
    print_status "Creating dev-secrets..."
    kubectl create secret generic dev-secrets \
        --from-literal=secret-key=dev-secret-key-123 \
        -n dev || print_warning "Could not create secret"
else
    print_success "Secret dev-secrets exists"
fi

# Step 4: Check ArgoCD application sync status
print_status "4. Checking ArgoCD application sync..."
if kubectl get application devops-pipeline-dev -n argocd &>/dev/null; then
    SYNC_STATUS=$(kubectl get application devops-pipeline-dev -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get application devops-pipeline-dev -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "  Current status: Sync=$SYNC_STATUS, Health=$HEALTH_STATUS"
    
    if [ "$SYNC_STATUS" != "Synced" ]; then
        print_status "Triggering ArgoCD sync..."
        kubectl patch application devops-pipeline-dev -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
        kubectl patch application devops-pipeline-dev -n argocd --type json -p='[{"op": "add", "path": "/operation", "value": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}]' 2>/dev/null || true
        print_status "Waiting for sync to complete..."
        sleep 20
    fi
else
    print_warning "ArgoCD application not found. Deploying manually..."
    
    # Deploy manually if ArgoCD is not working
    if kubectl get deployment flask-app -n dev &>/dev/null; then
        print_status "Deployment exists, checking status..."
    else
        print_status "Deploying Flask app manually..."
        kubectl apply -f apps/flask-app/deployment.yaml -n dev || print_error "Failed to deploy"
    fi
fi

# Step 5: Check and fix pending pods
print_status "5. Checking for pending pods..."
PENDING_PODS=$(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$PENDING_PODS" -gt 0 ]; then
    print_warning "Found $PENDING_PODS pending pod(s). Fixing..."
    
    # Check why pods are pending
    for pod in $(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        print_status "Checking pod: $pod"
        kubectl describe pod "$pod" -n dev | grep -A 5 "Events:" || true
        REASON=$(kubectl get pod "$pod" -n dev -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || echo "Unknown")
        print_status "  Reason: $REASON"
    done
    
    # Reduce resource requests if too high
    print_status "Reducing resource requests to allow scheduling..."
    kubectl patch deployment flask-app -n dev --type json -p='[
        {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "64Mi"},
        {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "50m"},
        {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "128Mi"},
        {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "100m"}
    ]' 2>/dev/null || print_warning "Could not patch resources"
    
    # Delete pending pods to force reschedule
    print_status "Deleting pending pods to force reschedule..."
    kubectl delete pods -n dev -l app=flask-app --field-selector=status.phase=Pending --grace-period=0 --force 2>/dev/null || true
    sleep 10
fi

# Step 6: Check deployment status
print_status "6. Checking deployment status..."
if kubectl get deployment flask-app -n dev &>/dev/null; then
    DESIRED=$(kubectl get deployment flask-app -n dev -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    READY=$(kubectl get deployment flask-app -n dev -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    echo "  Desired replicas: $DESIRED"
    echo "  Ready replicas: $READY"
    
    if [ "$READY" -eq 0 ] || [ "$READY" -lt "$DESIRED" ]; then
        print_warning "Deployment not ready. Checking pod status..."
        
        # Check pod status
        kubectl get pods -n dev -l app=flask-app || true
        echo ""
        
        # Check if pods are still pending
        PENDING_COUNT=$(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$PENDING_COUNT" -gt 0 ]; then
            print_error "Pods are still pending. Run: ./fix_pending_pods.sh"
            print_status "Or check node resources: kubectl describe nodes"
        else
            print_status "Pod events:"
            kubectl get events -n dev --sort-by='.lastTimestamp' | grep flask-app | tail -5 || true
            
            # Check pod logs if any pod exists
            POD_NAME=$(kubectl get pods -n dev -l app=flask-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$POD_NAME" ]; then
                echo ""
                print_status "Pod logs (last 20 lines):"
                kubectl logs -n dev "$POD_NAME" --tail=20 2>/dev/null || true
            fi
        fi
        
        print_status "Waiting for deployment to be ready..."
        kubectl wait --for=condition=available --timeout=300s deployment/flask-app -n dev 2>/dev/null || \
        print_warning "Deployment may still be starting. Check with: kubectl get pods -n dev"
    else
        print_success "Deployment is ready!"
    fi
else
    print_error "Flask app deployment not found!"
    print_status "Trying to deploy manually..."
    kubectl apply -f apps/flask-app/deployment.yaml -n dev || print_error "Failed to deploy"
    sleep 10
fi

# Step 6: Check service
print_status "6. Checking service..."
if kubectl get svc flask-app-service -n dev &>/dev/null; then
    print_success "Service flask-app-service exists"
    kubectl get svc flask-app-service -n dev
else
    print_warning "Service not found. Creating..."
    kubectl apply -f apps/flask-app/deployment.yaml -n dev || print_error "Failed to create service"
fi

# Step 7: Check and create ingress
print_status "7. Checking ingress..."
if kubectl get ingress flask-app-ingress -n dev &>/dev/null; then
    print_success "Ingress exists"
    kubectl get ingress flask-app-ingress -n dev
else
    print_status "Creating ingress..."
    cat > /tmp/flask-ingress-fix.yaml << EOF
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
    kubectl apply -f /tmp/flask-ingress-fix.yaml
    rm -f /tmp/flask-ingress-fix.yaml
    print_success "Ingress created"
fi

# Step 8: Ensure ingress controller is NodePort
print_status "8. Configuring ingress controller for external access..."
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}]' 2>/dev/null || true
sleep 3

# Step 9: Get access information
print_status "9. Getting access information..."
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "N/A")
PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")

# Step 10: Test connectivity
print_status "10. Testing connectivity..."
if [ "$INGRESS_PORT" != "N/A" ]; then
    print_status "Testing local connection..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H 'Host: flask-app.local' --max-time 5 "http://127.0.0.1:$INGRESS_PORT/api/health" 2>/dev/null || echo "000")
    
    if echo "$HTTP_CODE" | grep -qE "200|201|301|302"; then
        print_success "Flask app is accessible locally!"
    else
        print_warning "Flask app returned HTTP $HTTP_CODE. May still be starting..."
    fi
fi

# Display summary
echo ""
print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "Flask Application Fix Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Show pod status
print_status "Pod Status:"
kubectl get pods -n dev -l app=flask-app || print_warning "No pods found"

echo ""
print_status "Service Status:"
kubectl get svc flask-app-service -n dev || print_warning "Service not found"

echo ""
print_status "Ingress Status:"
kubectl get ingress flask-app-ingress -n dev || print_warning "Ingress not found"

echo ""
print_status "Access URLs:"
if [ "$INGRESS_PORT" != "N/A" ]; then
    echo "  Local: http://127.0.0.1:$INGRESS_PORT (with Host: flask-app.local)"
    if [ -n "$PUBLIC_IP" ]; then
        echo "  Public (EC2): http://$PUBLIC_IP:$INGRESS_PORT (with Host: flask-app.local)"
    fi
    echo ""
    print_status "Test Commands:"
    echo "  curl -H 'Host: flask-app.local' http://127.0.0.1:$INGRESS_PORT/api/health"
    if [ -n "$PUBLIC_IP" ]; then
        echo "  curl -H 'Host: flask-app.local' http://$PUBLIC_IP:$INGRESS_PORT/api/health"
    fi
else
    print_warning "Ingress port not available. Check ingress controller: kubectl get svc -n ingress-nginx"
fi

echo ""
print_status "Troubleshooting Commands:"
echo "  # Check pods:"
echo "  kubectl get pods -n dev"
echo "  kubectl describe pod -n dev <pod-name>"
echo "  kubectl logs -n dev <pod-name>"
echo ""
echo "  # Check service:"
echo "  kubectl get svc -n dev"
echo "  kubectl describe svc flask-app-service -n dev"
echo ""
echo "  # Check ingress:"
echo "  kubectl get ingress -n dev"
echo "  kubectl describe ingress flask-app-ingress -n dev"
echo ""
echo "  # Port forward (alternative access):"
echo "  kubectl port-forward -n dev svc/flask-app-service 8080:80"

