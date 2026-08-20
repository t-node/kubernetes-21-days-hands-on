# CKA 30 solution

## Challenge answers

### C1 - Pick the patch type

**1. Replica count — strategic merge.**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 5
```

Or the `replicas:` transformer from
[CKA 29](../../29-kustomize-structure-transformers/), which is shorter still.

**2. One environment variable — strategic merge.**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - {name: NEW_VAR, value: "x"}
```

`env` merges by `name` (30.5), so existing variables survive. **This is the case
JSON 6902 handles badly** — appending with `/env/-` works, but replacing one
requires knowing its index.

**3. The second container, whatever it is called — JSON 6902.**

```yaml
- op: remove
  path: /spec/template/spec/containers/1
```

**Strategic merge cannot express this**, because `$patch: delete` needs the merge
key — the container's name — and the question deliberately does not give you one.
Position is exactly what JSON 6902 is for (30.6).

**4. An annotation with a `/` in the key — either, but note the escaping.**

Strategic merge, which is simpler here:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    example.com/team: platform
```

JSON 6902, if you must:

```yaml
- op: add
  path: /metadata/annotations
  value: {}
- op: add
  path: /metadata/annotations/example.com~1team
  value: platform
```

**Both lines are needed** unless the object already has an `annotations` map —
`add` fails on a missing parent (30.6).

**5. Replace a CRD's list entirely — JSON 6902.**

```yaml
- op: replace
  path: /spec/forProvider/tags
  value:
    - {key: env, value: prod}
```

**Strategic merge on a CRD is unreliable**, because merging by key requires the
schema's `patchMergeKey`, which Kustomize does not have for an arbitrary CRD. It
falls back to replacing the whole list — which happens to be what you want here,
but you should not depend on it. `op: replace` says so explicitly.

**6. Tolerations on every backend Deployment — strategic merge with a target.**

```yaml
patches:
  - target:
      kind: Deployment
      labelSelector: "tier=backend"
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata: {name: ignored}
      spec:
        template:
          spec:
            tolerations:
              - key: workload
                operator: Equal
                value: backend
                effect: NoSchedule
```

**The `target:` is what makes it one patch instead of N** (30.3), and the
`metadata.name` in the patch is ignored.

### C2 - Predict the merge

**1. `env` — three entries:**

```yaml
        env:
          - {name: A, value: "1"}         # untouched -- not mentioned
          - {name: B, value: "changed"}   # replaced -- matched by name
          - {name: C, value: "3"}         # added
```

`env` merges by `name` (30.5).

**2. `ports` — two entries:**

```yaml
        ports:
          - {containerPort: 80}
          - {containerPort: 443}
```

**Both, not just 443.** `ports` merges by `containerPort`, and 443 matched
nothing, so it was added. **This is the answer people get wrong** — a patch
listing one port reads like "the port is now 443", and it means "make sure 443 is
among the ports".

**3. `nginx:1.27`** — the patch did not mention `image`, so the base's value
stands. Everything unmentioned is untouched (30.1).

**4. To end up with only `C`:**

```yaml
    containers:
      - name: app
        env:
          $patch: replace
          - {name: C, value: "3"}
```

`$patch: replace` discards the base's list rather than merging into it (30.5).

The alternative, if you would rather be explicit about the removals:

```yaml
        env:
          - {name: A, $patch: delete}
          - {name: B, $patch: delete}
          - {name: C, value: "3"}
