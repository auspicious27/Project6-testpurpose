#!/bin/bash

# fix_registry.sh - Fix registry configuration for HTTP access
# This script configures containerd to allow insecure HTTP registry access

set +e

echo "🔧 Fixing Docker Registry Configuration..."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CLUSTER_NAME="devops-pipeline"

# Get registry IP
REGISTRY_IP=$(kubectl get svc docker-registry -n registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -z "$REGISTRY_IP" ]; then
    print_error "Registry service not found!"
    exit 1
fi

print_status "Registry IP: ${REGISTRY_IP}:5000"

# Configure containerd for insecure registry
print_status "Configuring containerd for insecure registry..."

# Method 1: Using containerd config.toml
docker exec ${CLUSTER_NAME}-control-plane bash -c "cat > /etc/containerd/config.toml << 'EOFCONFIG'
version = 2

[plugins]
  [plugins.\"io.containerd.grpc.v1.cri\"]
    [plugins.\"io.containerd.grpc.v1.cri\".registry]
      [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors]
        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${REGISTRY_IP}:5000\"]
          endpoint = [\"http://${REGISTRY_IP}:5000\"]
      [plugins.\"io.containerd.grpc.v1.cri\".registry.configs]
        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${REGISTRY_IP}:5000\"]
          [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${REGISTRY_IP}:5000\".tls]
            insecure_skip_verify = true
        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${REGISTRY_IP}:5000\".http]
          insecure = true
EOFCONFIG
"

# Method 2: Using hosts.toml (newer containerd versions)
docker exec ${CLUSTER_NAME}-control-plane bash -c "mkdir -p /etc/containerd/certs.d/${REGISTRY_IP}:5000"
docker exec ${CLUSTER_NAME}-control-plane bash -c "cat > /etc/containerd/certs.d/${REGISTRY_IP}:5000/hosts.toml << 'EOFHOSTS'
server = \"http://${REGISTRY_IP}:5000\"

[host.\"http://${REGISTRY_IP}:5000\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
EOFHOSTS
"

# Also configure for docker-registry.registry service name
docker exec ${CLUSTER_NAME}-control-plane bash -c "mkdir -p /etc/containerd/certs.d/docker-registry.registry:5000"
docker exec ${CLUSTER_NAME}-control-plane bash -c "cat > /etc/containerd/certs.d/docker-registry.registry:5000/hosts.toml << 'EOFHOSTS2'
server = \"http://docker-registry.registry:5000\"

[host.\"http://docker-registry.registry:5000\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
EOFHOSTS2
"

print_success "Containerd configuration updated"

# Restart containerd
print_status "Restarting containerd..."
docker exec ${CLUSTER_NAME}-control-plane systemctl restart containerd
sleep 5

print_success "Containerd restarted"

# Verify containerd is running
if docker exec ${CLUSTER_NAME}-control-plane systemctl is-active containerd | grep -q active; then
    print_success "Containerd is running"
else
    print_error "Containerd failed to start!"
    exit 1
fi

# Delete existing pods to force re-pull with new config
print_status "Restarting pods to apply new configuration..."
kubectl delete pods -n dev -l app=flask-app --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n dev -l app=user-service --force --grace-period=0 2>/dev/null || true
kubectl delete pods -n dev -l app=product-service --force --grace-period=0 2>/dev/null || true

print_status "Waiting for pods to restart..."
sleep 10

# Wait for new pods to be ready
for app in flask-app user-service product-service; do
    print_status "Waiting for ${app}..."
    kubectl wait --for=condition=ready --timeout=300s pod -l app=${app} -n dev 2>/dev/null || \
        print_warning "${app} may still be starting"
done

print_success "Registry configuration fixed!"
echo ""
echo "Check pod status with: kubectl get pods -n dev"
echo "Check events with: kubectl get events -n dev --sort-by='.lastTimestamp'"
