#!/bin/bash

# fix_pending_pods.sh - Fix pending pods issues
# This script diagnoses and fixes pods stuck in Pending status

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

print_status "🔧 Fixing Pending Pods Issues..."

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
kubectl get nodes
echo ""
kubectl top nodes 2>/dev/null || print_warning "Metrics server not available (this is OK for kind)"

# Check node capacity
print_status "Node capacity:"
kubectl describe nodes | grep -A 5 "Allocated resources:" || kubectl describe nodes | grep -A 5 "Capacity:"

# Step 2: Check pending pods and their events
print_status "2. Checking pending pods..."

PENDING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

if [ -z "$PENDING_PODS" ]; then
    print_success "No pending pods found!"
    exit 0
fi

echo "$PENDING_PODS" | while IFS=$'\t' read -r namespace podname; do
    if [ -n "$podname" ]; then
        print_status "Checking pod: $namespace/$podname"
        
        # Get pod events
        echo "  Events:"
        kubectl describe pod "$podname" -n "$namespace" | grep -A 10 "Events:" || kubectl get events -n "$namespace" --field-selector involvedObject.name="$podname" --sort-by='.lastTimestamp' | tail -5
        
        # Check why it's pending
        REASON=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || echo "Unknown")
        MESSAGE=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || echo "Unknown")
        
        echo "  Reason: $REASON"
        echo "  Message: $MESSAGE"
        echo ""
    fi
done

# Step 3: Fix common issues

# Fix 3.1: Check if nodes are ready
print_status "3. Checking node readiness..."
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
READY_COUNT=$(kubectl get nodes --no-headers | grep Ready | wc -l)

if [ "$READY_COUNT" -eq 0 ]; then
    print_error "No nodes are ready!"
    print_status "Restarting Docker and cluster..."
    systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
    sleep 10
    kubectl get nodes
fi

# Fix 3.2: Check resource requests
print_status "4. Checking resource requests..."

# Check Flask app resource requests
if kubectl get deployment flask-app -n dev &>/dev/null; then
    print_status "Flask app resource requests:"
    kubectl get deployment flask-app -n dev -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq '.' 2>/dev/null || kubectl get deployment flask-app -n dev -o yaml | grep -A 10 "resources:"
    
    # If resources are too high, reduce them
    print_status "Checking if resources need adjustment..."
    kubectl get deployment flask-app -n dev -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null | grep -q "Gi" && {
        print_warning "Flask app has high memory requests. Reducing..."
        kubectl patch deployment flask-app -n dev --type json -p='[
            {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "64Mi"},
            {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "50m"},
            {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "128Mi"},
            {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "100m"}
        ]' 2>/dev/null || print_warning "Could not patch resources"
    }
fi

# Fix 3.3: Delete pending pods to force reschedule
print_status "5. Attempting to reschedule pending pods..."

# Delete Flask app pending pods
if kubectl get pods -n dev -l app=flask-app --field-selector=status.phase=Pending 2>/dev/null | grep -q flask-app; then
    print_status "Deleting pending Flask app pods..."
    kubectl delete pods -n dev -l app=flask-app --field-selector=status.phase=Pending --grace-period=0 --force 2>/dev/null || true
    sleep 5
fi

# Delete MinIO pending pods
if kubectl get pods -n minio --field-selector=status.phase=Pending 2>/dev/null | grep -q minio; then
    print_status "Deleting pending MinIO pods..."
    kubectl delete pods -n minio --field-selector=status.phase=Pending --grace-period=0 --force 2>/dev/null || true
    sleep 5
fi

# Fix 3.4: Check and fix PVC issues
print_status "6. Checking PersistentVolumeClaims..."
kubectl get pvc --all-namespaces | grep -i pending && {
    print_warning "Found pending PVCs. This might be causing pod scheduling issues."
    print_status "For kind clusters, PVCs should use local storage. Checking storage class..."
    kubectl get storageclass
}

