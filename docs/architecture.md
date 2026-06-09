# AI Inference Infrastructure — Architecture & Trade-offs

**vLLM Inference Service on AWS EKS**

---

## 1. Design Decisions

### EKS Node Group Configuration

**Choice:** Single managed node group of `g4dn.xlarge` instances (1x NVIDIA T4 GPU, 4 vCPU, 16 GiB RAM), configured with Spot capacity and on-demand fallback.

**Why g4dn.xlarge:** The T4 GPU (16 GB VRAM) provides the best cost-to-inference-performance ratio for small-to-medium models. facebook/opt-125m (~250 MB) easily fits on even a single T4 with room for large batch sizes. The `g4dn` family cost is approximately $0.53/hr on-demand and $0.16/hr spot — a 70% cost reduction for inference workloads that can tolerate interruptions during non-peak hours.

**Trade-off — Spot vs On-Demand:** Spot instances save ~60-70% but risk mid-inference interruptions. For a regulated bank's inference pipeline, request truncation is unacceptable. We mitigate this with spot-to-on-demand fallback in the node group configuration, ensuring capacity is always available. A long-term improvement would involve graceful draining via Kubernetes `preStop` hooks and Karpenter's node expiry handling.

**AMI Selection:** `AL2_x86_64_GPU` — the AWS-optimized Amazon Linux 2 AMI with pre-installed NVIDIA drivers, EKS bootstrap scripts, and the nvidia-container-runtime. This avoids a custom AMI pipeline and ensures immediate GPU availability on node join.

### vLLM Serving Settings

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `tensor-parallel-size` | 1 | opt-125m (~250 MB) fits entirely on a single T4 GPU (16 GB). Tensor parallelism across GPUs would add inter-GPU communication overhead with no throughput benefit at this model size. |
| `gpu-memory-utilization` | 0.85 | Reserves 15% GPU memory for CUDA context and KV cache overhead. At 85%, ~13.6 GB is usable — far more than needed for the model weights (250 MB) plus KV cache, allowing large batch sizes. |
| `max-model-len` | 2048 | T4's 16 GB VRAM constrains max context length. Increasing to 4096 or 8192 would require larger GPUs (A10G/A100) or model quantization. For a banking chatbot use case, 2048 tokens covers most customer interactions. |
| `max-num-seqs` | 32 | Concurrent sequences limited to balance throughput and latency. At 32 concurrent sequences, each gets ~425 MB of KV cache budget. |
| `dtype` | auto | vLLM auto-selects FP16 for GPU. For CPU-mode (local development), it falls back to FP32. |

**Trade-off — Batch Size vs Latency:** Larger `max-num-seqs` improves throughput (more concurrent generations) but increases per-request latency due to KV cache contention. We chose 32 as a conservative default that can be tuned via environment variables per workload pattern.

**CPU-Mode Fallback:** The Docker image supports `VLLM_DEVICE=cpu` for local development via Minikube/Kind. CPU inference on opt-125m is slower than GPU but perfectly usable for development and CI/CD validation on machines with 8+ GB RAM. GPU-specific production configs (tolerations, node selectors, NVIDIA device plugin) are present in all manifests and simply conditionally applied.

### Autoscaling Strategy

**Choice:** Kubernetes HPA (Horizontal Pod Autoscaler) with CPU and Memory Utilization as primary metrics.

**Why HPA over KEDA:** HPA is native, requires no additional operator, and integrates with the metrics-server already present in EKS. For GPU workloads, however, CPU/memory metrics are suboptimal — vLLM can be GPU-saturated at low CPU usage.

**Production path for GPU-aware scaling:**
1. Deploy NVIDIA DCGM Exporter (DaemonSet, scrapes GPU metrics via Prometheus)
2. Configure Prometheus Adapter to expose `DCGM_FI_DEV_GPU_UTIL` as a custom metric
3. Add GPU utilization metric to HPA (target: 80% average DCGM utilization)
4. Alternatively, adopt KEDA with the Prometheus scaler for request-queue-depth scaling

**Scaling Behavior:**
- Scale-up: 1 pod every 60 seconds (conservative — GPU pods need 2-5 minutes for model loading on new nodes)
- Scale-down: 1 pod every 2 minutes with 5-minute stabilization window (prevents thrashing from bursty inference traffic)

---

## 2. GPU Cluster Management at Scale

### Fleet Management (10–50 GPU Nodes)

Managing a GPU fleet at this scale requires treating GPUs as first-class, finite resources — not just another compute shape.

