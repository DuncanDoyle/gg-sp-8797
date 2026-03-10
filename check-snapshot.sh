#!/bin/sh

# Inspects the Gloo Edge edge snapshot to show whether the shared RouteOption
# 'simple-rto' has been mutated with options from the /api VS route.
#
# Expected: staged_transformations and timeout are null (not present in the K8s resource)
# Actual (bug): both fields are populated with values leaked from the /api VS route

GLOO_PORT=9095

echo "============================================================"
echo "Edge snapshot: RouteOption 'simple-rto' contamination check"
echo "Issue: https://github.com/solo-io/solo-projects/issues/8797"
echo "============================================================"
echo ""

# Start port-forward to the Gloo control plane
kubectl -n gloo-system port-forward deploy/gloo $GLOO_PORT &
PF_PID=$!

# Give it a moment to establish
sleep 2

echo "--- RouteOption 'simple-rto' options in the edge snapshot ---"
echo ""
curl -s localhost:$GLOO_PORT/snapshots/edge | \
  jq '.data.RouteOptions[] | select(.metadata.name == "simple-rto") | .options | {staged_transformations, timeout}'

echo ""
echo "Expected: { \"staged_transformations\": null, \"timeout\": null }"
echo "Actual (bug): staged_transformations and timeout are populated with values from the /api VS route"

kill $PF_PID 2>/dev/null
