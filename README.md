# Reproducer: RouteOption proto mutation via delegateOptions

**Issue:** [solo-projects#8797](https://github.com/solo-io/solo-projects/issues/8797)
**Related:** [kgateway#8837](https://github.com/kgateway-dev/kgateway/issues/8837)
**Product:** Gloo Gateway
**Version:** 1.20.5

## The Bug

When a `RouteOption` is referenced via `delegateOptions` from routes under multiple VirtualService routes, and one of those VS routes carries inline options (e.g. `stagedTransformations`, `timeout`), the Gloo Edge translation pipeline merges those VS-level options into the shared `RouteOption` proto **in place** instead of working on a copy.

This mutates the `RouteOption` in the **edge snapshot**, causing every route that references it to inherit options they never configured.

## Topology

```
VirtualService api-example-com
├── Route /api  (has inline: stagedTransformations + timeout)
│   └── delegates → RouteTable api-routes
│       └── /api  → upstream httpbin
│           └── delegateOptions → RouteOption simple-rto  ← gets mutated
│
└── Route /ping  (no inline options)
    └── delegates → RouteTable ping-routes
        └── /ping  → upstream httpbin
            └── delegateOptions → RouteOption simple-rto  ← inherits leak
```

## Expected Behavior

`simple-rto` contains only a response header transformation. The `/ping` route should receive only that header, unaffected by the `stagedTransformations` defined on the `/api` VS route.

## Actual Behavior

The edge snapshot shows `simple-rto` contaminated with `staged_transformations` and `timeout` from the `/api` VS route. All routes referencing `simple-rto` — including `/ping` — receive those options in their Envoy config. As a result, the `/ping` response body is replaced by the marker text.

Deleting and recreating the `RouteOption` does not help — it gets re-contaminated on the next sync cycle.

## Installation

Add the Gloo Gateway Helm repo:
```sh
helm repo add glooe https://storage.googleapis.com/gloo-ee-helm
```

Export your license key:
```sh
export GLOO_GATEWAY_LICENSE_KEY={your license key}
```

Install Gloo Edge:
```sh
cd install
./install-gloo-gateway-with-helm.sh
```

## Setup

```sh
cd install
./setup.sh
```

This deploys:
- The `gateway-proxy` Gateway
- The `httpbin` backend application
- The shared `RouteOption` (`simple-rto`) in the `httpbin` namespace
- Two `RouteTable` resources (`api-routes`, `ping-routes`), both referencing `simple-rto`
- The `VirtualService` with two delegating routes — `/api` (with inline options) and `/ping` (without)

## Reproduce

**Test 1 & 2 — HTTP requests:**
```sh
./test.sh
```

Sends requests to `/ping` and `/api` and checks whether the marker body transformation appeared on the `/ping` route (it should not).

**Test 3 — Edge snapshot inspection:**
```sh
./check-snapshot.sh
```

Port-forwards to the Gloo control plane and retrieves the edge snapshot, then extracts the `staged_transformations` and `timeout` fields from the `simple-rto` RouteOption.

**Expected:** `{ "staged_transformations": null, "timeout": null }`
**Actual (bug):** both fields populated with values leaked from the `/api` VS route

## Workaround

Use a distinct `RouteOption` per VS route. Creating a new `RouteOption` with a different name results in a fresh proto allocation and avoids the mutation. This was confirmed in the the issue — creating a separate `RouteOption` for the `/ping` route resolved the issue.

---

## Root Cause Analysis

The bug is in [`projects/gateway/pkg/translator/converter.go`](https://github.com/solo-io/gloo/blob/main/projects/gateway/pkg/translator/converter.go). When a route in a RouteTable has no inline options and references a `RouteOption` via `delegateOptions`, the translator assigns the snapshot proto by **direct pointer** rather than cloning it. A subsequent `ShallowMergeRouteOptions` call then writes the parent VS route's inline options into that pointer — permanently mutating the shared snapshot object for the rest of the translation cycle.

The fix is a one-line clone in the nil-options branch of the `delegateOptions` loop. Because the bug involves shared mutable state that some users may unknowingly rely on (e.g. inheriting ExtAuth or CORS from a parent VS route through contamination), the fix should ship behind an env var flag (`GLOO_ISOLATE_DELEGATE_ROUTE_OPTIONS`, defaulting to `true`) with a deprecation path.

See **[ANALYSIS.md](./ANALYSIS.md)** for the full root cause analysis, annotated code walkthrough, fix with code snippets, and feature flag implementation sketch.