**Multi-AZ Placement:** GPU nodes are distributed evenly across 2–3 availability zones. The EKS managed node group configuration specifies private subnets in each AZ. This provides resilience against single-AZ failures while keeping inter-AZ latency low (typically <2ms in `me-central-1`).

**Node Lifecycle Automation — Karpenter:** At 10+ nodes, static managed node groups become rigid. Karpenter (AWS-native Kubernetes node autoscaler) would replace the Terraform-managed node group for dynamic node provisioning. Karpenter consolidates underutilized nodes, selects the optimal instance type based on pending GPU pod requirements, and handles Spot interruption with a 2-minute rebalance recommendation window.

**Spot Instance Strategy at Scale:**
- **Diversification:** Request multiple GPU instance types (`g4dn.xlarge`, `g5.xlarge`, `g4dn.2xlarge`) across multiple Spot capacity pools. Karpenter's `weighted` provisioning strategy biases toward the cheapest available option.
- **Fallback Chain:** Spot → On-Demand g4dn → On-Demand g5 (if g4dn capacity is exhausted)
- **Interruption Handling:** Kubernetes 1.30+ supports Pod Disruption Budgets (PDBs) with `unhealthyPodEvictionPolicy: AlwaysAllow`. Combined with Karpenter's native Spot interruption handling, nodes receive a 2-minute SIGTERM before termination, allowing graceful request completion. vLLM's `preStop` hook can flush pending requests to a backup endpoint.

**GPU Health Monitoring — DCGM Deep Dive:**

NVIDIA's Data Center GPU Manager (DCGM) provides 100+ GPU metrics. Critical health signals:
- **XID Errors:** 40+ error types indicating hardware failures. An XID 48 (Double Bit ECC Error) requires immediate node cordon + drain.
- **GPU Memory ECC Errors:** Correctable errors above a threshold indicate imminent GPU failure. A Prometheus alert rule can trigger automated node replacement.
- **GPU Temperature:** Sustained temps above 85°C signal cooling issues. DCGM's thermal throttling counters correlate with performance degradation.
- **GPU Retired Pages:** Memory pages permanently retired due to errors. A node with >10 retired pages should be drained and its underlying instance terminated.