# Fix 3.5: Ensure storage class exists
if ! kubectl get storageclass standard &>/dev/null && ! kubectl get storageclass local-path &>/dev/null; then
    print_status "Creating default storage class..."
    cat > /tmp/storageclass.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
EOF
    kubectl apply -f /tmp/storageclass.yaml 2>/dev/null || print_warning "Could not create storage class"
    rm -f /tmp/storageclass.yaml
fi

# Fix 3.6: Check node taints
print_status "7. Checking node taints..."
kubectl describe nodes | grep -i taint || print_success "No taints found on nodes"

# Fix 3.7: Scale down and up to force reschedule
print_status "8. Scaling deployments to force reschedule..."

# Flask app
if kubectl get deployment flask-app -n dev &>/dev/null; then
    print_status "Scaling Flask app..."
    CURRENT_REPLICAS=$(kubectl get deployment flask-app -n dev -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    kubectl scale deployment flask-app -n dev --replicas=0 2>/dev/null || true
    sleep 5
    kubectl scale deployment flask-app -n dev --replicas=${CURRENT_REPLICAS} 2>/dev/null || kubectl scale deployment flask-app -n dev --replicas=1 2>/dev/null || true
    sleep 10
fi

# MinIO
if kubectl get deployment minio -n minio &>/dev/null; then
    print_status "Scaling MinIO..."
    kubectl scale deployment minio -n minio --replicas=0 2>/dev/null || true
    sleep 5
    kubectl scale deployment minio -n minio --replicas=1 2>/dev/null || true
    sleep 10
fi

# Fix 3.8: Check if images are available
print_status "9. Checking if images are available..."
if kubectl get deployment flask-app -n dev &>/dev/null; then
    IMAGE=$(kubectl get deployment flask-app -n dev -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    if [ -n "$IMAGE" ]; then
        print_status "Flask app image: $IMAGE"
        # Check if image exists in kind cluster
        if echo "$IMAGE" | grep -q "flask-app"; then
            print_status "Verifying image is loaded in cluster..."
            docker images | grep flask-app || print_warning "Image not found locally. May need to rebuild."
        fi
    fi
fi

# Fix 3.9: Wait and check status
print_status "10. Waiting for pods to schedule..."
sleep 15

# Check status again
print_status "Current pod status:"
kubectl get pods --all-namespaces --field-selector=status.phase=Pending

# Final status check
print_status "11. Final status check..."
echo ""
print_status "Flask app pods:"
kubectl get pods -n dev -l app=flask-app

echo ""
print_status "MinIO pods:"
kubectl get pods -n minio

echo ""
print_status "All pending pods:"
PENDING_COUNT=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [ "$PENDING_COUNT" -eq 0 ]; then
    print_success "No pending pods! All pods should be scheduling now."
else
    print_warning "Still have $PENDING_COUNT pending pod(s)."
    echo ""
    print_status "Troubleshooting steps:"
    echo "  1. Check node resources: kubectl describe nodes"
    echo "  2. Check pod events: kubectl describe pod <pod-name> -n <namespace>"
    echo "  3. Check if storage is available: kubectl get pv,pvc"
    echo "  4. Check node capacity: kubectl top nodes"
    echo "  5. Try deleting and recreating the deployment"
    echo ""
    print_status "Common solutions:"
    echo "  - Reduce resource requests in deployment"
    echo "  - Add more nodes to cluster"
    echo "  - Check storage class configuration"
    echo "  - Restart Docker: systemctl restart docker"
fi

# Display summary
echo ""
print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_status "Fix Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_status "Next steps:"
echo "  1. Wait a few minutes for pods to start"
echo "  2. Check pod status: kubectl get pods -n dev"
echo "  3. If still pending, check: kubectl describe pod <pod-name> -n dev"
echo "  4. Check node resources: kubectl describe nodes"
echo "  5. Run: ./fix_flask_app.sh to fix Flask app specifically"

