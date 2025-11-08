#!/bin/bash

# sync_argocd_apps.sh - Manually sync ArgoCD applications
# This script helps sync ArgoCD applications if they don't sync automatically

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

print_status "Syncing ArgoCD Applications..."

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi

# Check if ArgoCD namespace exists
if ! kubectl get namespace argocd &>/dev/null; then
    print_error "ArgoCD namespace not found. Please run bootstrap_cluster.sh first."
    exit 1
fi

# List of applications to sync
APPS=("devops-pipeline-dev" "devops-pipeline-staging" "devops-pipeline-prod" "devops-pipeline-blue-green" "devops-pipeline-apps")

# Enable automated sync for all applications
print_status "Enabling automated sync for applications..."
for app in "${APPS[@]}"; do
    if kubectl get application "$app" -n argocd &>/dev/null; then
        print_status "Enabling automated sync for $app..."
        kubectl patch application "$app" -n argocd --type merge --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || \
        print_warning "Could not update sync policy for $app"
    fi
done

# Wait a bit
sleep 5

# Trigger refresh and sync for each application
print_status "Triggering refresh and sync for applications..."
for app in "${APPS[@]}"; do
    if kubectl get application "$app" -n argocd &>/dev/null; then
        print_status "Syncing $app..."
        
        # Method 1: Add refresh annotation
        kubectl patch application "$app" -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || true
        
        # Method 2: Trigger sync operation
        kubectl patch application "$app" -n argocd --type json -p='[{"op": "add", "path": "/operation", "value": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}]' 2>/dev/null || \
        kubectl patch application "$app" -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null || \
        print_warning "Could not trigger sync for $app"
    else
        print_warning "Application $app not found"
    fi
done

# Wait for sync to complete
print_status "Waiting for applications to sync (this may take a few minutes)..."
sleep 10

# Check sync status
print_status "Checking sync status..."
for app in "${APPS[@]}"; do
    if kubectl get application "$app" -n argocd &>/dev/null; then
        SYNC_STATUS=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        HEALTH_STATUS=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        echo "  $app: Sync=$SYNC_STATUS, Health=$HEALTH_STATUS"
    fi
done

print_success "Sync operations completed!"
print_status "Check application status with: kubectl get applications -n argocd"
print_status "Check pods with: kubectl get pods -n dev"

