# Deployment Plan — vLLM Inference Service on EKS

## 1. Build Challenge: Deploy a vLLM Inference Service on EKS

### 1.1 Overview

Deploy a production-grade vLLM inference service on AWS EKS with GPU node support, serving `facebook/opt-125m` (~250 MB model). The service must be accessible via an API endpoint, auto-scale, and include observability.

### 1.2 Deliverables

| Deliverable | Status |
|------------|--------|
| GitHub repository with IaC, K8s manifests, Dockerfile, CI/CD | Done |
| Live deployed service URL or screen recording of `/v1/completions` + Grafana | Pending |
| Architecture & trade-offs document (PDF, max 4 pages) | Done |

### 1.3 Infrastructure (Terraform)

```
terraform/
├── providers.tf    # AWS ~> 5.0, me-central-1, S3 backend
├── main.tf         # VPC, EKS cluster (terraform-aws-modules/eks ~> 20.0),
│                   #   GPU node group (g4dn.xlarge), ECR, ALB Controller, NVIDIA plugin
├── variables.tf    # All vars with descriptions (region, cluster_name, instance_type, etc.)
├── outputs.tf      # EKS endpoint, ECR URL, Grafana password command
└── iam.tf          # IRSA for ALB Controller, EKS roles, Secrets Manager access
```

**Key decisions:**
- **Region:** `me-central-1` (UAE) for data residency
- **GPU node group:** g4dn.xlarge (1x T4 GPU, 16 GB VRAM), Spot with on-demand fallback, AL2_x86_64_GPU AMI
- **VPC:** Public + private subnets across 2 AZs, NAT Gateway
- **ECR:** Mal-vllm-opt125m repo, scan on push, lifecycle policy (keep last 20 images)
- **Secrets:** AWS Secrets Manager for HuggingFace token, IRSA for pod access

### 1.4 Kubernetes Manifests

```
kubernetes/
├── namespace.yaml                    # vllm namespace
├── vllm-deployment.yaml              # Deployment + SA + RBAC
├── vllm-service.yaml                 # ClusterIP on 8000
├── vllm-ingress.yaml                 # AWS ALB Ingress (internet-facing)
├── vllm-hpa.yaml                     # HPA: min 1, max 5, CPU + memory targets
├── vllm-secret.yaml                  # K8s Secret template (HF_TOKEN)
├── grafana-dashboard-configmap.yaml  # Pre-built Grafana dashboard JSON
└── prometheus-servicemonitor.yaml    # Prometheus ServiceMonitor for vLLM metrics
```

**Key decisions:**
- **GPU resources:** `nvidia.com/gpu: 1`, memory 2Gi req / 4Gi lim, CPU 1/2
- **Tolerations + nodeSelector** for GPU nodes
- **vLLM flags:** tensor-parallel=1, gpu-memory-utilization=0.85, max-model-len=2048, dtype=auto
- **Readiness probe:** `/health` after 60s (opt-125m loads fast)
- **Rolling update:** maxSurge 1, maxUnavailable 0
- **Ingress:** ALB (internet-facing), routes: `/v1/completions`, `/v1/chat/completions`, `/health`

### 1.5 Docker Image

```
docker/
├── Dockerfile         # Multi-stage: CPU (python:3.12-slim) + GPU (vllm-openai CUDA)
├── entrypoint.sh      # vLLM API server launcher
└── .dockerignore
```

**Build commands:**
```bash
# CPU (local dev)
docker build --target cpu -t vllm-opt125m:cpu -f docker/Dockerfile .

# GPU (production)
docker build --target gpu -t vllm-opt125m:gpu -f docker/Dockerfile .
```

### 1.6 Observability

```
helm/
├── observability-values.yaml     # kube-prometheus-stack config
└── dcgm-exporter-values.yaml     # NVIDIA DCGM Exporter for GPU metrics
```

**Stack:** Prometheus + Grafana (via `kube-prometheus-stack` Helm chart) + NVIDIA DCGM Exporter DaemonSet

**Grafana dashboard panels (pre-built via ConfigMap):**
1. vLLM Request Latency (p50/p95/p99) — histogram from vLLM `/metrics`
2. GPU Memory Utilization (%) — from DCGM exporter
3. GPU Compute Utilization (%) — from DCGM exporter
4. Request Throughput (req/s)
5. Token Generation Rate (tokens/s)
6. Active Requests in Queue
7. GPU Power Usage (W)
8. GPU Temperature (°C)
9. Pod Health Count

### 1.7 CI/CD Pipeline

```
.github/workflows/ci-cd.yaml
```

**Trigger:** Push to `main` branch

**Jobs:**
1. **validate** — Terraform fmt + validate, kubeconform for K8s manifests, hadolint for Dockerfile
2. **build** — Docker build + Trivy vulnerability scan + push to ECR
3. **deploy** — `kubectl set image` on EKS + rollout status check
4. **smoke-test** — Port-forward to vLLM service, test `/v1/completions` endpoint

