# 🚀 Quick Fix Commands - EC2 Par Run Karne Ke Liye

## Step 1: Latest Code Pull Karein

```bash
git pull origin main
```

## Step 2: Resource Constraints Fix (MOST IMPORTANT)

```bash
./fix_resource_constraints.sh
```

## Step 3: Flask App Fix

```bash
./fix_flask_app.sh
```

## Step 4: ArgoCD Sync

```bash
./sync_argocd_apps.sh
```

## Step 5: Status Check

```bash
kubectl get pods -n dev
```

## Step 6: URL Test (Jab Pods Running Ho Jayen)

```bash
# Get ingress port
INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')

# Get Public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Test
curl -H 'Host: flask-app.local' http://$PUBLIC_IP:$INGRESS_PORT/api/health
```

---

## 🎯 ONE-LINER (Sab Kuch Ek Saath)

```bash
git pull origin main && ./fix_resource_constraints.sh && sleep 30 && ./fix_flask_app.sh && kubectl get pods -n dev
```

---

## 📋 Agar Koi Issue Aaye To

### Pods Still Pending?
```bash
# Manual fix
kubectl scale deployment flask-app -n dev --replicas=1
kubectl patch deployment flask-app -n dev --type json -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "32Mi"}, {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "25m"}]'
kubectl delete pods -n dev -l app=flask-app --grace-period=0 --force
```

### Image Pull Error?
```bash
# Rebuild and load image
cd apps/flask-app
docker build -t flask-app:latest .
kind load docker-image flask-app:latest --name devops-pipeline
cd ../..
kubectl delete pods -n dev -l app=flask-app --grace-period=0 --force
```

### URL Not Working?
```bash
# Check service
kubectl get svc flask-app-service -n dev

# Check ingress
kubectl get ingress flask-app-ingress -n dev

# Port forward (alternative)
kubectl port-forward -n dev svc/flask-app-service 8080:80
# Then access: http://localhost:8080
```

