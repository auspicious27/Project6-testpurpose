#!/bin/bash

# check_gitea.sh - Comprehensive Gitea diagnostic script
# This script checks Gitea pods, services, ingress, and provides troubleshooting steps

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

GITEA_NAMESPACE="gitea"
CLUSTER_NAME="devops-pipeline"

echo ""
print_header "Gitea Diagnostic Script"
echo ""

# Step 1: Check Docker
print_header "Step 1: Checking Docker Status"
if docker info >/dev/null 2>&1; then
    print_success "Docker is running"
    docker version --format "Docker Version: {{.Server.Version}}" 2>/dev/null || true
else
    print_error "Docker is NOT running!"
    echo ""
    echo "To start Docker:"
    echo "  macOS: Open Docker Desktop application"
    echo "  Linux: sudo systemctl start docker"
    echo ""
    exit 1
fi

# Step 2: Check Kubernetes cluster
print_header "Step 2: Checking Kubernetes Cluster"
if command -v kind >/dev/null 2>&1; then
    if kind get clusters | grep -q "${CLUSTER_NAME}"; then
        print_success "Cluster '${CLUSTER_NAME}' exists"
        
        # Check if cluster is accessible
        if kubectl cluster-info >/dev/null 2>&1; then
            print_success "Cluster is accessible"
            kubectl cluster-info | head -1
        else
            print_error "Cluster exists but is not accessible"
            print_status "Trying to set kubeconfig..."
            kind get kubeconfig --name ${CLUSTER_NAME} > ~/.kube/config 2>/dev/null
            export KUBECONFIG=~/.kube/config
            kubectl config use-context kind-${CLUSTER_NAME} 2>/dev/null || true
        fi
    else
        print_error "Cluster '${CLUSTER_NAME}' does not exist!"
        echo ""
        echo "To create cluster, run:"
        echo "  ./bootstrap_cluster.sh"
        echo ""
        exit 1
    fi
else
    print_error "kind command not found!"
    echo "Please install kind first"
    exit 1
fi

# Set kubeconfig
export KUBECONFIG=~/.kube/config
kubectl config use-context kind-${CLUSTER_NAME} 2>/dev/null || true

# Step 3: Check Gitea namespace
print_header "Step 3: Checking Gitea Namespace"
if kubectl get namespace ${GITEA_NAMESPACE} >/dev/null 2>&1; then
    print_success "Namespace '${GITEA_NAMESPACE}' exists"
    kubectl get namespace ${GITEA_NAMESPACE}
else
    print_error "Namespace '${GITEA_NAMESPACE}' does not exist!"
    echo ""
    echo "To create namespace, run:"
    echo "  kubectl create namespace ${GITEA_NAMESPACE}"
    echo ""
    exit 1
fi

# Step 4: Check Gitea Pods
print_header "Step 4: Checking Gitea Pods"
echo ""
print_status "All pods in ${GITEA_NAMESPACE} namespace:"
kubectl get pods -n ${GITEA_NAMESPACE} 2>/dev/null || {
    print_error "Cannot get pods. Check cluster connectivity."
    exit 1
}

echo ""
print_status "Gitea pods with details:"
kubectl get pods -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea -o wide 2>/dev/null || true

echo ""
print_status "Pod status breakdown:"
PODS=$(kubectl get pods -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea --no-headers 2>/dev/null || true)

if [ -z "$PODS" ]; then
    print_error "No Gitea pods found!"
    echo ""
    echo "Gitea may not be installed. To install:"
    echo "  ./bootstrap_cluster.sh"
    echo ""
else
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            POD_NAME=$(echo "$line" | awk '{print $1}')
            POD_STATUS=$(echo "$line" | awk '{print $3}')
            POD_READY=$(echo "$line" | awk '{print $2}')
            
            echo "  Pod: $POD_NAME"
            echo "    Status: $POD_STATUS"
            echo "    Ready: $POD_READY"
            
            if [ "$POD_STATUS" != "Running" ] || [ "$POD_READY" != "1/1" ]; then
                print_warning "Pod $POD_NAME is not ready!"
                echo ""
                print_status "Recent events for $POD_NAME:"
                kubectl describe pod $POD_NAME -n ${GITEA_NAMESPACE} 2>/dev/null | tail -10 || true
                echo ""
            else
                print_success "Pod $POD_NAME is running and ready"
            fi
        fi
    done <<< "$PODS"
