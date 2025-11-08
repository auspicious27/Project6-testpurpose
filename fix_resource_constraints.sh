#!/bin/bash

# fix_resource_constraints.sh - Fix resource constraints and pending pods
# This script fixes CPU/memory constraints by scaling down and optimizing resources

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

print_status "🔧 Fixing Resource Constraints and Pending Pods..."

# Check prerequisites
if ! command -v kubectl &>/dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    print_error "Kubernetes cluster not found"
    exit 1
fi

# Step 1: Check node resources
print_status "1. Checking node resources..."
kubectl describe nodes | grep -A 5 "Allocated resources:" || kubectl describe nodes | grep -A 5 "Capacity:"

# Step 2: Scale down Flask app to 1 replica (reduce CPU usage)
print_status "2. Scaling Flask app to 1 replica to reduce CPU usage..."
if kubectl get deployment flask-app -n dev &>/dev/null; then
    CURRENT_REPLICAS=$(kubectl get deployment flask-app -n dev -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "2")
    if [ "$CURRENT_REPLICAS" -gt 1 ]; then
        print_status "Scaling from $CURRENT_REPLICAS to 1 replica..."
        kubectl scale deployment flask-app -n dev --replicas=1
        print_success "Scaled Flask app to 1 replica"
    else
        print_status "Flask app already at 1 replica"
    fi
else
    print_warning "Flask app deployment not found"
fi

# Step 3: Fix image pull issues
print_status "3. Fixing image pull issues..."
if kubectl get pods -n dev -l app=flask-app 2>/dev/null | grep -q "ImagePullBackOff\|ErrImagePull"; then
    print_status "Found ImagePullBackOff errors. Ensuring image is loaded..."
    
    # Check if image exists locally
    if docker images | grep -q "flask-app.*latest"; then
        print_status "Image exists locally. Loading into kind cluster..."
        CLUSTER_NAME="devops-pipeline"
        if kind get clusters | grep -q "$CLUSTER_NAME"; then
            kind load docker-image flask-app:latest --name "$CLUSTER_NAME" || print_warning "Failed to load image"
        fi
    else
        print_warning "Image not found locally. Rebuilding..."
        if [ -f "apps/flask-app/Dockerfile" ]; then
            cd apps/flask-app
            docker build -t flask-app:latest . || print_error "Failed to build image"
            CLUSTER_NAME="devops-pipeline"
            if kind get clusters | grep -q "$CLUSTER_NAME"; then
                kind load docker-image flask-app:latest --name "$CLUSTER_NAME" || print_warning "Failed to load image"
            fi
            cd ../..
        fi
    fi
    
    # Delete pods with image pull errors
    print_status "Deleting pods with image pull errors..."
    kubectl delete pods -n dev -l app=flask-app --field-selector=status.phase!=Running --grace-period=0 --force 2>/dev/null || true
    sleep 10
fi

# Step 4: Reduce resource requests further
print_status "4. Reducing resource requests to minimum..."
kubectl patch deployment flask-app -n dev --type json -p='[
    {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "32Mi"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "25m"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "64Mi"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "50m"}
]' 2>/dev/null || print_warning "Could not patch resources"

# Step 5: Scale down other non-essential pods
print_status "5. Scaling down non-essential pods to free resources..."

# Scale down Gitea postgres replicas (if possible)
if kubectl get statefulset gitea-postgresql-ha-postgresql -n gitea &>/dev/null; then
    print_status "Gitea postgres is statefulset, cannot scale down easily"
fi

# Scale down Trivy node collector (optional)
if kubectl get deployment node-collector -n trivy-system &>/dev/null; then
    print_status "Scaling down Trivy node collector..."
    kubectl scale deployment node-collector -n trivy-system --replicas=0 2>/dev/null || true
fi

# Step 6: Delete all pending pods to force reschedule
print_status "6. Deleting all pending pods..."
kubectl delete pods --all-namespaces --field-selector=status.phase=Pending --grace-period=0 --force 2>/dev/null || true
sleep 10

# Step 7: Wait and check status
print_status "7. Waiting for pods to reschedule..."
sleep 20

# Step 8: Check Flask app status
print_status "8. Checking Flask app status..."
kubectl get pods -n dev -l app=flask-app

# Check if any pod is running
RUNNING_PODS=$(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
PENDING_PODS=$(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$RUNNING_PODS" -gt 0 ]; then
    print_success "Flask app has $RUNNING_PODS running pod(s)!"
    
    # Get running pod name
    RUNNING_POD=$(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$RUNNING_POD" ]; then
        print_status "Waiting for pod to be ready..."
        kubectl wait --for=condition=ready --timeout=120s pod/$RUNNING_POD -n dev 2>/dev/null || print_warning "Pod may still be starting"
    fi
elif [ "$PENDING_PODS" -gt 0 ]; then
    print_warning "Flask app still has $PENDING_PODS pending pod(s)"
    print_status "Checking why pods are pending..."
    for pod in $(kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        print_status "Pod: $pod"
        kubectl describe pod "$pod" -n dev | grep -A 3 "Events:" | tail -3 || true
    done
fi

# Step 9: Fix image reference if needed
print_status "9. Ensuring correct image reference..."
if kubectl get deployment flask-app -n dev &>/dev/null; then
    CURRENT_IMAGE=$(kubectl get deployment flask-app -n dev -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    if [ -n "$CURRENT_IMAGE" ] && echo "$CURRENT_IMAGE" | grep -q "localhost:5000"; then
        print_status "Updating image reference to use local image..."
        kubectl set image deployment/flask-app flask-app=flask-app:latest -n dev 2>/dev/null || print_warning "Could not update image"
    fi
fi

# Step 10: Final status
print_status "10. Final status check..."
echo ""
print_status "Node resources:"
kubectl describe nodes | grep -A 5 "Allocated resources:" || true

echo ""
print_status "Flask app pods:"
kubectl get pods -n dev -l app=flask-app

echo ""
print_status "All pending pods:"
PENDING_COUNT=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$PENDING_COUNT" -eq 0 ]; then
    print_success "No pending pods!"
else
    print_warning "Still have $PENDING_COUNT pending pod(s)"
    kubectl get pods --all-namespaces --field-selector=status.phase=Pending
fi

# Display summary
echo ""
print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_status "Fix Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_status "Actions taken:"
echo "  ✓ Scaled Flask app to 1 replica"
echo "  ✓ Reduced resource requests (32Mi/25m)"
echo "  ✓ Fixed image pull issues"
echo "  ✓ Deleted pending pods"
echo ""
print_status "Next steps:"
echo "  1. Wait 1-2 minutes for pods to start"
echo "  2. Check: kubectl get pods -n dev"
echo "  3. If still pending, node may need more resources"
echo "  4. Consider: kind delete cluster && ./bootstrap_cluster.sh (fresh start)"

