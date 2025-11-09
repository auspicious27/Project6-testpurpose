# DevOps Pipeline Scripts Guide

## 📋 Main Scripts (Run in Order)

### 1. setup_prereqs.sh
**Purpose**: Install all required tools and dependencies

**What it does**:
- Installs Docker, kubectl, kind, Helm
- Installs ArgoCD CLI, Trivy, Velero, Kustomize
- Installs MkDocs for documentation
- Configures system for Kubernetes

**Run once**: Only needed on fresh systems

```bash
./setup_prereqs.sh
```

---

### 2. bootstrap_cluster.sh
**Purpose**: Create Kubernetes cluster and install infrastructure

**What it does**:
- Creates kind cluster with proper configuration
- Installs NGINX Ingress Controller
- Installs Gitea (Git server) with NodePort on 30084
- Installs ArgoCD (GitOps) with NodePort on 30083
- Installs MinIO (S3 storage) with NodePort on 30085
- Installs Trivy Operator (security scanning)
- Installs Velero (backup/restore)
- Creates local Docker registry on port 30500
- **Configures containerd for HTTP registry** (fixes ImagePullBackOff)
- **Creates Gitea NodePort service** (fixes Gitea accessibility)
- Sets up GitOps repository

**Run time**: 10-15 minutes

```bash
./bootstrap_cluster.sh
```

**Key fixes integrated**:
- ✅ Registry HTTP configuration (no more ImagePullBackOff)
- ✅ Gitea NodePort service (accessible externally)
- ✅ Proper containerd configuration for insecure registry

---

### 3. deploy_pipeline.sh
**Purpose**: Build Docker images and deploy applications

**What it does**:
- Builds Docker images for Flask app and microservices
- Pushes images to local registry (or loads to kind if registry unavailable)
- Updates deployment manifests with correct registry IPs
- Deploys applications to dev namespace
- Exposes services via NodePort:
  - Flask App: 30080
  - User Service: 30081
  - Product Service: 30082
- Triggers ArgoCD sync
- Runs security scans with Trivy

**Run time**: 5-10 minutes

```bash
./deploy_pipeline.sh
```

---

### 4. check_env.sh
**Purpose**: Comprehensive health check and URL verification

**What it does**:
- Checks all required tools are installed
- Verifies cluster is running
- Checks all namespaces and pods
- Tests ArgoCD, Gitea, MinIO, Trivy, Velero
- **Tests all application URLs** (with HTTP status codes)
- Shows credentials for all services
- Provides AWS Security Group instructions
- Generates health report
- Displays troubleshooting tips

**Run anytime**: To verify system health

```bash
./check_env.sh
```

**Output includes**:
- ✅ URL accessibility status for all services
- ✅ Credentials (Gitea, MinIO, ArgoCD)
- ✅ AWS Security Group configuration guide
- ✅ Troubleshooting tips

---

### 5. check_urls.sh (Optional)
**Purpose**: Quick URL checker (simplified version of check_env.sh)

**What it does**:
- Tests all service URLs
- Shows HTTP status codes
- Displays credentials
- Minimal output for quick checks

**Run anytime**: For quick URL verification

```bash
./check_urls.sh
```

---

## 🔧 What Was Consolidated

All functionality from these helper scripts is now integrated into the main 4 scripts:

### Removed Scripts (functionality integrated):
- ❌ `fix_registry.sh` → Now in `bootstrap_cluster.sh`
- ❌ `fix_gitea.sh` → Now in `bootstrap_cluster.sh`
- ❌ `fix_gitea_nodeport.sh` → Now in `bootstrap_cluster.sh`
- ❌ `diagnose_gitea.sh` → Now in `check_env.sh`
- ❌ `open_aws_ports.sh` → Instructions in `check_env.sh`
- ❌ `AWS_SECURITY_GROUP_SETUP.md` → Instructions in `check_env.sh`

---

## 🚀 Complete Workflow

```bash
# Fresh installation
./setup_prereqs.sh          # Install tools (once)
./bootstrap_cluster.sh      # Create cluster (10-15 min)
./deploy_pipeline.sh        # Deploy apps (5-10 min)
./check_env.sh              # Verify everything

# Quick URL check
./check_urls.sh

# If you need to reset
kind delete cluster --name devops-pipeline
./bootstrap_cluster.sh
./deploy_pipeline.sh
```

---

## 🌐 Access URLs

After running all scripts, services are accessible at:

| Service | URL | Port | Credentials |
|---------|-----|------|-------------|
| Flask App | http://YOUR_IP:30080 | 30080 | None |
| User Service | http://YOUR_IP:30081/api/users | 30081 | None |
| Product Service | http://YOUR_IP:30082/api/products | 30082 | None |
| ArgoCD | http://YOUR_IP:30083 | 30083 | admin / (see below) |
| Gitea | http://YOUR_IP:30084 | 30084 | admin / admin123 |
| MinIO | http://YOUR_IP:30085 | 30085 | minioadmin / minioadmin123 |
| Docker Registry | http://YOUR_IP:30500/v2/ | 30500 | None |

**Get ArgoCD password**:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## ⚠️ AWS Security Group

**IMPORTANT**: Open these ports in your AWS Security Group:

1. Go to: **AWS Console → EC2 → Security Groups**
2. Select your instance's security group
3. **Edit Inbound Rules** → Add these Custom TCP rules:
   - Port Range: **30080-30085, 30500**
   - Source: **0.0.0.0/0** (or your IP for security)
4. **Save rules**

Without this, services will show as UNREACHABLE from external browsers.

---

## 🐛 Troubleshooting

### ImagePullBackOff errors?
✅ **Fixed automatically** in `bootstrap_cluster.sh`
- Containerd is configured for HTTP registry
- No manual intervention needed

### Gitea unreachable?
✅ **Fixed automatically** in `bootstrap_cluster.sh`
- NodePort service created on port 30084
- No manual intervention needed

### Services unreachable from browser?
- Check AWS Security Group ports (see above)
- Run `./check_env.sh` to see detailed status
- Wait 2-3 minutes for services to fully start

### Pods not starting?
```bash
kubectl get pods -n dev
kubectl describe pod -n dev <pod-name>
kubectl logs -n dev <pod-name>
```

---

## 📊 What Each Script Fixes

| Issue | Fixed By | How |
|-------|----------|-----|
| ImagePullBackOff | bootstrap_cluster.sh | Configures containerd for HTTP registry |
| Gitea unreachable | bootstrap_cluster.sh | Creates NodePort service on 30084 |
| Registry not accessible | bootstrap_cluster.sh | Configures insecure registry with IP |
| Services unreachable | deploy_pipeline.sh | Exposes all services as NodePort |
| Unknown service status | check_env.sh | Tests all URLs and shows status |
| Missing credentials | check_env.sh | Displays all credentials |
| AWS ports closed | check_env.sh | Shows configuration instructions |

---

## ✅ Success Criteria

After running all scripts, you should see:

```
Flask App            http://YOUR_IP:30080 ... [✓] OK (HTTP 200)
User Service         http://YOUR_IP:30081/api/users ... [✓] OK (HTTP 200)
Product Service      http://YOUR_IP:30082/api/products ... [✓] OK (HTTP 200)
ArgoCD               http://YOUR_IP:30083 ... [✓] OK (HTTP 307)
Gitea                http://YOUR_IP:30084 ... [✓] OK (HTTP 200)
MinIO                http://YOUR_IP:30085 ... [✓] OK - Needs Auth (HTTP 403)
Docker Registry      http://YOUR_IP:30500/v2/ ... [✓] OK (HTTP 200)
```

All services accessible and working! 🎉
