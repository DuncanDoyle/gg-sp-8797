# Root Cause Analysis: RouteOption Proto Mutation via delegateOptions

**Issue:** [solo-projects#8797](https://github.com/solo-io/solo-projects/issues/8797)
**Related:** [kgateway#8837](https://github.com/kgateway-dev/kgateway/issues/8837) (same class of bug for VirtualHostOptions)
**Codebase:** [solo-io/gloo](https://github.com/solo-io/gloo) (`main`)
**File:** [`projects/gateway/pkg/translator/converter.go`](https://github.com/solo-io/gloo/blob/main/projects/gateway/pkg/translator/converter.go)

---

## The Bug in One Sentence

During Gloo Edge route delegation translation, a `RouteOption` proto fetched from the snapshot
is assigned by **direct pointer reference** to a route, and a subsequent
`ShallowMergeRouteOptions` call writes the parent VS route's options into it — permanently
mutating the shared snapshot object for the rest of the translation cycle.

---

## Execution Path

The translation entry point for a VirtualService is:

```
converter.go: routeVisitor.ConvertVirtualService()
  └─ routeVisitor.visit()               ← runs for every route in every VS/RouteTable
       ├─ delegateOptions loop           ← resolves RouteOption refs from optionsConfigRefs
       ├─ validateAndMergeParentRoute()  ← merges parent VS route options into child
       └─ DelegateAction case            ← stores routeClone.Options as parentRoute.options
            └─ recursive visit() for each delegated RouteTable
```

### Step-by-step for the reproducer

Given:
- VS route `/api` → delegates to `api-routes` RT, has inline `stagedTransformations` + `timeout`
- VS route `/ping` → delegates to `ping-routes` RT, no inline options
- Both RTs reference `simple-rto` via `delegateOptions`; `simple-rto` has only a response header

**Phase 1 — Processing the VS itself:**

VS routes are processed in declaration order. For the `/api` route:

1. `visit()` runs at the VS level. The `/api` route is cloned via `proto.Clone(gatewayRoute)`.
2. The `/api` route is a `DelegateAction`, not a leaf route. It has inline options
   (`stagedTransformations` + `timeout`) but no `optionsConfigRefs`, so the delegateOptions loop
   is a no-op.
3. `parentRoute` is nil (this is a top-level VS route), so `validateAndMergeParentRoute` is skipped.
4. The code enters the `DelegateAction` case and builds a `routeInfo` with
   `options: routeClone.GetOptions()` — the VS `/api` route's inline options.
5. It recursively calls `visit()` for the `api-routes` RouteTable, passing that `routeInfo` as
   `parentRoute`.

**Phase 2 — Processing `api-routes` RouteTable (recursive visit):**

6. The route in `api-routes` is cloned via `proto.Clone()`. This route has **no inline options**
   (`routeClone.Options == nil`) but has `optionsConfigRefs.delegateOptions` referencing
   `simple-rto`.
7. The delegateOptions loop resolves `simple-rto` from the snapshot and hits the nil branch:

```go
// converter.go — visit(), delegateOptions loop
if routeClone.GetOptions() == nil {
    routeClone.Options = routeOpts.GetOptions()  // BUG: direct pointer into snapshot proto
    continue
}
```

8. `routeClone.Options` is now a **direct pointer** to the `simple-rto` proto object living
   inside the snapshot. No copy was made.
9. `parentRoute` is non-nil (it's the VS `/api` `routeInfo` from step 4), so
   `validateAndMergeParentRoute()` is called:

```go
// converter.go — validateAndMergeParentRoute()
child.Options, _ = utils.ShallowMergeRouteOptions(child.GetOptions(), parent.options)
//                                                 ^^^                ^^^
//                                  direct ptr to simple-rto          VS /api options
//                                  in the snapshot                   (stagedTransformations + timeout)
```

10. `ShallowMergeRouteOptions` (in `merge.go`) iterates over all fields of `dst` via reflection.
    For each field that is zero in `dst` but non-zero in `src`, it calls `dst.Set(src)`:

```go
// merge.go — ShallowMergeRouteOptions(), non-nil dst path
dstValue, srcValue := reflect.ValueOf(dst).Elem(), reflect.ValueOf(src).Elem()

for i := range dstValue.NumField() {
    dstField, srcField := dstValue.Field(i), srcValue.Field(i)
    if srcOverride := ShallowMerge(dstField, srcField); srcOverride {
        // ShallowMerge calls dstField.Set(srcField) — writes directly into dst
        overwrote = true
    }
}
return dst, overwrote   // returns the same pointer, now mutated
```

11. `staged_transformations` and `timeout` from the VS `/api` route are now **written directly
    into the `simple-rto` proto object in the snapshot**. The snapshot is corrupted.

**Phase 3 — Processing `ping-routes` RouteTable (back in the VS-level visit loop):**

12. The VS loop moves to the `/ping` route. Same flow — it delegates to `ping-routes` RT.
13. The route in `ping-routes` also has nil options and references `simple-rto` via
    `delegateOptions`.
14. `visit()` resolves `simple-rto` from the snapshot — but the proto has already been mutated
    in step 11.
15. `routeClone.Options` is now a direct pointer to the **already-contaminated** `simple-rto`.
16. The VS `/ping` route has no inline options, so `parent.options` is nil,
    `validateAndMergeParentRoute` merges nothing — but the damage was done in step 11.
17. The final Envoy config for `/ping` carries `staged_transformations` and `timeout` that were
    never configured for it.

---

## Why the Bug is Order-Dependent

Routes are processed **in declaration order** within the VirtualService. The first route whose
parent VS options are non-nil and whose child references a shared `RouteOption` is the one that
contaminates the snapshot. If `/ping` were listed before `/api` in the VS, `/ping` would be
processed first, and its parent has no inline options, so nothing would be written into
`simple-rto`. Then when `/api` is processed, it would contaminate `simple-rto`, but `/ping`'s
Envoy config was already emitted cleanly.

This makes the bug insidious: reordering routes in a VirtualService can change which routes are
affected, and the issue is non-obvious because the source of the contamination may be a
completely unrelated route.

---

## Why Deleting and Recreating the RouteOption Doesn't Help

The snapshot is rebuilt from Kubernetes on each sync cycle, so the fresh `simple-rto` proto
starts clean. But the very next translation cycle re-contaminates it via the same code path.
The mutation happens every translation cycle — it is not a one-time stale state issue.

---

## Why a New RouteOption Name Works Around It

A new `RouteOption` with a different name (e.g. `simple-rto-v2`) is a separate proto allocation
in the snapshot. In the customer's case, the new RouteOption is only referenced by `/ping`
routes, whose parent VS route carries no inline options — so `validateAndMergeParentRoute` has
nothing to merge into it, and it stays clean.

Note that this workaround only helps if the new RouteOption is **not also** referenced by routes
whose parent VS route has inline options. If both routes still share the same RouteOption, the
bug would recur regardless of the name.

---

## Multiple delegateOptions Refs: the Non-nil Branch is Also Affected

The analysis above focuses on the nil-branch assignment, but the non-nil branch has a related
issue when a route references **multiple** `delegateOptions`:

```yaml
optionsConfigRefs:
  delegateOptions:
  - name: rto-shared    # ← first ref: hits nil branch, direct pointer
  - name: rto-extra     # ← second ref: hits non-nil branch
```

On the first iteration, `routeClone.Options` is nil → direct pointer to `rto-shared` in the
snapshot. On the second iteration, `routeClone.Options` is non-nil (it IS `rto-shared`'s proto),
so the code calls:

```go
routeClone.Options, _ = utils.ShallowMergeRouteOptions(routeClone.GetOptions(), routeOpts.GetOptions())
//                                                      ^^^
//                                      still the direct pointer to rto-shared
```

`ShallowMergeRouteOptions` fills zero fields in `dst` from `src`. Since `dst` is a direct
pointer to `rto-shared` in the snapshot, this writes `rto-extra`'s fields into `rto-shared`.

After fixing the nil branch to clone, this becomes safe: `routeClone.Options` is a clone,
so subsequent merges mutate the owned copy.

---

## The Fix

### Primary fix: `converter.go` — `visit()`, delegateOptions nil-branch

Clone the `RouteOption` options before assigning them to the route, so that downstream merge
operations mutate an owned copy rather than the shared snapshot object.

**Current code (buggy):**

```go
optionRefs := routeClone.GetOptionsConfigRefs().GetDelegateOptions()
for _, optionRef := range optionRefs {
    routeOpts, err := reporterHelper.snapshot.RouteOptions.Find(optionRef.GetNamespace(), optionRef.GetName())
    if err != nil {
        reporterHelper.addWarning(resource.InputResource(), err)
        continue
    }
    if routeClone.GetOptions() == nil {
        routeClone.Options = routeOpts.GetOptions()   // direct reference into snapshot
        continue
    }
    routeClone.Options, _ = utils.ShallowMergeRouteOptions(routeClone.GetOptions(), routeOpts.GetOptions())
}
```

**Fixed code:**

```go
optionRefs := routeClone.GetOptionsConfigRefs().GetDelegateOptions()
for _, optionRef := range optionRefs {
    routeOpts, err := reporterHelper.snapshot.RouteOptions.Find(optionRef.GetNamespace(), optionRef.GetName())
    if err != nil {
        reporterHelper.addWarning(resource.InputResource(), err)
        continue
    }
    if routeClone.GetOptions() == nil {
        // Clone the shared proto so that validateAndMergeParentRoute (and subsequent
        // iterations of this loop) cannot mutate the snapshot object.
        if routeOpts.GetOptions() != nil {
            routeClone.Options = routeOpts.GetOptions().Clone().(*gloov1.RouteOptions)
        }
        continue
    }
    routeClone.Options, _ = utils.ShallowMergeRouteOptions(routeClone.GetOptions(), routeOpts.GetOptions())
}
```

This single clone is sufficient because:
- After the clone, `routeClone.Options` is an owned copy, so both
  `validateAndMergeParentRoute` and subsequent delegateOptions iterations mutate a copy.
- The non-nil branch (`ShallowMergeRouteOptions`) only writes to `dst` (which is now the clone),
  never to `src` (the snapshot proto for subsequent refs). So snapshot protos referenced in later
  iterations are also safe.
- When the route already has inline options (non-nil before the loop), `routeClone.Options` came
  from `proto.Clone(gatewayRoute)` at the top of `visit()` — already an owned copy.

### Defence-in-depth: `validateAndMergeParentRoute`

For additional safety, clone `child.Options` before merging parent options into it, regardless of
how it was populated. This makes the function safe to call even if a future code change
introduces a new path that sets `child.Options` to a shared reference:

```go
func validateAndMergeParentRoute(child *gatewayv1.Route, parent *routeInfo) (*gatewayv1.Route, error) {
    // ... existing validation code ...

    // Clone child options before merging to ensure we never mutate a shared proto.
    if child.GetOptions() != nil {
        child.Options = child.GetOptions().Clone().(*gloov1.RouteOptions)
    }
    child.Options, _ = utils.ShallowMergeRouteOptions(child.GetOptions(), parent.options)

    return child, nil
}
```

This clone is technically redundant if the primary fix is in place, but it makes the invariant
("we never pass a shared proto as `dst` to a merge function") explicit and locally verifiable.

---

## Feature Flag: `GLOO_ISOLATE_DELEGATE_ROUTE_OPTIONS`

### Why a flag is needed

Users may unknowingly depend on the current (buggy) behaviour. The contamination causes parent
VS route options to propagate to **all** routes that share a `RouteOption` via `delegateOptions`.
If a user has:
- ExtAuth, CORS, or another security policy defined inline on a parent VS route
- A shared `RouteOption` referenced by child routes under that parent

…then the child routes currently receive those policies through contamination. Fixing the bug
would **remove** those policies from the child routes, which could silently weaken security
postures.

Conversely, the bug itself is a security risk: unintended policies (e.g. transformations that
alter auth headers, or permissive CORS) can bleed onto routes that were never meant to have them.
This is the scenario the customer in [solo-projects#8797](https://github.com/solo-io/solo-projects/issues/8797)
is hitting.

Because both fixing and not fixing carry security implications, the fix should ship with an
opt-out flag.

### Proposed flag

| | |
|---|---|
| **Environment variable** | `GLOO_ISOLATE_DELEGATE_ROUTE_OPTIONS` |
| **Set on** | `gloo` controller Deployment |
| **Default** | `"true"` (fixed, isolated behaviour) |
| **Opt-out value** | `"false"` (legacy, mutating behaviour) |

### Implementation sketch

Read the env var once at startup and thread it into the route converter:

```go
// pkg/translator/translator.go (or wherever NewRouteConverter is called)
isolateDelegateOptions := os.Getenv("GLOO_ISOLATE_DELEGATE_ROUTE_OPTIONS") != "false"
```

```go
// converter.go — visit(), delegateOptions loop
if routeClone.GetOptions() == nil {
    opts := routeOpts.GetOptions()
    if rv.isolateDelegateOptions && opts != nil {
        opts = opts.Clone().(*gloov1.RouteOptions)
    }
    routeClone.Options = opts
    continue
}
```

When `false`, the old behaviour is preserved. A deprecation warning should be logged at startup:

> *"GLOO_ISOLATE_DELEGATE_ROUTE_OPTIONS=false is deprecated and will be removed in a future
> release. Shared RouteOptions referenced via delegateOptions may receive unintended options
> from parent VS routes. See solo-projects#8797."*

### Deprecation plan

1. **Now:** Ship the fix defaulting to `true`. Log a warning when `false` is explicitly set.
2. **Next major release:** Remove the flag; isolation becomes the only behaviour.

---

## Files to Change

| File | Change |
|---|---|
| `projects/gateway/pkg/translator/converter.go` | Clone `routeOpts.GetOptions()` in the nil-options branch of the delegateOptions loop (gated by flag); optionally clone in `validateAndMergeParentRoute`; add `isolateDelegateOptions` field to `routeVisitor` |
| `projects/gateway/pkg/translator/converter_test.go` | Add test: two RouteTables referencing the same `RouteOption` under different parent VS routes with different inline options must not contaminate each other |
| `NewRouteConverter` call site | Read env var `GLOO_ISOLATE_DELEGATE_ROUTE_OPTIONS` and pass to converter |
| Helm chart / deployment templates | Expose the env var as a configurable value on the `gloo` Deployment |

---

## Related: VirtualHostOptions

[kgateway#8837](https://github.com/kgateway-dev/kgateway/issues/8837) reports the same class of
bug for `VirtualHostOptions` with extauth. The `ShallowMergeVirtualHostOptions` function in
`merge.go` follows the identical pattern — it mutates `dst` in place when non-nil. Any code path
that passes a shared `VirtualHostOption` proto as `dst` is vulnerable to the same contamination.
The fix strategy is the same: clone before merging.