**Node Replacement Automation:**
1. DCGM metric triggers a Prometheus alert (e.g., `DCGM_FI_DEV_XID_ERRORS > 0`)
2. Alertmanager routes to a webhook receiver
3. Webhook executes `kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
4. Karpenter (or managed node group) replaces the terminated instance

### GPU Driver Version Cohesion

All nodes must run identical NVIDIA driver versions (pinned to CUDA 12.9 in our image). The `AL2_x86_64_GPU` AMI manages this implicitly, but at scale, a custom AMI built with Packer + a driver version pin in the build pipeline prevents version drift across nodes.

---

## 3. What We Cut

The following were deprioritized in the initial implementation. They represent the first items to implement in a real production rollout:

### Priority 1 — Must Implement Before Production

| Item | Impact | Effort |
|------|--------|--------|
| **TLS Termination at ALB** | Currently HTTP-only. Production requires ACM certificate + HTTPS listener on the ALB Ingress. | Low |
| **AWS WAF Association** | Web Application Firewall for OWASP Top 10 protection, rate limiting per IP, and bot control. Critical for a public-facing banking API. | Medium |
| **GPU-Aware Autoscaling** | Current HPA uses CPU/memory. GPU utilization via DCGM + Prometheus Adapter is essential for accurate scaling. | Medium |
| **External Secrets Operator** | Kubernetes Secrets currently use a placeholder template. ESO would sync HF_TOKEN from AWS Secrets Manager automatically with rotation support. | Low |
| **Model Version Registry** | No mechanism to track which model version is deployed. A model registry (MLflow or S3 versioning) with the ability to A/B test model versions. | Medium |
| **ArgoCD GitOps** | Current deployment uses `kubectl set image`. GitOps via ArgoCD provides declarative state management, automated drift detection, and a deployment audit trail. | Medium |

### Priority 2 — Near-Term Enhancements

| Item | Impact |
|------|--------|
| **Istio Service Mesh** | mTLS between services, request-level metrics, circuit breaking, and fault injection for resilience testing. |
| **PagerDuty On-Call Integration** | Alertmanager → PagerDuty for production incident response with escalation policies. |
| **GPU Auto-Remediation** | Automated node cordon/drain on GPU errors (XID, ECC, thermal) — currently requires manual intervention. |
| **Shadow/Canary Deployments** | Flagger or Argo Rollouts for progressive delivery of new model versions with automated latency/error analysis. |
| **Cost Allocation Tags** | Granular AWS cost tags per model/team/workload. GPU costs dominate at scale — precise attribution is essential. |
| **Chaos Engineering** | GPU node termination, Spot interruption, and AZ failure simulation to validate the resilience design. |

### Priority 3 — Long-Term Platform Features

| Item | Impact |
|------|--------|
| **Multi-Model Serving** | vLLM supports serving multiple LoRA adapters. For a bank, this enables model-per-use-case (fraud detection, customer support, document analysis) on shared GPU infrastructure. |
| **Model Quantization (AWQ/GPTQ)** | 4-bit quantization reduces opt-125m VRAM from ~250 MB to ~60 MB, enabling even larger batch sizes or the smallest/cheapest GPU instances. |
| **GPU Sharing via MIG** | On A100/H100 instances, Multi-Instance GPU (MIG) partitions a single GPU into isolated slices. This would allow multiple models to share a single physical GPU with guaranteed resource isolation — critical for multi-tenant banking workloads. |
| **Cross-Region DR** | Active-passive EKS cluster in `me-central-1` with model artifact replication. Given UAE data residency requirements, a second AZU region (when available) would serve as DR. |

---

## 4. Data Residency & Compliance

This infrastructure is designed to operate under UAE Central Bank (CBUAE) regulatory requirements. The following controls apply to the inference service:

### Data Residency (UAE Region Only)

| Layer | Control |
|-------|---------|
| **Region Lock** | All resources deployed exclusively in `me-central-1` (UAE). Terraform provider is hardcoded to this region. An AWS SCP (Service Control Policy) at the organization level denies any resource creation outside `me-central-1`. |
| **Model Location** | Model weights downloaded from HuggingFace Hub are cached on encrypted EBS volumes within UAE. If HuggingFace CDN serves from non-UAE edge locations, a VPC endpoint with S3 interface could reduce cross-border data transit. |
| **Inference Data** | Prompt and completion data never leave the VPC. vLLM runs entirely within private subnets. No external logging or analytics services receive inference payloads. |
| **Logs** | CloudWatch Logs, VPC Flow Logs, and EKS audit logs are stored in `me-central-1` only. Log retention is set to 30 days with automatic expiration. For financial audit requirements, logs would be archived to S3 Glacier Deep Archive (UAE) with 7-year retention. |

### Network Isolation

| Layer | Control |
|-------|---------|
| **VPC Layout** | GPU nodes reside in private subnets (no direct internet access). Outbound traffic (model download, ECR pull) routes through NAT Gateway. Inbound traffic enters only via the ALB in public subnets. |
| **Security Groups** | GPU nodes allow ingress only from the VPC CIDR on port 8000 (vLLM API) and port 9400 (metrics). The ALB security group allows HTTP/HTTPS from 0.0.0.0/0 (restricted to specific IPs in production). |
| **Network Policies** | Calico or Cilium network policies would additionally restrict pod-to-pod communication — e.g., the vLLM pod can only receive traffic from the ALB controller pod and can only initiate connections to HuggingFace CDN (for model loading). |
| **PrivateLink** | ECR access via VPC endpoint (no internet path). Secrets Manager access via VPC endpoint. |

### Audit Logging

| Source | What's Logged | Retention |
|--------|--------------|-----------|
| **CloudTrail** | All AWS API calls (EKS, EC2, ECR, Secrets Manager). Organization trail enabled, log file validation. | 90 days (CloudWatch) + 7 years (S3) |
| **EKS Audit Logs** | Kubernetes API server audit logs (who ran `kubectl exec`, who modified deployments, who accessed secrets). Enabled via EKS control plane logging. | 30 days (CloudWatch) |
| **VPC Flow Logs** | Every IP flow 5-tuple (source/dest IP, port, protocol, accept/reject). Critical for detecting data exfiltration attempts. | 30 days (CloudWatch) |
| **vLLM Access Logs** | Request path, source IP, status code, latency. Configured at the ALB level (access logs to S3). Inference payloads (prompts/completions) are explicitly excluded from access logs to protect customer PII. | 30 days |

### Secrets Management

- **HuggingFace Token:** Stored in AWS Secrets Manager (`mal-vllm-huggingface-token`), encrypted with KMS CMK, accessed via IRSA (IAM Roles for Service Accounts) through the External Secrets Operator.
- **Model Weights Integrity:** SHA256 checksums verified at model load time to detect tampering.
- **Zero Secrets in Code:** No API keys, tokens, or credentials appear in the repository. All sensitive values flow through environment variables injected from Kubernetes Secrets at runtime.

### CBUAE-Specific Considerations

- **Data Localization:** All customer data (inference prompts, responses, model fine-tuning data) must reside in UAE. The `me-central-1` region satisfies this.
- **Right to Audit:** CloudTrail + EKS audit logs provide an immutable audit trail of all administrative actions.
- **Data Classification:** Inference requests may contain personally identifiable financial information (PIFI). At minimum, we must tag all S3 buckets, EBS volumes, and log groups with data classification levels and apply appropriate encryption (SSE-KMS with customer-managed keys, not AWS-managed).
- **Key Management:** KMS keys must be single-region (me-central-1), single-tenant (per-service keys), with automatic annual rotation.

---

## 5. 100x Scale — Nightmare Scenario

**Scenario:** Inference traffic grows 100x overnight (e.g., viral marketing, new product launch, or a competing service outage drives unexpected traffic to the service).

### What Breaks First

| Failure Point | Why | Time to Failure |
|---------------|-----|-----------------|
| **GPU Node Capacity** | 1x `g4dn.xlarge` can handle ~8 req/s at 32 concurrent sequences. 100x traffic = 800 req/s needing ~25-50 GPU nodes. AWS GPU Spot capacity in `me-central-1` is unknown and likely limited. | ~5-10 minutes (HPA maxes out, pods pending) |
| **Model Loading Latency** | New GPU nodes take 2-3 minutes to join EKS + 2-5 minutes for NVIDIA driver init + ~1 minute for HuggingFace model download (~250 MB). Total cold start: ~8 minutes per node. During a traffic spike, this delay accumulates. |
| **ALB Connection Pool** | ALB has a default max of 60 seconds idle timeout. Under 800 req/s, connection pools may exhaust, causing TCP resets to clients. | ~10-15 minutes |
| **Prometheus Scrape Interval** | 15s scrape interval at 50 nodes * 100+ DCGM metrics = 5,000+ time series per scrape. Prometheus memory may balloon, causing OOMKill. | ~30 minutes |
| **ECR Pull Rate** | 25-50 nodes pulling a 10+ GB image simultaneously can hit ECR's implicit rate limits (though high, burst pull can cause throttling). | ~10 minutes |
| **HuggingFace Rate Limiting** | Each node downloads the model independently. 50+ nodes hitting HuggingFace CDN simultaneously may trigger rate limiting or bandwidth throttling. | ~15 minutes |

### What Must Change

| Change | How |
|--------|-----|
| **Node Pre-Provisioning** | Maintain a warm pool of 5-10 pre-initialized GPU nodes (model cached, drivers loaded). Karpenter can be configured with minimum node counts per AZ. |
| **Model Caching Layer** | Instead of per-node HuggingFace downloads, pull model weights once into an S3 bucket (UAE), then use an init container that copies from S3 to a shared EFS volume mounted across nodes. This reduces node startup from 2 GB download per node to a local EFS read. |
| **Multi-Cluster Architecture** | Deploy inference across 2-3 EKS clusters in `me-central-1`. Route traffic via Route53 latency-based routing or Global Accelerator. This distributes GPU capacity requests across multiple AWS capacity pools. |
| **Request Queuing + Backpressure** | Deploy an Envoy or Istio sidecar that implements token-bucket rate limiting and request queuing with a max queue depth. Clients receive 429 Too Many Requests with a Retry-After header instead of indefinite request hanging. |
| **Model Quantization** | Switch from FP16 to AWQ 4-bit quantization. Reduces VRAM per model from ~250 MB to ~60 MB — enabling higher concurrency per GPU. |
| **ALB → NLB + Envoy** | Replace ALB with NLB (higher connection limits) fronting an Envoy proxy fleet that handles connection pooling, retry budgets, and circuit breaking. |
| **Prometheus Federation** | Deploy a Prometheus agent per cluster that forwards to a centralized Thanos/Cortex instance. This avoids single-Prometheus memory limits at scale. |
| **GPU Reservation System** | In a multi-tenant bank, different teams (fraud ML, chatbot, document processing) compete for GPU resources. A GPU reservation system with priority classes (system critical → production → batch) ensures fair allocation during contention. |

### The Real Cost

At 100x scale, GPU infrastructure alone costs **$400-800/hour** (50 nodes × $8-16/hr on-demand). This demands:
- **Showback/Chargeback:** Per-team cost attribution with Kubecost or CloudHealth
- **Commitment Discounts:** Reserved Instances (1-year) for baseline capacity + Spot for burst
- **Utilization Targets:** Minimum 70% GPU utilization across the fleet — idle GPUs are a cost emergency

---

*Document intended for 4-page PDF export. Last updated: June 2026.*
