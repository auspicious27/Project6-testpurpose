# 🚀 Unified Production-Ready DevOps Pipeline

A comprehensive DevOps ecosystem integrating Flask web application with microservices architecture, featuring GitOps with ArgoCD, automated CI/CD, container security scanning, multi-environment deployment, blue-green strategy, and backup & disaster recovery.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Complete Setup Guide](#complete-setup-guide)
- [Access URLs](#access-urls)
- [Fixing Common Issues](#fixing-common-issues)
- [Testing Guide](#testing-guide)
- [Features](#features)
- [Troubleshooting](#troubleshooting)
- [Command Reference](#command-reference)
- [Contributing](#contributing)

## 🏗️ Overview

This project implements a complete production-ready DevOps pipeline with:

- **Flask Web Application**: Modern Python web app with Bootstrap UI
- **Microservices Architecture**: User Service and Product Service with REST APIs
- **GitOps Workflow**: ArgoCD for automated deployments
- **Git Server**: Self-hosted Gitea for PoC
- **Container Orchestration**: Kubernetes (kind)
- **Configuration Management**: Helm and Kustomize
- **Security Scanning**: Trivy CLI (CI) and Trivy Operator (in-cluster)
- **Backup & DR**: Velero with MinIO as S3 backend
- **Deployment Strategy**: Blue-Green Deployments

## 🏛️ Architecture

### System Components

```
┌─────────────────┐
│  GitHub Repo    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────┐
│  ArgoCD (GitOps)│────▶│  Kubernetes  │
└─────────────────┘     │   Cluster    │
         │               └──────┬───────┘
         │                      │
         ▼                      ▼
┌─────────────────┐     ┌──────────────────┐
│  Applications   │     │  Infrastructure  │
│  - Flask App    │     │  - NGINX Ingress │
│  - User Service │     │  - MinIO S3      │
│  - Product Svc  │     │  - Trivy Operator│
└─────────────────┘     └──────────────────┘
```

## 📋 Prerequisites

### System Requirements

- **OS**: Ubuntu 20.04+, Debian 11+, Amazon Linux 2, or RHEL 8+
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: Minimum 20GB free space
- **CPU**: 2+ cores recommended
- **Network**: Internet access for downloading images and packages

### Required Permissions

- Root or sudo access for installing packages
- Docker daemon access (user in docker group)
- Ability to modify `/etc/hosts` file

## 🚀 Quick Start

### One-Command Setup (Recommended)

```bash
# Clone the repository
git clone https://github.com/auspicious27/Project6-testpurpose.git
cd Project6-testpurpose

# Run complete setup (this will take 10-15 minutes)
./setup_prereqs.sh && ./bootstrap_cluster.sh && ./deploy_pipeline.sh
```

### Verify Installation

```bash
# Check cluster status
kubectl get nodes

# Check all components
./check_env.sh
```

## 📖 Complete Setup Guide

### Step 1: Install Prerequisites

```bash
# Make script executable
chmod +x setup_prereqs.sh

# Run prerequisites installation
./setup_prereqs.sh
```

**This installs:**
- Docker
- kubectl
- kind (Kubernetes in Docker)
- Helm
- ArgoCD CLI
- Trivy
- Velero
- Kustomize
- MkDocs

### Step 2: Bootstrap Kubernetes Cluster

```bash
# Make script executable
chmod +x bootstrap_cluster.sh

# Bootstrap cluster with all infrastructure components
./bootstrap_cluster.sh
```

**This creates:**
- Kind Kubernetes cluster
- NGINX Ingress Controller
- Gitea (Git server)
- ArgoCD (GitOps)
- MinIO (Object storage)
- Trivy Operator (Security scanning)
- Velero (Backup/Restore)
- Namespaces: dev, staging, production

**Expected time:** 5-10 minutes

### Step 3: Deploy Applications

```bash
# Make script executable
chmod +x deploy_pipeline.sh

# Build images and deploy applications
./deploy_pipeline.sh
```

**This does:**
- Builds Docker images for Flask app and microservices
- Loads images into Kubernetes cluster
- Configures ArgoCD applications
- Syncs applications to dev, staging, production
- Creates ingress for Flask app
- Runs security scans
- Configures services for external access (EC2)

**Expected time:** 5-10 minutes

### Step 4: Fix Any Issues (If Needed)

If you encounter any issues, run the fix scripts:

```bash
# Fix all deployment issues
./fix_deployment.sh

# Fix Flask application specifically
./fix_flask_app.sh

# Sync ArgoCD applications manually
./sync_argocd_apps.sh
```

### Step 5: Verify Everything Works

```bash
# Run comprehensive health checks
./check_env.sh

# Check pods are running
kubectl get pods -n dev
kubectl get pods -n argocd
kubectl get pods -n gitea
kubectl get pods -n minio

# Check ArgoCD applications
kubectl get applications -n argocd
```

## 🌐 Access URLs

### Local/Development Access

After deployment, the script will display URLs. For local access:

**Flask App:**
```bash
# Add to /etc/hosts (if not already added)
echo "127.0.0.1 flask-app.local" | sudo tee -a /etc/hosts

# Get ingress port
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

# Access via browser or curl
curl -H 'Host: flask-app.local' http://127.0.0.1:$INGRESS_PORT/api/health
```

**ArgoCD:**
```bash
# Get ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port forward
kubectl port-forward -n argocd svc/argocd-server 8081:443

# Access: https://localhost:8081 (username: admin)
```

**Gitea:**
```bash
# Port forward
kubectl port-forward -n gitea svc/gitea-http 3000:3000

# Access: http://localhost:3000 (username: admin, password: admin123)
```

**MinIO:**
```bash
# Port forward
kubectl port-forward -n minio svc/minio 9000:9000

# Access: http://localhost:9000 (username: minioadmin, password: minioadmin123)
```

### AWS EC2 Deployment

If running on EC2, the `deploy_pipeline.sh` script automatically detects EC2 and configures services for external access.

**Get Your URLs:**
```bash
# Get EC2 Public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Get service ports
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
ARGOCD_PORT=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

# Flask App URL
echo "Flask App: http://$PUBLIC_IP:$INGRESS_PORT (with Host: flask-app.local)"

# ArgoCD URL
echo "ArgoCD: https://$PUBLIC_IP:$ARGOCD_PORT"
```

**Configure AWS Security Group:**

Add inbound rules for these ports:
- **Ingress Controller**: Port from `INGRESS_PORT` (usually 30000-32767)
- **ArgoCD**: Port from `ARGOCD_PORT` (usually 30000-32767)
- **Gitea**: Port from Gitea service NodePort
- **MinIO**: Port from MinIO service NodePort

**AWS CLI Commands:**
```bash
# Get Security Group ID
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d ' ' -f2)
SG_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)

# Add rules (replace ports with actual values)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $INGRESS_PORT --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $ARGOCD_PORT --cidr 0.0.0.0/0
```

## 🔧 Fixing Common Issues

### Issue: Applications Not Deploying

```bash
# Run comprehensive fix
./fix_deployment.sh

# Or fix Flask app specifically
./fix_flask_app.sh
```

### Issue: ArgoCD Applications Not Syncing

```bash
# Sync manually
./sync_argocd_apps.sh

# Or manually trigger sync
kubectl patch application devops-pipeline-dev -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Issue: Flask App Not Accessible

```bash
# Run Flask-specific fix
./fix_flask_app.sh

# Check pod status
kubectl get pods -n dev -l app=flask-app

# Check pod logs
kubectl logs -n dev -l app=flask-app --tail=50

# Check service
kubectl get svc flask-app-service -n dev

# Check ingress
kubectl get ingress flask-app-ingress -n dev
```

### Issue: MinIO Installation Failed

```bash
# Reinstall MinIO
helm uninstall minio -n minio
./fix_deployment.sh
```

### Issue: Namespaces Missing

```bash
# Create missing namespaces
kubectl create namespace dev
kubectl create namespace staging
kubectl create namespace production
```

## 🧪 Testing Guide

### Quick Health Check

```bash
# Run comprehensive health checks
./check_env.sh
```

### Test Flask Application

```bash
# Get ingress port
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

# Test health endpoint
curl -H 'Host: flask-app.local' http://127.0.0.1:$INGRESS_PORT/api/health

# Test home page
curl -H 'Host: flask-app.local' http://127.0.0.1:$INGRESS_PORT/
```

### Test Blue-Green Deployment

```bash
# Run blue-green deployment demo
./switch_blue_green.sh demo
```

### Test Backup and Restore

```bash
# Run backup/restore demo
./backup_restore_demo.sh demo
```

### Test Security Scanning

```bash
# Scan Flask app image
trivy image flask-app:latest

# Check Trivy Operator reports
kubectl get vulnerabilityreports -n dev
kubectl get configauditreports -n dev
```

## ✨ Features

### 🔄 GitOps Workflow
- ArgoCD for automated deployments
- Multi-environment support (dev, staging, production)
- Automated sync and self-healing

### 🔒 Security Integration
- Trivy for container vulnerability scanning
- Security reports in Kubernetes
- RBAC configurations

### 🔄 Blue-Green Deployments
- Zero-downtime deployments
- Easy rollback capability
- Traffic switching script

### 💾 Backup & Recovery
- Velero for backup/restore
- MinIO as S3-compatible storage
- Scheduled backups support

### 🌍 Multi-Environment Support
- Separate configurations for dev, staging, production
- Kustomize for environment-specific overlays
- Environment-specific resource limits

## 🚨 Troubleshooting

### Cluster Not Starting

```bash
# Check Docker
systemctl status docker
sudo systemctl restart docker

# Delete and recreate cluster
kind delete cluster --name devops-pipeline
./bootstrap_cluster.sh
```

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n dev

# Check pod events
kubectl describe pod <pod-name> -n dev

# Check pod logs
kubectl logs <pod-name> -n dev
```

### Services Not Accessible

```bash
# Check service endpoints
kubectl get endpoints -n dev

# Check ingress
kubectl get ingress -n dev
kubectl describe ingress flask-app-ingress -n dev

# Check ingress controller
kubectl get pods -n ingress-nginx
```

### ArgoCD Not Syncing

```bash
# Check ArgoCD application status
kubectl get applications -n argocd
kubectl describe application devops-pipeline-dev -n argocd

# Manually sync
./sync_argocd_apps.sh
```

### Disk Space Issues

```bash
# Clean Docker
docker system prune -a --volumes -f
docker builder prune -a -f

# Clean Kubernetes
kind delete cluster --name devops-pipeline
```

## 📚 Command Reference

### Setup Commands

```bash
# Install prerequisites
./setup_prereqs.sh

# Bootstrap cluster
./bootstrap_cluster.sh

# Deploy applications
./deploy_pipeline.sh

# Check health
./check_env.sh
```

### Fix Commands

```bash
# Fix all issues
./fix_deployment.sh

# Fix Flask app
./fix_flask_app.sh

# Sync ArgoCD
./sync_argocd_apps.sh
```

### Get Information

```bash
# Get EC2 Public IP
curl -s http://169.254.169.254/latest/meta-data/public-ipv4

# Get service ports
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'
kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}'

# Get ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### Common Operations

```bash
# Port forwarding
kubectl port-forward -n dev svc/flask-app-service 8080:80
kubectl port-forward -n argocd svc/argocd-server 8081:443
kubectl port-forward -n gitea svc/gitea-http 3000:3000
kubectl port-forward -n minio svc/minio 9000:9000

# View logs
kubectl logs -n dev -l app=flask-app
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Restart deployment
kubectl rollout restart deployment/flask-app -n dev

# Scale deployment
kubectl scale deployment flask-app --replicas=3 -n dev
```

## 🤝 Contributing

### Development Setup

```bash
# Fork and clone
git clone https://github.com/auspicious27/Project6-testpurpose.git
cd Project6-testpurpose

# Create feature branch
git checkout -b feature/new-feature

# Make changes and test
./check_env.sh

# Commit and push
git commit -m "feat: add new feature"
git push origin feature/new-feature
```

### Testing

```bash
# Run health checks
./check_env.sh

# Test blue-green deployment
./switch_blue_green.sh demo

# Test backup/restore
./backup_restore_demo.sh demo
```

## 📄 License

This project is licensed under the MIT License.

## 🆘 Support

### Getting Help

- **Documentation**: Check the `/docs` directory
- **Troubleshooting**: See [Troubleshooting](#troubleshooting) section
- **Health Checks**: Run `./check_env.sh`
- **Issues**: Create an issue in the GitHub repository

### Quick Help Commands

```bash
# Check everything
./check_env.sh

# Fix issues
./fix_deployment.sh

# Get status
kubectl get all -A
```

## 🎉 Success!

**Congratulations! You now have a complete, production-ready DevOps pipeline.**

### Next Steps

1. **Customize**: Modify configurations for your needs
2. **Scale**: Add more applications and environments
3. **Monitor**: Set up additional monitoring and alerting
4. **Secure**: Implement additional security measures for production

---

**Made with ❤️ for the DevOps community**