```

**Prefer `$patch: replace` when you want a guaranteed final state**, and the
per-element deletes when the base may legitimately add variables you want to
keep.

### C3 - Overlay or component

| # | Requirement | Answer | Why |
|---|---|---|---|
| 1 | prod 5 replicas, dev 1 | **overlay** | it differs by environment, and every environment has a value |
| 2 | some environments need external Redis | **component** | it is optional, and it adds objects *and* patches the base |
| 3 | prod uses the `production` namespace | **overlay** | positional, and it is a transformer, not even a patch |
| 4 | optional request tracing | **component** | opt-in, and it bundles a sidecar plus env vars -- the textbook case |
| 5 | staging uses a different registry | **overlay** | the `images` transformer in that overlay |

**The rule that separates them: does every environment have an answer?**
Replica count and namespace do — every environment has one, so it is an overlay
concern. Tracing does not — some environments simply do not have the feature, so
it is a component (30.8).

**A useful second test:** if enabling it means adding objects *and* modifying
existing ones, it is a component. Components can patch the base, which is what
makes them features rather than folders.

**The genuinely conditional case.**

Something conditional on a *value* rather than on which overlay is built —
"enable tracing when the sampling rate is above zero" — **is outside what
Kustomize does.** There is no `if`, and components are chosen at build time, not
evaluated.

Three honest options:

1. **Make it positional anyway.** Build `overlays/prod-with-tracing` and
   `overlays/prod`. Crude, and perfectly workable for a handful of combinations.
2. **Move the condition into the application.** A sampling rate of zero in a
   ConfigMap, with the sidecar always present, is usually simpler than making the
   sidecar conditional.
3. **Use Helm for that application.** This is the boundary
   [CKA 29](../../29-kustomize-structure-transformers/) 29.2 names, and reaching
   for the other tool is the right answer rather than a defeat.

**What not to do** is generate kustomizations with a script. At that point you
have templating with none of Helm's tooling.

### C4 - Debug a patch that does nothing

**1. The first command:**

```bash
diff <(kubectl kustomize base) <(kubectl kustomize overlays/prod)
```

**It beats looking at the cluster because it removes every other variable.** If
the render is missing the change, the problem is in the kustomization and
nothing about `apply`, RBAC, admission or controllers is involved. If the render
*contains* the change and the cluster does not, the problem is downstream — and
you have halved the search space with one command that touches nothing.

**2. Five reasons a patch silently matches nothing:**

1. **The name is wrong.** `target.name` is a **regex** and it is anchored — `web`
   does not match `prod-web`.
2. **The name is right but the *timing* is wrong.** A target written against the
   final, prefixed name can miss the object as it exists when the patch runs
   ([CKA 29](../../29-kustomize-structure-transformers/) C2 is the same trap for
   transformers).
3. **The `kind` or `group` is wrong** -- a CRD sharing a name with a built-in, or
   `kind: deployment` in lower case.
4. **A `labelSelector` matches nothing** -- the label is on the pod template
   rather than on the object, which is easy to miss because they look identical
   in the file.
5. **The strategic merge patch's own `metadata.name` does not match**, when there
   is no `target:` to override it.

A sixth worth knowing: **the file is not listed in `patches:` at all**, because
it was added to the directory and not to the kustomization.

**3. Making it loud in CI:**

```bash
#!/usr/bin/env bash
set -euo pipefail
for overlay in overlays/*/; do
  if diff -q <(kubectl kustomize base) <(kubectl kustomize "$overlay") >/dev/null; then
    echo "FAIL: $overlay renders identically to the base -- no patch took effect"
    exit 1
  fi
done
```

That catches the crude case. For a specific field, assert on it:

```bash
kubectl kustomize overlays/prod | yq '.spec.replicas' | grep -q '^5$' \
  || { echo "FAIL: prod replicas is not 5"; exit 1; }
```

**Render in CI and assert on the output**, exactly as you would test any other
build artefact. A kustomization is code that produces YAML, and untested code
that fails silently is the worst combination available.

Two cheap additions for the same job: `kubectl kustomize` on every overlay to
catch syntax errors, and `kubectl apply --dry-run=server -k` to catch schema
errors the local render cannot see.

### C5 - Design the repository

**1. The tree:**

```
  base/
    kustomization.yaml
    api.yaml
    web.yaml
  components/
    external-db/            kind: Component
    tracing/                kind: Component
  overlays/
    dev/
      kustomization.yaml
      replicas-patch.yaml
    staging/
      kustomization.yaml
      replicas-patch.yaml
    prod/
      base/                 <- the SHARED prod configuration
        kustomization.yaml
        replicas-patch.yaml
        resources-patch.yaml
      eu/
        kustomization.yaml  resources: [../base]
        ingress-patch.yaml
      us/
        kustomization.yaml  resources: [../base]
        ingress-patch.yaml
```

**2. What each contains:**

| File | Contents |
|---|---|
| `base/` | the objects, with the most common configuration (30.7) |
| `overlays/dev` | `resources: [../../base]`, namespace, prefix, 1 replica, `components: [external-db]` |
| `overlays/staging` | the same shape with staging values and its own registry via `images:` |
| `overlays/prod/base` | prod replicas, resource limits, `components: [external-db, tracing]` |
| `overlays/prod/eu` | `resources: [../base]` plus the eu hostname and node selector |
| `overlays/prod/us` | the us equivalents |

**`overlays/prod/base` is the important idea.** Everything the two regions share
lives there once, and each region's kustomization contains only what genuinely
differs. **That is an overlay stacked on an overlay**, which works because an
overlay is just a kustomization with a base (30.7).

**3. Deploying prod-eu:**

```bash
kubectl diff -k overlays/prod/eu
kubectl apply -k overlays/prod/eu
```

**4. What stacks, and the risk.**

**Stacking:** `base` -> `overlays/prod/base` -> `overlays/prod/eu`. Components
compose at any level, and one included in `prod/base` applies to both regions.

**The risk of stacking too deep is that the output stops being predictable.**
Each layer's transformers and patches apply in turn, so a field may be set three
times and you cannot tell which layer won without rendering. Concretely:

- **`namePrefix` compounds** into `prod-eu-app-web`, which is legal, ugly, and
  eventually hits the 63-character name limit.
- **Patch targets drift**, because a patch must target the name as it exists at
  that point, which depends on every prefix above it (C4.2).
- **`diff` against "the base" stops being meaningful**, because there are now
  three plausible bases.

**Two rules that keep it manageable:** no more than **three levels** (base,
shared environment, variant), and **set `namePrefix` at exactly one level**.
Beyond that, prefer duplicating a small kustomization over adding a layer —
twenty repeated lines are easier to reason about than a four-deep stack nobody
can render mentally.

---

## Files

| Path | Purpose |
|---|---|
| `base/` | two Deployments and two Services; `api` has two containers, two ports and two env vars so the list demos have something to work on |
| `patch-demos/01-strategic-merge.yaml` | modifies a container and merges `env` by name |
| `patch-demos/02-add-container.yaml` | the same mechanism, adding |
| `patch-demos/03-delete-container.yaml` | `$patch: delete` |
| `patch-demos/04-replace-list.yaml` | `$patch: replace`, used via `kustomization-replace.yaml` |
| `patch-demos/05-json6902.yaml` | append with `-`, remove by index, `~1` escaping |
| `patch-demos/kustomization.yaml` | every form at once, including an inline patch with a `labelSelector` target |
| `components/external-db/` | adds Postgres **and patches the api** -- a feature, not a folder |
| `components/monitoring/` | targets `name: ".*"`, so it reaches whatever exists when it runs |
| `overlays/dev`, `overlays/prod` | one base, two environments, different component sets |
| `verify.sh` | runs entirely without a cluster |

---

## On component ordering

`overlays/prod` lists its components in this order:

```yaml
components:
  - ../../components/external-db
  - ../../components/monitoring
```

and Step 6 of the lab shows that swapping them changes the output from three
metrics sidecars to two.

**The reason is that `monitoring` targets `kind: Deployment, name: ".*"`.** Run
after `external-db`, the Postgres Deployment already exists and is matched. Run
first, it is not there yet.

**Nothing warns you.** Both orders render successfully, both produce valid YAML,
and the difference is one missing sidecar — which surfaces weeks later as a gap
in a dashboard.

Two ways to stop depending on it: **target explicitly** (`name: "web|api"`
rather than `.*`), so the set is stated rather than discovered; or **treat
component order as significant and comment it**, as the file does. The first is
better where you can enumerate the targets; the second is honest where you
cannot.

## Why `$patch: replace` has its own kustomization

`patch-demos/kustomization.yaml` applies patches 01, 02, 03 and 05.
`04-replace-list.yaml` is deliberately excluded and reachable only through
`kustomization-replace.yaml`.

**Because `$patch: replace` and the add/delete patches would fight.** Patch 02
adds a container, patch 03 removes another, and patch 04 discards the whole list
— so applying all three leaves an outcome that depends on ordering and teaches
nothing about any of them individually.

That is a real lesson rather than a lab artefact: **patches against the same list
compose in ways that are hard to predict**, and `$patch: replace` in particular
overrides work that earlier patches did. If two patches touch the same list,
combine them into one.
