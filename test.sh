#!/bin/sh

GATEWAY_URL="http://api.example.com"

echo "============================================================"
echo "Test: RouteOption proto mutation via delegateOptions"
echo "Issue: https://github.com/solo-io/solo-projects/issues/8797"
echo "============================================================"
echo ""

# ---- Test 1: /ping should NOT receive the /api staged transformation ----
echo "--- Test 1: GET /ping ---"
echo "Expected: normal httpbin response (no VS_STAGED_MARKER in body)"
echo "Actual (bug): body replaced by 'VS_STAGED_MARKER: should NOT appear on /ping'"
echo ""
PING_RESPONSE=$(curl -s "$GATEWAY_URL/ping/get")
echo "Response: $PING_RESPONSE"
echo ""

if echo "$PING_RESPONSE" | grep -q "VS_STAGED_MARKER"; then
  echo "BUG CONFIRMED: /ping received the stagedTransformation from the /api VS route."
  echo "The shared RouteOption 'simple-rto' was mutated during translation."
else
  echo "No marker found in /ping response (bug may be fixed or route not responding)."
fi

echo ""

# ---- Test 2: /api should receive the staged transformation (expected) ----
echo "--- Test 2: GET /api ---"
echo "Expected: body contains 'VS_STAGED_MARKER' (this IS the /api route, transformation is intentional)"
echo ""
API_RESPONSE=$(curl -s "$GATEWAY_URL/api/get")
echo "Response: $API_RESPONSE"
echo ""

# ---- Test 3: Inspect the edge snapshot for RouteOption contamination ----
echo "--- Test 3: Edge snapshot ---"
echo "Run ./check-snapshot.sh to inspect the edge snapshot for RouteOption contamination."
