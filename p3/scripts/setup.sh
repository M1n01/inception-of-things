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

# Create namespaces
echo "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
echo "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

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
echo "   k3d cluster delete $CLUSTER_NAME  # To cleanup"
echo ""
echo "Note: ArgoCD UI uses self-signed certificates, so you'll see a security warning in your browser"
echo "To stop port forwarding: kill \$(cat /tmp/argocd-portforward.pid)"
