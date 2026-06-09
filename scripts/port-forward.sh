#!/bin/bash
# ============================================================================
# port-forward.sh — Access vLLM and Grafana via Port Forwarding
# ============================================================================
# Usage:
#   ./scripts/port-forward.sh vllm      # Forward vLLM service (8000)
#   ./scripts/port-forward.sh grafana   # Forward Grafana (3000)
#   ./scripts/port-forward.sh all       # Forward both
# ============================================================================

set -euo pipefail

NAMESPACE="vllm"
MONITORING_NS="monitoring"

forward_vllm() {
    echo "Forwarding vLLM service → http://localhost:8000"
    kubectl port-forward -n "$NAMESPACE" svc/vllm 8000:8000
}

forward_grafana() {
    echo "Forwarding Grafana → http://localhost:3000"
    echo "Credentials: admin / admin"
    kubectl port-forward -n "$MONITORING_NS" svc/monitoring-grafana 3000:80
}

case "${1:-all}" in
    vllm)
        forward_vllm
        ;;
    grafana)
        forward_grafana
        ;;
    all)
        echo "Starting port forwards..."
        echo "vLLM:     http://localhost:8000"
        echo "Grafana:  http://localhost:3000 (admin/admin)"
        echo "Press Ctrl+C to stop all."
        echo ""
        kubectl port-forward -n "$NAMESPACE" svc/vllm 8000:8000 &
        kubectl port-forward -n "$MONITORING_NS" svc/monitoring-grafana 3000:80 &
        wait
        ;;
    *)
        echo "Usage: $0 {vllm|grafana|all}"
        exit 1
        ;;
esac
