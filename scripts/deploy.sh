#!/bin/bash
# ============================================================================
# deploy.sh — End-to-End Local vLLM Deployment on Minikube/Kind
# ============================================================================
# Prerequisites:
#   - minikube or kind
#   - docker
#   - kubectl
#   - helm
#   - HuggingFace token in HF_TOKEN env var
#
# Usage:
#   export HF_TOKEN="hf_xxxxxxxxxxxxx"
#   ./scripts/deploy.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="vllm"
IMAGE_NAME="vllm-opt125m:cpu"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    for cmd in docker kubectl helm; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "$cmd is not installed. Please install it first."
            exit 1
        fi
    done

    if [ -z "${HF_TOKEN:-}" ]; then
        log_warn "HF_TOKEN is not set. The model may fail to download from HuggingFace."
        log_warn "Set it with: export HF_TOKEN=\"hf_xxxxxxxxxxxxx\""
        log_warn "Get a token at: https://huggingface.co/settings/tokens"
    fi

    log_info "All prerequisites satisfied."
}

start_cluster() {
    local CLUSTER_TOOL=""

    if command -v minikube &>/dev/null; then
        CLUSTER_TOOL="minikube"
    elif command -v kind &>/dev/null; then
        CLUSTER_TOOL="kind"
    else
        log_error "Neither minikube nor kind found. Please install one."
        exit 1
    fi

    log_info "Using cluster tool: $CLUSTER_TOOL"

    if [ "$CLUSTER_TOOL" = "minikube" ]; then
        if minikube status | grep -q "Running"; then
            log_info "Minikube is already running."
        else
            log_info "Starting Minikube..."
            minikube start \
                --cpus=2 \
                --memory=2048 \
                --driver=docker \
                --kubernetes-version=v1.31.0
        fi
    else
        if kind get clusters | grep -q "vllm"; then
            log_info "Kind cluster 'vllm' already exists."
        else
            log_info "Creating Kind cluster..."
            cat <<EOF | kind create cluster --name vllm --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "nvidia.com/gpu=true"
EOF
        fi
    fi
}

build_image() {
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        log_info "Docker image $IMAGE_NAME already exists — skipping build."
    else
        log_info "Building Docker image: $IMAGE_NAME"
        docker build \
            --target cpu \
            -t "$IMAGE_NAME" \
            -f "$PROJECT_DIR/docker/Dockerfile" \
            "$PROJECT_DIR"
        log_info "Docker image built successfully."
    fi
}

load_image() {
    local CLUSTER_TOOL=""

    if command -v minikube &>/dev/null && minikube status | grep -q "Running"; then
        if minikube image list 2>/dev/null | grep -q "$IMAGE_NAME"; then
            log_info "Image $IMAGE_NAME already loaded in Minikube — skipping."
        else
            log_info "Loading image into Minikube..."
            minikube image load "$IMAGE_NAME"
        fi
    elif kind get clusters 2>/dev/null | grep -q "vllm"; then
        log_info "Loading image into Kind..."
        kind load docker-image "$IMAGE_NAME" --name vllm
    else
        log_info "No local cluster detected, skipping image load."
    fi
}

deploy_kubernetes() {
    log_info "Deploying Kubernetes resources..."

    kubectl apply -f "$PROJECT_DIR/kubernetes/namespace.yaml"

    if [ -n "${HF_TOKEN:-}" ]; then
        kubectl create secret generic vllm-secrets \
            --from-literal=hf_token="$HF_TOKEN" \
            --namespace "$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        kubectl apply -f "$PROJECT_DIR/kubernetes/vllm-secret.yaml"
    fi

    kubectl apply -f "$PROJECT_DIR/kubernetes/prometheus-servicemonitor.yaml" 2>/dev/null || true

    log_info "Applying CPU-mode deployment..."
    kubectl apply -f "$PROJECT_DIR/kubernetes/vllm-deployment-cpu.yaml"

    kubectl apply -f "$PROJECT_DIR/kubernetes/vllm-service.yaml"
    kubectl apply -f "$PROJECT_DIR/kubernetes/vllm-hpa.yaml"

    log_info "Kubernetes resources applied."
}

deploy_observability() {
    log_info "Deploying observability stack..."

    if ! helm repo list | grep -q "prometheus-community"; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    fi
    helm repo update

    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring --create-namespace \
        --values "$PROJECT_DIR/helm/observability-values.yaml" \
        --set grafana.adminPassword=admin \
        --set prometheus.prometheusSpec.retention=1d \
        --set prometheus.prometheusSpec.retentionSize=2GB \
        --wait --timeout 10m

    kubectl apply -f "$PROJECT_DIR/kubernetes/grafana-dashboard-configmap.yaml"

    log_info "Observability stack deployed."
}

wait_for_pods() {
    log_info "Waiting for vLLM pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app=vllm \
        -n "$NAMESPACE" \
        --timeout=600s 2>/dev/null || {
        log_warn "Pods not ready yet. Checking status..."
        kubectl get pods -n "$NAMESPACE"
        log_info "The model download may take several minutes on first run."
    }
}

print_info() {
    echo ""
    echo "=============================================="
    log_info "Deployment Complete!"
    echo "=============================================="
    echo ""
    echo "Access vLLM service:"
    echo "  kubectl port-forward -n $NAMESPACE svc/vllm 8000:8000"
    echo ""
    echo "Test the endpoint:"
    echo "  ./scripts/test-endpoint.sh"
    echo ""
    echo "Access Grafana:"
    echo "  kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
    echo "  URL: http://localhost:3000"
    echo "  User: admin"
    echo "  Password: admin"
    echo ""
}

main() {
    echo ""
    echo "=============================================="
    echo " vLLM Inference Service — Local Deployment"
    echo "=============================================="
    echo ""

    check_prerequisites
    start_cluster
    build_image
    load_image
    deploy_kubernetes
    deploy_observability
    wait_for_pods
    print_info
}

main "$@"
