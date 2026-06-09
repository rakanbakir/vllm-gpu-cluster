#!/bin/bash
set -euo pipefail

MODEL_ID="${MODEL_ID:-facebook/opt-125m}"

echo "Starting vLLM with model: $MODEL_ID"

exec python3 -m vllm.entrypoints.openai.api_server \
    --model "$MODEL_ID" \
    --host "${VLLM_HOST:-0.0.0.0}" \
    --port "${VLLM_LISTEN_PORT:-8000}" \
    --gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION:-0.85}" \
    --max-model-len "${VLLM_MAX_MODEL_LEN:-2048}" \
    --tensor-parallel-size "${VLLM_TENSOR_PARALLEL_SIZE:-1}" \
    --max-num-seqs "${VLLM_MAX_NUM_SEQS:-32}" \
    --dtype "${VLLM_DTYPE:-auto}" \
    --served-model-name "$MODEL_ID"
