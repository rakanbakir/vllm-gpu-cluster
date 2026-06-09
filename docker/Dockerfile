# ============================================================================
# vLLM Inference Service — facebook/opt-125m
# ============================================================================
# Multi-stage build supporting both GPU (CUDA) and CPU inference.
#
# GPU build (production):
#   docker build -t vllm-opt125m:gpu \
#     --target gpu \
#     -f docker/Dockerfile .
#
# CPU build (Apple Silicon / ARM64):
#   docker build --target cpu -t vllm-opt125m:cpu -f docker/Dockerfile .
#
# CPU build (Linux / x86_64):
#   docker build --target cpu --build-arg CPU_ARCH=x86_64 -t vllm-opt125m:cpu -f docker/Dockerfile .
# ============================================================================

ARG CPU_ARCH=arm64

# ============================================================================
# Stage 1: CPU-only base (for local development)
# ============================================================================
FROM vllm/vllm-openai-cpu:v0.22.1-${CPU_ARCH} AS cpu

ENV MODEL_ID=facebook/opt-125m
ENV VLLM_HOST=0.0.0.0
ENV VLLM_LISTEN_PORT=8000
ENV VLLM_GPU_MEMORY_UTILIZATION=0.4
ENV VLLM_MAX_MODEL_LEN=2048
ENV VLLM_MAX_NUM_SEQS=16
ENV VLLM_DTYPE=auto
ENV HF_HOME=/home/vllm/.cache/huggingface
ENV NUMBA_CACHE_DIR=/tmp

RUN useradd -u 1000 vllm 2>/dev/null || true
RUN mkdir -p /home/vllm/.cache/huggingface /tmp/hf_cache \
    && chown -R 1000:1000 /home/vllm/.cache /tmp/hf_cache /tmp

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER 1000:1000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]

# ============================================================================
# Stage 2: GPU/CUDA base (production)
# Uses official vLLM CUDA image for GPU inference
# ============================================================================
FROM vllm/vllm-openai:v0.22.1-cu129-ubuntu2404 AS gpu

ARG DEVICE=auto
ENV VLLM_DEVICE=${DEVICE}
ENV MODEL_ID=facebook/opt-125m
ENV VLLM_HOST=0.0.0.0
ENV VLLM_LISTEN_PORT=8000
ENV VLLM_GPU_MEMORY_UTILIZATION=0.85
ENV VLLM_MAX_MODEL_LEN=2048
ENV VLLM_TENSOR_PARALLEL_SIZE=1
ENV VLLM_MAX_NUM_SEQS=32
ENV VLLM_DTYPE=auto
ENV HF_HOME=/home/vllm/.cache/huggingface
ENV NUMBA_CACHE_DIR=/tmp

RUN mkdir -p /home/vllm/.cache/huggingface /tmp/hf_cache \
    && chown -R 1000:1000 /home/vllm/.cache /tmp/hf_cache /tmp

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER 1000:1000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
