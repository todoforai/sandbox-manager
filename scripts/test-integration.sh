#!/bin/bash
# Test sandbox integration with resource-gateway
set -e

GATEWAY_URL="${GATEWAY_URL:-http://localhost:6000}"
SANDBOX_URL="${SANDBOX_URL:-http://localhost:9000}"
API_KEY="${API_KEY:-}"

echo "=== Sandbox Integration Test ==="
echo "Gateway: $GATEWAY_URL"
echo "Sandbox: $SANDBOX_URL"
echo ""

# Check services are running
echo "1. Checking services..."
curl -sf "$GATEWAY_URL/health" > /dev/null && echo "   ✓ Gateway healthy" || echo "   ✗ Gateway not running"
curl -sf "$SANDBOX_URL/health" > /dev/null && echo "   ✓ Sandbox manager healthy" || echo "   ✗ Sandbox manager not running"
echo ""

# Create sandbox (direct, no auth)
echo "2. Creating sandbox (direct)..."
SANDBOX_RESP=$(curl -sf -X POST "$SANDBOX_URL/sandbox" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"test-user","template":"alpine-base","size":"small"}' 2>&1) || {
    echo "   ✗ Failed to create sandbox"
    echo "   Response: $SANDBOX_RESP"
    exit 1
}
SANDBOX_ID=$(echo "$SANDBOX_RESP" | grep -oP '"id"\s*:\s*"\K[^"]+')
echo "   ✓ Created sandbox: $SANDBOX_ID"
echo ""

# Test WebSocket via gateway (requires API key)
if [ -n "$API_KEY" ]; then
  echo "3. Testing WebSocket via gateway..."
  echo "   wscat -c 'ws://localhost:6000/sandbox/$SANDBOX_ID?api_key=$API_KEY'"
  echo "   (manual test - requires wscat)"
else
  echo "3. Skipping gateway test (no API_KEY set)"
fi
echo ""

# Cleanup
echo "4. Cleaning up..."
curl -sf -X DELETE "$SANDBOX_URL/sandbox/$SANDBOX_ID" > /dev/null && echo "   ✓ Deleted sandbox" || echo "   ✗ Failed to delete"
echo ""

echo "=== Test Complete ==="
echo ""
echo "To test with gateway auth:"
echo "  API_KEY=your-api-key $0"
