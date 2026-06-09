# vLLM Inference Service on EKS

Production-grade deployment of vLLM serving facebook/opt-125m on AWS EKS with GPU node support for AI model serving infrastructure.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     AWS me-central-1                        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                      VPC                              │  │
│  │  ┌──────────────┐  ┌──────────────────────────────┐   │  │
│  │  │ Public Subnet│  │       Private Subnets (x2)    │   │  │
│  │  │              │  │  ┌──────────┐ ┌──────────┐   │   │  │
│  │  │  ALB (Ingress│  │  │ GPU Node │ │ GPU Node │   │   │  │
│  │  │  Controller) │  │  │ g4dn.xl  │ │ g4dn.xl  │   │   │  │
│  │  │              │  │  │ ┌──────┐ │ │ ┌──────┐ │   │   │  │
│  │  │              │  │  │ │vLLM  │ │ │ │vLLM  │ │   │   │  │
│  │  │              │  │  │ │Pod   │ │ │ │Pod   │ │   │   │  │
│  │  │              │  │  │ └──────┘ │ │ └──────┘ │   │   │  │
│  │  │              │  │  └──────────┘ └──────────┘   │   │  │
│  │  │              │  │  ┌──────────────────────┐     │   │  │
│  │  │              │  │  │ Observability Stack  │     │   │  │
│  │  │              │  │  │ Prometheus + Grafana │     │   │  │
│  │  │              │  │  │ + DCGM Exporter      │     │   │  │
│  │  │              │  │  └──────────────────────┘     │   │  │
│  │  └──────────────┘  └──────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────┘  │
│                        ┌──────────┐                          │
│                        │   ECR    │                          │
│                        └──────────┘                          │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Terraform** >= 1.5
- **kubectl** >= 1.28
- **Helm** >= 3.12
- **Docker** (for local image builds)
- **AWS CLI** configured with credentials (for production deployment)

## Quickstart

### 1. Local Test (Docker only — no Kubernetes)

```bash
# Build CPU image (Apple Silicon MacBooks)
docker build -t vllm-opt125m:cpu --target cpu -f docker/Dockerfile .

# Run vLLM (model auto-downloads on first run, ~250 MB)
docker run --rm -p 8000:8000 --shm-size=2g vllm-opt125m:cpu

# Test the endpoint
./scripts/test-endpoint.sh
```

> **Memory note:** If the container fails with "Available memory... is less than desired CPU memory utilization", increase Docker Desktop's memory limit (Settings → Resources → Memory → 6+ GB) or lower `VLLM_GPU_MEMORY_UTILIZATION` in the Dockerfile (default: 0.4).

### 2. Local Demo (Minikube + CPU-mode)

```bash
# Start minikube (minimal for 8GB MacBooks)
minikube start --cpus=2 --memory=2048 --driver=docker

# Build the CPU image
docker build --target cpu -t vllm-opt125m:cpu -f docker/Dockerfile .

# Load into minikube
minikube image load vllm-opt125m:cpu

# Deploy everything (vLLM + observability)
./scripts/deploy.sh

# Port-forward to access
kubectl port-forward -n vllm svc/vllm 8000:8000

# Test the endpoint
./scripts/test-endpoint.sh
```

### 3. Production (AWS EKS)

```bash
# Deploy infrastructure
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Configure kubectl
aws eks update-kubeconfig --region me-central-1 --name mal-vllm-cluster

# Build and push GPU image
docker build --target gpu -t ${AWS_ACCOUNT}.dkr.ecr.me-central-1.amazonaws.com/mal-vllm-opt125m:latest -f docker/Dockerfile .
aws ecr get-login-password | docker login --username AWS --password-stdin ${AWS_ACCOUNT}.dkr.ecr.me-central-1.amazonaws.com
docker push ${AWS_ACCOUNT}.dkr.ecr.me-central-1.amazonaws.com/mal-vllm-opt125m:latest

# Deploy observability
./scripts/deploy-observability.sh

# Deploy vLLM (GPU mode)
kubectl apply -f kubernetes/

# Get the ALB endpoint
kubectl get ingress -n vllm vllm-ingress
```

## Docker Images

| Target | Base Image | Purpose |
|--------|-----------|---------|
| `--target cpu` | `vllm/vllm-openai-cpu:v0.22.1-arm64` | Local dev (Apple Silicon / Intel CPU) |
| `--target gpu` | `vllm/vllm-openai:v0.22.1-cu129-ubuntu2404` | Production (NVIDIA GPU) |

## Model

- **Model:** [facebook/opt-125m](https://huggingface.co/facebook/opt-125m)
- **Size:** ~250 MB
- **Mode:** GPU (production) / CPU (local dev)
- **No token required** — model is publicly accessible

## GPU vs CPU Configuration

| Setting | GPU (Production) | CPU (Local Dev) |
|---------|-----------------|-----------------|
| Base image | vllm-openai:v0.22.1-cu129 | vllm-openai-cpu:v0.22.1-arm64 |
| Device | auto (CUDA) | cpu |
| gpu-memory-utilization | 0.85 | 0.4 |
| tensor-parallel-size | 1 | N/A |
| max-num-seqs | 32 | 16 |
| Memory request | 2Gi | N/A |
| GPU resource | nvidia.com/gpu: 1 | none |
| Node tolerations | nvidia.com/gpu | none |

## Repository Structure

| Path | Purpose |
|------|---------|
| `terraform/` | EKS cluster, VPC, IAM via terraform-aws-modules |
| `kubernetes/` | vLLM Deployment, Service, Ingress, HPA, Secrets |
| `docker/` | Multi-stage Dockerfile + entrypoint |
| `helm/` | Prometheus + Grafana + DCGM Exporter values |
| `.github/workflows/` | CI/CD: build → ECR push → rolling deploy |
| `scripts/` | Deployment helpers and endpoint testing |
| `docs/` | Architecture & trade-offs document |

## Security

- No secrets in code — all credentials via AWS Secrets Manager or Kubernetes Secrets
- Non-root container execution
- Private subnets for GPU nodes
- IAM roles for service accounts (IRSA)
- Container image vulnerability scanning (Trivy) in CI/CD
