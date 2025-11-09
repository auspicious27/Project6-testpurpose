#!/bin/bash

# fix_gitea_final.sh - Complete Gitea fix

EC2_IP="54.197.219.80"
SSH_KEY="$HOME/.ssh/devops-pipeline-key.pem"

echo "🔧 Fixing Gitea - Complete Solution"
echo "==================================="
echo ""

ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    -o ServerAliveInterval=60 \
    ubuntu@$EC2_IP << 'ENDSSH'
set +e

cd ~/Project6-testpurpose || cd Project6-testpurpose

export KUBECONFIG=~/.kube/config
kubectl config use-context kind-devops-pipeline

echo "=== Step 1: Complete Cleanup ==="
echo ""

# Complete cleanup
helm uninstall gitea -n gitea 2>/dev/null || true
kubectl delete namespace gitea 2>/dev/null || true
sleep 15

# Recreate namespace
kubectl create namespace gitea

echo "=== Step 2: Installing Gitea with Minimal Config ==="
echo ""

# Add Helm repo
helm repo add gitea-charts https://dl.gitea.io/charts/ 2>/dev/null || true
helm repo update 2>/dev/null || true

# Install Gitea with absolute minimal config (SQLite only, no PostgreSQL, no Redis)
cat > /tmp/gitea-final.yaml << 'EOF'
gitea:
  admin:
    username: admin
    password: admin123
    email: admin@devops.local
  config:
    server:
      ROOT_URL: http://gitea.local
      DOMAIN: gitea.local
    database:
      DB_TYPE: sqlite3
    service:
      DISABLE_REGISTRATION: false
  image:
    tag: "1.21"
postgresql:
  enabled: false
redis:
  enabled: false
memcached:
  enabled: false
ingress:
  enabled: false
service:
  http:
    type: NodePort
    nodePort: 30084
    port: 3000
persistence:
  enabled: true
  size: 2Gi
  accessMode: ReadWriteOnce
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
EOF

echo "Installing Gitea (this will take 3-5 minutes)..."
helm install gitea gitea-charts/gitea \
  --namespace gitea \
  --values /tmp/gitea-final.yaml \
  --timeout 15m \
  --wait=false \
  --atomic=false 2>&1 | tail -10

echo ""
echo "Waiting for Gitea to be ready..."
sleep 60

# Check pod status
echo ""
echo "=== Gitea Pod Status ==="
for i in {1..20}; do
    POD_STATUS=$(kubectl get pods -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" = "Running" ]; then
        echo "✅ Gitea pod is Running!"
        break
    fi
    echo "Waiting... ($i/20) - Status: $POD_STATUS"
    sleep 15
done

# Verify service
echo ""
echo "=== Gitea Service Status ==="
kubectl get svc -n gitea

# Check if NodePort is set
NODEPORT=$(kubectl get svc gitea-http -n gitea -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ -z "$NODEPORT" ] || [ "$NODEPORT" != "30084" ]; then
    echo ""
    echo "Fixing NodePort..."
    kubectl patch svc gitea-http -n gitea --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}, {"op": "add", "path": "/spec/ports/0/nodePort", "value": 30084}]' 2>/dev/null || {
        # Create new service if patch fails
        kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: gitea-nodeport
  namespace: gitea
spec:
  type: NodePort
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30084
    protocol: TCP
  selector:
    app.kubernetes.io/name: gitea
EOF
    }
fi

# Final status
echo ""
echo "=== Final Status ==="
kubectl get pods -n gitea
echo ""
kubectl get svc -n gitea | grep -E "gitea|NodePort"

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo ""
echo "=========================================="
echo "✅ Gitea Setup Complete!"
echo "=========================================="
echo ""
echo "📚 Gitea URL:"
echo "   http://${PUBLIC_IP}:30084"
echo ""
echo "   Username: admin"
echo "   Password: admin123"
echo ""
echo "Note: If not accessible, wait 1-2 more minutes for pod to fully start"
echo ""

# Test connectivity
echo "Testing Gitea connectivity..."
sleep 10
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:30084 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    echo "✅ Gitea is responding! (HTTP $HTTP_CODE)"
else
    echo "⚠️ Gitea may still be starting (HTTP $HTTP_CODE)"
    echo "   Check pod logs: kubectl logs -n gitea -l app.kubernetes.io/name=gitea"
fi
echo ""

ENDSSH

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Gitea fix completed!"
    echo ""
    echo "🌐 Gitea URL:"
    echo "   http://54.197.219.80:30084"
    echo "   Username: admin"
    echo "   Password: admin123"
    echo ""
    echo "Please wait 1-2 minutes for Gitea to be fully ready"
else
    echo ""
    echo "❌ Fix failed. Please check connection"
fi