**GitHub Secrets required:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ACCOUNT_ID`

### 1.8 Local Development (8GB MacBook)

```bash
# Option A: Docker only (no Kubernetes, ~1.5 GB RAM)
docker build --target cpu -t vllm-opt125m:cpu -f docker/Dockerfile .
docker run --rm -p 8000:8000 vllm-opt125m:cpu
./scripts/test-endpoint.sh

# Option B: Minikube (full K8s stack, ~4 GB RAM)
minikube start --cpus=2 --memory=2048 --driver=docker
./scripts/deploy.sh
```

### 1.9 GPU vs CPU Configuration Matrix

| Setting | GPU (Production) | CPU (Local Dev) |
|---------|-----------------|-----------------|
| Base image | vllm/vllm-openai v0.22.1-cu129 | python:3.12-slim + CPU PyTorch |
| Device | auto (CUDA detected) | cpu |
| tensor-parallel | 1 | N/A |
| GPU memory | 85% utilization | N/A |
| Memory request | 2Gi | 2Gi |
| Node selector | nvidia.com/gpu=true | none |
| Tolerations | nvidia.com/gpu exists | none |

### 1.10 Verification Checklist

- [ ] Terraform validates (`terraform validate`)
- [ ] Docker image builds (`docker build --target cpu ...`)
- [ ] vLLM starts and serves model (`docker run ...`)
- [ ] `/health` returns 200
- [ ] `/v1/completions` returns valid JSON with `choices`
- [ ] K8s manifests pass `kubeconform`
- [ ] Grafana dashboard loads and shows metrics
- [ ] HPA scales pods (simulate load)

---

## 2. Architecture & Trade-offs Document

### 2.1 Design Decisions

**EKS Node Group:**
- **g4dn.xlarge**: 1x T4 GPU (16 GB VRAM), 4 vCPU, 16 GiB RAM. Best cost-to-performance for opt-125m. $0.53/hr on-demand, $0.16/hr spot (~70% savings).
- **Spot with on-demand fallback**: Reduces cost while ensuring capacity. Graceful draining via `preStop` hooks for production.
- **AL2_x86_64_GPU AMI**: Pre-installed NVIDIA drivers, no custom AMI pipeline needed.

**vLLM Settings:**
- `tensor-parallel-size=1`: Single-GPU model. Parallelism adds overhead with no benefit for 250 MB model.
- `gpu-memory-utilization=0.85`: Reserves 15% for CUDA context + KV cache overhead.
- `max-model-len=2048`: Balanced context window for most use cases.
- `max-num-seqs=32`: Balance throughput vs per-request KV cache budget.

**Autoscaling:**
- **HPA** (not KEDA): Native, no extra operator. CPU + memory metrics initially; GPU utilization via DCGM + Prometheus Adapter is the production upgrade path.
- Scale-up: 1 pod/60s (conservative for GPU cold starts). Scale-down: 1 pod/120s with 5min stabilization.

**CPU-Mode Fallback:**
- Separate Docker build target (`--target cpu`) builds from `python:3.12-slim` with CPU-only PyTorch.
- ZERO CUDA dependencies in the CPU image — avoids vLLM device detection failures on non-GPU hardware.
- Enables full CI/CD validation without GPU hardware.

### 2.2 GPU Cluster Management at Scale (10–50 Nodes)

**Fleet Management:**
- **Multi-AZ**: GPU nodes across 2–3 AZs in private subnets.
- **Karpenter** (replaces static node groups at scale): Dynamic provisioning, consolidation, optimal instance selection.
- **Spot diversification**: Request multiple GPU types (g4dn, g5) across capacity pools. Fallback chain: Spot → On-Demand g4dn → On-Demand g5.

**GPU Health Monitoring (DCGM):**
- XID Errors → immediate cordon + drain (XID 48 = double-bit ECC error)
- GPU Memory ECC Errors → threshold-based alerting
- GPU Temperature > 85°C → thermal throttling alert
- GPU Retired Pages > 10 → node replacement

**Node Replacement Automation:**
1. DCGM metric → Prometheus alert
2. Alertmanager → webhook
3. Webhook → `kubectl cordon <node> && kubectl drain`
4. Karpenter → replace terminated instance

**Driver Cohesion:** Custom AMI (Packer) with pinned NVIDIA driver + CUDA version. Prevents version drift across fleet.

### 2.3 What We Cut (Production Readiness Gap)

**Priority 1 — Must Implement Before Production:**

| Item | Impact |
|------|--------|
| TLS Termination at ALB | Currently HTTP-only. Needs ACM cert + HTTPS listener. |
| AWS WAF | OWASP protection, IP rate limiting, bot control. |
| GPU-Aware Autoscaling | HPA uses CPU/memory; DCGM + Prometheus Adapter needed. |
| External Secrets Operator | Sync HF_TOKEN from AWS Secrets Manager to K8s Secrets. |
| ArgoCD GitOps | Declarative state, drift detection, audit trail. |
| Model Version Registry | MLflow or S3 versioning for A/B model testing. |

**Priority 2 — Near-Term:**

| Item | Impact |
|------|--------|
| Istio Service Mesh | mTLS, circuit breaking, canary deployments. |
| PagerDuty Integration | On-call escalation for production alerts. |
| GPU Auto-Remediation | Automated node drain on GPU errors. |
| Shadow/Canary Deployments | Flagger/Argo Rollouts for model version testing. |
| Cost Allocation Tags | Per-model/team cost attribution (GPU costs dominate). |

**Priority 3 — Long-Term:**

| Item | Impact |
|------|--------|
| Multi-Model Serving | LoRA adapters for model-per-use-case. |
| Model Quantization (AWQ) | 250 MB → ~60 MB, higher concurrency per GPU. |
| GPU Sharing (MIG) | A100/H100 GPU partitioning for multi-tenant isolation. |
| Cross-Region DR | Active-passive cluster in secondary AZU region. |

### 2.4 Data Residency & Compliance (CBUAE)

**Region Lock:**
- All resources in `me-central-1` (UAE). Terraform provider hardcoded.
- AWS SCP denies resource creation outside `me-central-1`.
- Model weights, inference data, and logs never leave UAE.

**Network Isolation:**
- GPU nodes in private subnets (no direct internet).
- Outbound via NAT Gateway. Inbound only via ALB.
- PrivateLink for ECR, Secrets Manager (no internet path).
- Network policies restrict pod-to-pod communication.

**Audit Logging:**
- **CloudTrail**: All AWS API calls. 90 days CloudWatch + 7 years S3.
- **EKS Audit Logs**: K8s API server actions. 30 days CloudWatch.
- **VPC Flow Logs**: All IP flows. 30 days CloudWatch.
- **ALB Access Logs**: Request metadata only (no inference payloads).

**Secrets Management:**
- HF_TOKEN in AWS Secrets Manager, encrypted with KMS CMK.
- Accessed via IRSA + External Secrets Operator.
- Zero secrets in repository.

**CBUAE Considerations:**
- All customer data (prompts, responses) stays in UAE.
- Immutable audit trail via CloudTrail + EKS logs.
- PIFI classification tags on S3, EBS, log groups.
- Single-region, single-tenant KMS keys with annual rotation.

### 2.5 100x Scale — What Breaks First

**Scenario:** 100x traffic overnight (viral event, competitor outage).

| Failure Point | Why | Time to Failure |
|---------------|-----|-----------------|
| GPU Node Capacity | 1 node → 50 nodes needed. Spot capacity in me-central-1 unknown. | 5–10 min |
| Model Loading Latency | 10 min/node cold start (EKS join + drivers + model download). | 15–20 min |
| ALB Connection Pool | 60s idle timeout exhausts at 800 req/s. | 10–15 min |
| Prometheus Memory | 50 nodes × 100 DCGM metrics = OOMKill. | 30 min |
| ECR Pull Rate | 50 nodes pulling 10 GB image simultaneously. | 10 min |
| HuggingFace Rate Limiting | 50 nodes downloading model simultaneously. | 15 min |

**Changes Required:**
1. **Node Pre-Provisioning** — Warm pool of 5–10 pre-initialized GPU nodes.
2. **Model Caching** — S3 → EFS shared volume, no per-node HuggingFace downloads.
3. **Multi-Cluster** — 2–3 EKS clusters in me-central-1, Route53 latency-based routing.
4. **Request Queuing** — Envoy/Istio sidecar with token-bucket rate limiting, 429 responses with Retry-After.
5. **Model Quantization** — AWQ 4-bit: 250 MB → 60 MB, 3x concurrency per GPU.
6. **NLB + Envoy** — Replace ALB with NLB (higher connections) fronting Envoy proxy fleet.
7. **Prometheus Federation** — Thanos/Cortex for horizontal scaling beyond single Prometheus.
8. **GPU Reservation System** — Priority classes for multi-tenant allocation (system > production > batch).

**Cost at Scale:** ~$400–800/hour (50 nodes × $8–16/hr on-demand). Demands Reserved Instances + Spot mix and minimum 70% GPU utilization target.

---

## Project Structure

```
devops_mal_assement/
├── README.md
├── plan.md                              # This file
├── .gitignore
├── terraform/
│   ├── providers.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── iam.tf
├── kubernetes/
│   ├── namespace.yaml
│   ├── vllm-deployment.yaml
│   ├── vllm-service.yaml
│   ├── vllm-ingress.yaml
│   ├── vllm-hpa.yaml
│   ├── vllm-secret.yaml
│   ├── grafana-dashboard-configmap.yaml
│   └── prometheus-servicemonitor.yaml
├── docker/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── .dockerignore
├── helm/
│   ├── observability-values.yaml
│   └── dcgm-exporter-values.yaml
├── .github/
│   └── workflows/
│       └── ci-cd.yaml
├── scripts/
│   ├── deploy.sh
│   ├── deploy-observability.sh
│   ├── test-endpoint.sh
│   └── port-forward.sh
└── docs/
    └── architecture.md
```

---

*Last updated: June 2026*