fi

# Step 5: Check Gitea Services
print_header "Step 5: Checking Gitea Services"
echo ""
print_status "All services in ${GITEA_NAMESPACE} namespace:"
kubectl get svc -n ${GITEA_NAMESPACE} 2>/dev/null || true

echo ""
print_status "Service details:"
SERVICES=$(kubectl get svc -n ${GITEA_NAMESPACE} --no-headers 2>/dev/null || true)

if [ -z "$SERVICES" ]; then
    print_error "No services found in ${GITEA_NAMESPACE} namespace!"
else
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            SVC_NAME=$(echo "$line" | awk '{print $1}')
            SVC_TYPE=$(echo "$line" | awk '{print $2}')
            CLUSTER_IP=$(echo "$line" | awk '{print $3}')
            EXTERNAL_IP=$(echo "$line" | awk '{print $4}')
            PORT=$(echo "$line" | awk '{print $5}')
            
            echo "  Service: $SVC_NAME"
            echo "    Type: $SVC_TYPE"
            echo "    Cluster IP: $CLUSTER_IP"
            echo "    External IP: $EXTERNAL_IP"
            echo "    Port: $PORT"
            
            # Check for NodePort
            if [ "$SVC_TYPE" = "NodePort" ]; then
                NODEPORT=$(kubectl get svc $SVC_NAME -n ${GITEA_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
                echo "    NodePort: $NODEPORT"
                print_success "Service $SVC_NAME is exposed via NodePort"
            elif [ "$SVC_TYPE" = "ClusterIP" ]; then
                print_warning "Service $SVC_NAME is ClusterIP (not accessible externally)"
                echo "    To expose it, run:"
                echo "      kubectl patch svc $SVC_NAME -n ${GITEA_NAMESPACE} -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":3000,\"targetPort\":3000,\"nodePort\":30084}]}}'"
            fi
            echo ""
        fi
    done <<< "$SERVICES"
fi

# Step 6: Check Gitea Ingress
print_header "Step 6: Checking Gitea Ingress"
echo ""
INGRESS=$(kubectl get ingress -n ${GITEA_NAMESPACE} 2>/dev/null || true)

if [ -z "$INGRESS" ] || echo "$INGRESS" | grep -q "No resources found"; then
    print_warning "No ingress found for Gitea"
    echo "Gitea is not exposed via ingress"
else
    print_success "Ingress found:"
    kubectl get ingress -n ${GITEA_NAMESPACE}
    echo ""
    print_status "Ingress details:"
    kubectl describe ingress -n ${GITEA_NAMESPACE} 2>/dev/null | grep -A 10 "Name:\|Host:\|Address:" || true
fi

# Step 7: Check Gitea Logs
print_header "Step 7: Checking Gitea Pod Logs"
echo ""
GITEA_POD=$(kubectl get pods -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$GITEA_POD" ]; then
    print_status "Recent logs from pod: $GITEA_POD"
    echo ""
    kubectl logs -n ${GITEA_NAMESPACE} $GITEA_POD --tail=20 2>/dev/null || print_warning "Could not retrieve logs"
else
    print_warning "No Gitea pod found to check logs"
fi

# Step 8: Check Port Forwarding
print_header "Step 8: Port Forwarding Options"
echo ""
print_status "To access Gitea via port-forward, run:"
echo "  kubectl port-forward -n ${GITEA_NAMESPACE} svc/gitea-http 3000:3000"
echo ""
print_status "Then access Gitea at: http://localhost:3000"
echo ""

# Step 9: Check NodePort Access
print_header "Step 9: NodePort Access Information"
echo ""
NODEPORT_SVC=$(kubectl get svc -n ${GITEA_NAMESPACE} -o jsonpath='{.items[?(@.spec.type=="NodePort")].metadata.name}' 2>/dev/null || echo "")

if [ -n "$NODEPORT_SVC" ]; then
    NODEPORT=$(kubectl get svc $NODEPORT_SVC -n ${GITEA_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    if [ -n "$NODEPORT" ]; then
        print_success "Gitea is exposed via NodePort: $NODEPORT"
        echo ""
        print_status "Access Gitea at:"
        echo "  http://localhost:$NODEPORT"
        echo ""
        
        # Try to get public IP
        PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_IP")
        if [ "$PUBLIC_IP" != "YOUR_IP" ]; then
            echo "  http://${PUBLIC_IP}:$NODEPORT"
        else
            echo "  http://<YOUR_IP>:$NODEPORT"
        fi
        echo ""
        print_status "Credentials: admin / admin123"
    else
        print_warning "NodePort service found but port not detected"
    fi
else
    print_warning "No NodePort service found"
    echo ""
    print_status "To create NodePort service, run:"
    echo "  kubectl patch svc gitea-http -n ${GITEA_NAMESPACE} -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":3000,\"targetPort\":3000,\"nodePort\":30084}]}}'"
    echo ""
fi

# Step 10: Test Connectivity
print_header "Step 10: Testing Gitea Connectivity"
echo ""
if [ -n "$NODEPORT" ] && [ "$NODEPORT" != "" ]; then
    print_status "Testing connection to localhost:$NODEPORT..."
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:$NODEPORT --max-time 5 | grep -q "200\|302\|301"; then
        print_success "Gitea is accessible via NodePort!"
    else
        print_warning "Gitea is not responding via NodePort"
        print_status "This could mean:"
        echo "  1. Pod is still starting (wait a few minutes)"
        echo "  2. Pod is in error state (check logs above)"
        echo "  3. Service selector doesn't match pod labels"
    fi
else
    print_status "Testing connection to ClusterIP service..."
    CLUSTER_IP=$(kubectl get svc -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || echo "")
    if [ -n "$CLUSTER_IP" ] && [ "$CLUSTER_IP" != "" ]; then
        print_status "ClusterIP: $CLUSTER_IP"
        print_status "Use port-forward to access: kubectl port-forward -n ${GITEA_NAMESPACE} svc/gitea-http 3000:3000"
    fi
fi

# Step 11: Summary and Recommendations
print_header "Summary and Recommendations"
echo ""

# Check if everything is OK
ISSUES=0

# Check pods
if ! kubectl get pods -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea --no-headers 2>/dev/null | grep -q Running; then
    ISSUES=$((ISSUES + 1))
    print_error "Issue #$ISSUES: Gitea pods are not running"
fi

# Check services
if ! kubectl get svc -n ${GITEA_NAMESPACE} -l app.kubernetes.io/name=gitea 2>/dev/null | grep -q NodePort; then
    ISSUES=$((ISSUES + 1))
    print_warning "Issue #$ISSUES: Gitea service is not exposed via NodePort"
fi

if [ $ISSUES -eq 0 ]; then
    print_success "All checks passed! Gitea should be accessible."
    echo ""
    print_status "Quick Access:"
    if [ -n "$NODEPORT" ]; then
        echo "  http://localhost:$NODEPORT"
    fi
    echo "  Username: admin"
    echo "  Password: admin123"
else
    echo ""
    print_status "Troubleshooting Steps:"
    echo ""
    echo "1. If pods are not running, check logs:"
    echo "   kubectl logs -n ${GITEA_NAMESPACE} <pod-name>"
    echo ""
    echo "2. If service is not NodePort, patch it:"
    echo "   kubectl patch svc gitea-http -n ${GITEA_NAMESPACE} -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":3000,\"targetPort\":3000,\"nodePort\":30084}]}}'"
    echo ""
    echo "3. Restart Gitea deployment:"
    echo "   kubectl rollout restart deployment/gitea -n ${GITEA_NAMESPACE}"
    echo ""
    echo "4. Reinstall Gitea:"
    echo "   helm uninstall gitea -n ${GITEA_NAMESPACE}"
    echo "   ./bootstrap_cluster.sh"
    echo ""
fi

echo ""
print_status "Script completed!"
echo ""

