#!/bin/bash
# ============================================================================
# deploy-observability.sh — Deploy Prometheus + Grafana + DCGM Exporter
# ============================================================================
# Usage:
#   ./scripts/deploy-observability.sh
#   ./scripts/deploy-observability.sh --with-dcgm    # Include DCGM for GPU
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WITH_DCGM=false

for arg in "$@"; do
    case "$arg" in
        --with-dcgm) WITH_DCGM=true ;;
    esac
done

GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

log_info "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add nvidia https://nvidia.github.io/dcgm-exporter 2>/dev/null || true
helm repo update

log_info "Deploying kube-prometheus-stack..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --values "$PROJECT_DIR/helm/observability-values.yaml" \
    --wait --timeout 10m

if [ "$WITH_DCGM" = true ]; then
    log_info "Deploying NVIDIA DCGM Exporter..."

    helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
        --namespace monitoring \
        --values "$PROJECT_DIR/helm/dcgm-exporter-values.yaml" \
        --wait --timeout 5m
else
    log_info "Skipping DCGM Exporter (use --with-dcgm to enable)."
fi

log_info "Applying Grafana dashboard ConfigMap..."
kubectl apply -f "$PROJECT_DIR/kubernetes/grafana-dashboard-configmap.yaml"

log_info "Observability stack deployed successfully."
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
echo "  URL: http://localhost:3000"
echo "  User: admin"
echo "  Password: admin"
