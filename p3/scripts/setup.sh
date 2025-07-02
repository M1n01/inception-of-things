#!/bin/bash

set -e

# Install Docker Desktop if not installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker Desktop..."
    brew install --cask docker
    echo "Please start Docker Desktop manually and wait for it to be ready"
    echo "Then rerun this script"
    exit 1
else
    echo "Docker found!"
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "Docker is not running. Please start Docker Desktop and try again"
    exit 1
fi
echo "Docker is running!"

# Install kubectl if not installed
if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    brew install kubectl
else
    echo "kubectl found!"
fi

# Install K3d if not installed
if ! command -v k3d &> /dev/null; then
    echo "Installing K3d..."
    brew install k3d
else
    echo "K3d found!"
fi

# Create K3d cluster
CLUSTER_NAME="iot-cluster"
echo "Creating K3d cluster: $CLUSTER_NAME"

# Delete existing cluster if it exists
if k3d cluster list | grep -q $CLUSTER_NAME; then
    echo "Removing existing cluster..."
    k3d cluster delete $CLUSTER_NAME
fi

# Create K3d cluster
k3d cluster create $CLUSTER_NAME --port 8080:80@loadbalancer --port 8443:443@loadbalancer --port "30000-30010:30000-30010@server:0"

echo "K3d cluster created successfully!"

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../configs"

# Check if confs directory exists
if [ ! -d "$CONFS_DIR" ]; then
    echo "confs directory not found at $CONFS_DIR"
    exit 1
fi

# Create namespaces
echo "Creating namespaces..."
if [ -f "$CONFS_DIR/namespace.yaml" ]; then
    kubectl apply -f "$CONFS_DIR/namespace.yaml"
else
    # Fallback to manual creation
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
fi

# Install ArgoCD
echo "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Apply application manifests
echo "Deploying Wil application..."
if [ -f "$CONFS_DIR/deployment.yaml" ]; then
    kubectl apply -f "$CONFS_DIR/deployment.yaml"
else
    echo "deployment.yaml not found, skipping application deployment"
fi

if [ -f "$CONFS_DIR/service.yaml" ]; then
    kubectl apply -f "$CONFS_DIR/service.yaml"
else
    echo "service.yaml not found, skipping service creation"
fi

# Wait for application to be ready
echo "Waiting for application to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/wil-playground -n dev 2>/dev/null || echo "Application deployment may still be starting"

# Apply ArgoCD Application configuration
echo "Setting up ArgoCD Application..."
if [ -f "$CONFS_DIR/application.yaml" ]; then
    # Wait a bit more for ArgoCD to be fully ready
    sleep 10
    kubectl apply -f "$CONFS_DIR/application.yaml"
    echo "ArgoCD Application configured"
else
    echo "application.yaml not found, ArgoCD Application not configured"
    echo "You'll need to configure ArgoCD manually via the UI"
fi

# Get ArgoCD initial admin password
echo "Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Port forward ArgoCD (run in background)
echo "Setting up port forwarding for ArgoCD..."
kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
PORTFORWARD_PID=$!

# Save the PID for cleanup
echo $PORTFORWARD_PID > /tmp/argocd-portforward.pid

echo ""
echo "Setup completed successfully!"
echo ""
echo "Access Information:"
echo "   ArgoCD UI: https://localhost:8080"
echo "   Username: admin"
echo "   Password: $ARGOCD_PASSWORD"
echo ""
echo "Useful commands:"
echo "   kubectl get pods -n argocd"
echo "   kubectl get pods -n dev"
echo "   kubectl get svc -n dev"
echo "   kubectl logs -n dev deployment/wil-playground"
echo "   k3d cluster delete $CLUSTER_NAME  # To cleanup"
echo ""
echo "Application Access:"
echo "   kubectl port-forward svc/wil-playground -n dev 8888:8888"
echo "   Then access: http://localhost:8888"
echo ""
echo "Note: ArgoCD UI uses self-signed certificates, so you'll see a security warning in your browser"
echo "To stop port forwarding: kill \$(cat /tmp/argocd-portforward.pid)"
