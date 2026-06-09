#!/bin/bash
# ============================================================================
# test-endpoint.sh — Test the vLLM /v1/completions Endpoint
# ============================================================================
# Usage:
#   ./scripts/test-endpoint.sh                          # localhost:8000
#   ./scripts/test-endpoint.sh https://my-alb-url.com   # remote endpoint
# ============================================================================

set -euo pipefail

ENDPOINT="${1:-http://localhost:8000}"
COMPLETIONS_URL="${ENDPOINT}/v1/completions"
HEALTH_URL="${ENDPOINT}/health"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

info "Testing vLLM at: $ENDPOINT"

info "Checking health endpoint..."
HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" --connect-timeout 10)
if [ "$HEALTH_RESPONSE" -eq 200 ]; then
    pass "Health endpoint returned 200"
else
    fail "Health endpoint returned $HEALTH_RESPONSE"
    exit 1
fi

info "Testing /v1/completions with simple prompt..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$COMPLETIONS_URL" \
    -H "Content-Type: application/json" \
    --connect-timeout 30 \
    --max-time 120 \
    -d '{
        "model": "facebook/opt-125m",
        "prompt": "Once upon a time,",
        "max_tokens": 50,
        "temperature": 0.7,
        "top_p": 0.95
    }')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo ""
echo "HTTP Status: $HTTP_CODE"

if [ "$HTTP_CODE" -eq 200 ]; then
    echo ""
    echo "Response:"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    echo ""
    pass "/v1/completions returned 200 OK"

    if echo "$BODY" | grep -q '"text"'; then
        pass "Response contains generated text"
    elif echo "$BODY" | grep -q '"choices"'; then
        pass "Response contains choices"
    else
        fail "Response does not contain expected fields"
    fi
else
    echo ""
    echo "Response:"
    echo "$BODY"
    fail "/v1/completions failed with HTTP $HTTP_CODE"
    exit 1
fi

echo ""
echo "=============================================="
info "All tests passed!"
echo "=============================================="
