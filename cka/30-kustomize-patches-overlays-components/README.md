# CKA 30 — Kustomize: Patches, Overlays and Components

**Time:** 100-120 minutes
**Prerequisites:** [CKA 29](../29-kustomize-structure-transformers/), [CKA 04](../04-imperative-declarative-and-apply/)
**Source lectures:** 274, 275, 276, 277, 279, 281

[CKA 29](../29-kustomize-structure-transformers/) covered transformers — the
handful of things Kustomize knows how to change by name. **Patches change
anything else**, overlays organise them per environment, and components are
Kustomize's answer to "sometimes".

---

## Part 1 - Concepts

### 30.1 Two kinds of patch

| | **Strategic merge** | **JSON 6902** |
|---|---|---|
| Looks like | a partial Kubernetes manifest | a list of operations |
| Reads well | **yes** | no |
| Knows about Kubernetes | **yes** -- merges lists by key | no -- lists are arrays with indices |
| Deletes precisely | with a directive | **yes**, natively |
| Works on unknown CRDs | not reliably | **always** |

**Strategic merge is the default choice.** You write the shape you want and
Kustomize merges it in:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 5
```

**That is the entire patch.** Everything not mentioned is untouched;
`metadata.name` and `kind` are there to identify the target, not to be applied.

**JSON 6902 is a list of operations against paths:**

```yaml
- op: replace
  path: /spec/replicas
  value: 5
```

Verbose, precise, and the only option when a list must be manipulated by
position or the field belongs to a CRD whose merge semantics Kustomize does not
know.

### 30.2 One field, two deprecated ones

```yaml
patches:
  - path: replica-patch.yaml
    target:
      kind: Deployment
      name: web
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 5
    target:
      kind: Deployment
      name: api
```

**`patches:` handles both types and both forms** — a file via `path:`, or inline
via `patch:`. Kustomize decides which kind it is from the content: a YAML list of
`op:` entries is JSON 6902; anything else is a strategic merge.

> **`patchesStrategicMerge:` and `patchesJson6902:` are deprecated.** They still
> work, you will meet them, and the modern `patches:` replaces both.

### 30.3 Targeting

A strategic merge patch identifies its target by `kind` plus `metadata.name`
inside the patch itself. **`target:` lets you aim at many objects at once:**

```yaml
patches:
  - path: add-probes.yaml
    target:
      kind: Deployment
      labelSelector: "tier=backend"
```

| Selector | Matches |
|---|---|
| `kind`, `name` | the obvious ones -- and `name` is a **regex** |
| `namespace` | objects already in that namespace |
| `labelSelector` | standard label selector syntax |
| `annotationSelector` | the same, on annotations |
| `group`, `version` | for disambiguating API groups |

**`name` being a regex is useful and surprising**: `name: "web|api"` hits two, and
`name: ".*"` with a `kind` hits every object of that kind.

**A patch that matches nothing is silently ignored** — the same trap as
transformers in [CKA 29](../29-kustomize-structure-transformers/) C2. Render and
diff; if nothing changed, nothing matched.

### 30.4 Dictionaries merge

```yaml
# base                    # patch                    # result
metadata:                 metadata:                  metadata:
  labels:                   labels:                    labels:
    app: web                  tier: web-tier             app: web        <- untouched
    tier: frontend            version: v2                tier: web-tier  <- replaced
                                                         version: v2     <- added
```

**Maps merge key by key.** Nothing is lost unless you overwrite it, which is what
makes strategic merge patches short.

### 30.5 Lists are the hard part

**Strategic merge knows Kubernetes**, so some lists merge by a key rather than by
position:

| List | Merge key |
|---|---|
| `spec.template.spec.containers` | `name` |
| `containers[].ports` | `containerPort` |
| `containers[].env` | `name` |
| `spec.template.spec.volumes` | `name` |
| `imagePullSecrets` | **replaced wholesale** |

So this **adds** a container without disturbing the existing one:

```yaml
spec:
  template:
    spec:
      containers:
        - name: sidecar
          image: busybox:1.36
```

...and this **modifies** the existing one, because the name matches:

```yaml
      containers:
        - name: web
          image: nginx:1.28-alpine
```

**Two directives control the rest:**

```yaml
      containers:
        - name: sidecar
          $patch: delete          # remove this list element
```

```yaml
      containers:
        $patch: replace           # discard the base's list entirely
        - name: only-this-one
          image: nginx:alpine
```

**`$patch: delete` is the only way to remove a list element with a strategic
merge patch**, because omitting something means "leave it alone", not "delete
it".

### 30.6 JSON 6902, when position matters

```yaml
- op: replace
  path: /spec/replicas
  value: 5

- op: add
  path: /spec/template/spec/containers/0/env/-      # `-` means APPEND
  value:
    name: NEW_VAR
    value: "hello"

- op: remove
  path: /spec/template/spec/containers/1            # by INDEX

- op: add
  path: /metadata/annotations/example.com~1owner    # ~1 escapes a `/`
  value: platform
```

Six operations exist — `add`, `remove`, `replace`, `move`, `copy`, `test` — and
you will use the first three.

Three details cause most of the errors:

- **`-` appends to a list.** `/env/-` adds an element; `/env/0` replaces one.
- **Indices are positional and fragile.** `remove /containers/1` removes whatever
  is second *today*.
- **`/` inside a key is escaped as `~1`**, and `~` as `~0`. Annotation and label
  keys nearly always contain a `/`.

**`op: add` fails if the path's parent does not exist.** Adding an annotation to
an object with no `annotations` map needs the map created first — the usual cause
of `add operation does not apply: doc is missing path`.

### 30.7 Overlays

The structure Kustomize exists for:

```
  base/
    kustomization.yaml
    deployment.yaml
    service.yaml
  overlays/
    dev/
      kustomization.yaml      resources: [../../base]
      replicas-patch.yaml
    prod/
      kustomization.yaml      resources: [../../base]
      replicas-patch.yaml
      resources-patch.yaml
```

```bash
kubectl apply -k overlays/dev
kubectl apply -k overlays/prod
```

**An overlay is just a kustomization whose `resources` is a base.** There is no
special syntax — which is why overlays stack: an overlay can be the base of
another overlay.

**What belongs where** is the judgement call:

| In the base | In an overlay |
|---|---|
| everything common | anything that differs by environment |
| sensible defaults | replica counts, resource limits |
| the full object shape | hostnames, image tags, namespaces |

**Put the *most common* configuration in the base, not the smallest.** If two of
three environments want probes, the probes belong in the base and the third
overlay removes them — so the unusual case is the one that needs explaining.

### 30.8 Components are the answer to "sometimes"

Overlays are **positional** — dev, staging, prod. Components are **opt-in
features** any overlay can include:

```yaml
# components/external-db/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1     # NOT v1beta1
kind: Component                                   # NOT Kustomization
resources:
  - postgres.yaml
secretGenerator:
  - name: db-creds
    literals: [password=changeme]
patches:
  - path: add-db-env.yaml
    target: {kind: Deployment, name: api}
```

```yaml
# overlays/dev/kustomization.yaml
resources:
  - ../../base
components:
  - ../../components/external-db
```

**Note the different `apiVersion` and `kind`** — `v1alpha1` and `Component`.
Using `Kustomization` there is the usual first mistake.

A component can do everything a kustomization can: add resources, generate
ConfigMaps, and **patch the base**. That last part makes it a *feature* rather
than a bundle of files — `external-db` adds a Postgres Deployment *and* patches
the API Deployment to know about it.

**This is Kustomize's substitute for `{{ if .Values.database.enabled }}`**
([CKA 29](../29-kustomize-structure-transformers/) C5). Not as general — the
choice is made by which overlay you build, not by a value — but it covers the
common case cleanly and keeps every file valid YAML.

> **Components apply in order, after `resources`.** Two components patching the
> same field is last-one-wins, decided by the order of the `components:` list.

---

## Part 2 - Hands-on lab

```bash
find solution -name kustomization.yaml | sort
kubectl kustomize solution/base | grep -E "^kind:|^  name:"
```

The base is two Deployments and two Services. `api` deliberately has **two
containers, two ports and two environment variables**, so the list-merge
behaviour in 30.5 has something to work on.

### Step 1: A strategic merge patch merges

```bash
cat solution/patch-demos/01-strategic-merge.yaml
diff <(kubectl kustomize solution/base) <(kubectl kustomize solution/patch-demos) | head -40
```

Look at what happened to `web`'s environment variables:

```bash
kubectl kustomize solution/patch-demos | awk '/name: web$/,/^---/' | grep -A2 "env:"
```

```
          env:
            - name: API_URL
              value: http://api.prod:80      <- REPLACED (matched by name)
            - name: EXTRA
              value: added-by-patch          <- ADDED
```

**The patch named two variables and the result has both** — `env` merges by
`name` (30.5). Had the base carried a third variable, it would still be there.

And the container itself was modified, not duplicated:

```bash
kubectl kustomize solution/patch-demos | awk '/name: web$/,/^---/' | grep -c "image:"
```

### Step 2: The same mechanism adds, deletes and replaces

```bash
cat solution/patch-demos/02-add-container.yaml
cat solution/patch-demos/03-delete-container.yaml
kubectl kustomize solution/patch-demos | awk '/kind: Deployment/,/^---/' | grep "  - name:"
```

Two patches ran against `api`: one added `log-shipper`, the other deleted
`legacy-sidecar`. **Both were strategic merge patches and the only difference is
`$patch: delete`** (30.5).

Now the third directive, which needs its own kustomization because it would
fight with the other two:

```bash
TMP=$(mktemp -d) && cp -r solution/patch-demos "$TMP/d"
cp "$TMP/d/kustomization-replace.yaml" "$TMP/d/kustomization.yaml"
kubectl kustomize "$TMP/d" | awk '/name: api$/,/^---/' | grep "  - name:"
rm -rf "$TMP"
```

```
  - name: only-this-one
```

**`$patch: replace` discarded the base's entire container list.** Compare with
Step 2's merge, which kept everything it did not mention. Choosing between them
is choosing whether the base may keep evolving underneath you.

### Step 3: JSON 6902

```bash
cat solution/patch-demos/05-json6902.yaml
kubectl kustomize solution/patch-demos | awk '/name: web$/,/^---/' | grep -E "replicas:|ADDED_BY|patched-by"
```

Four operations, and each shows something a strategic merge patch cannot do
neatly (30.6):

- **`/env/-` appended.** With `/env/0` it would have replaced the first element.
- **`remove /containers/1` deleted by position**, not by name.
- **`example.com~1patched-by`** — the `~1` is an escaped `/`, and the preceding
  `add /metadata/annotations {}` exists because **`add` fails if the parent path
  is missing**.

Try that last point yourself:

```bash
TMP=$(mktemp -d) && cp -r solution/patch-demos "$TMP/d"
sed -i '/path: \/metadata\/annotations$/,+1d' "$TMP/d/05-json6902.yaml"
kubectl kustomize "$TMP/d" 2>&1 | tail -3
rm -rf "$TMP"
```

```
add operation does not apply: doc is missing path: "/metadata/annotations/..."
```

### Step 4: One patch, many targets

```bash
kubectl kustomize solution/patch-demos | grep -c "patched-by-label-selector"
```

```
2
```

**One inline patch reached both Deployments** via
`labelSelector: "tier in (frontend,backend)"` (30.3). Note that the
`metadata.name` inside that patch says `ignored-because-target-wins` and it made
no difference — **when `target:` is present, it decides.**

Confirm the silent-failure trap:

```bash
TMP=$(mktemp -d) && cp -r solution/patch-demos "$TMP/d"
sed -i 's/tier in (frontend,backend)/tier=nonexistent/' "$TMP/d/kustomization.yaml"
kubectl kustomize "$TMP/d" | grep -c "patched-by-label-selector"
rm -rf "$TMP"
```

```
0
```

**No error, no warning, no output.** A patch that matches nothing is silently
ignored — which is why `diff` against the base is the only reliable check.

### Step 5: Two overlays from one base

```bash
kubectl kustomize solution/overlays/dev  | grep -E "^kind:|^  name:|namespace:"
kubectl kustomize solution/overlays/prod | grep -E "^kind:|^  name:|namespace:"
```

Different namespaces, different prefixes, different object counts. See exactly
how they differ:

```bash
diff <(kubectl kustomize solution/overlays/dev) <(kubectl kustomize solution/overlays/prod) | head -50
```

```bash
kubectl kustomize solution/overlays/dev  | grep -c "^kind:"
kubectl kustomize solution/overlays/prod | grep -c "^kind:"
```

**prod renders more objects than dev**, because it includes a second component
(30.8).

### Step 6: Components are opt-in features

```bash
cat solution/components/external-db/kustomization.yaml
```

Note `apiVersion: kustomize.config.k8s.io/v1alpha1` and `kind: Component` —
**both different from a Kustomization** (30.8).

Both overlays include `external-db`, so both get Postgres **and** the patch that
tells the API about it:

```bash
for env in dev prod; do
  echo "== $env"
  kubectl kustomize "solution/overlays/$env" | grep -E "name: (dev|prod)-postgres$"
  kubectl kustomize "solution/overlays/$env" | grep -A2 "name: DB_HOST"
done
```

**The component added a Deployment and modified an object it does not own.**
That is what makes it a feature rather than a folder of manifests.

Only prod includes `monitoring`:

```bash
kubectl kustomize solution/overlays/dev  | grep -c "metrics-exporter"
kubectl kustomize solution/overlays/prod | grep -c "metrics-exporter"
```

```
0
3
```

**Three**, because `monitoring` targets `name: ".*"` and prod has three
Deployments by the time it runs — `web`, `api` **and the `postgres` that
`external-db` added first** (30.8).

Prove the ordering claim by swapping the components:

```bash
TMP=$(mktemp -d) && cp -r solution "$TMP/s"
python - "$TMP/s/overlays/prod/kustomization.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  - ../../components/external-db\n  - ../../components/monitoring\n",
              "  - ../../components/monitoring\n  - ../../components/external-db\n")
open(p, "w", newline="\n").write(s)
PY
kubectl kustomize "$TMP/s/overlays/prod" | grep -c "metrics-exporter"
rm -rf "$TMP"
```

```
2
```

**Two, not three.** With `monitoring` first, `postgres` did not exist yet, so the
`.*` target never saw it. **Component order is significant**, and this is the
kind of difference that is invisible until something is missing from a
dashboard.

### Step 7: Apply them

```bash
kubectl create namespace cka30-dev
kubectl create namespace cka30-prod

kubectl diff -k solution/overlays/dev | head -20
kubectl apply -k solution/overlays/dev
kubectl apply -k solution/overlays/prod

kubectl get deploy,svc -n cka30-dev
kubectl get deploy,svc -n cka30-prod
```

**One base, two environments, no duplicated manifests.** And because the objects
are prefixed and namespaced, they coexist without any coordination.

### Cleanup

```bash
kubectl delete -k solution/overlays/dev --ignore-not-found
kubectl delete -k solution/overlays/prod --ignore-not-found
kubectl delete namespace cka30-dev cka30-prod --ignore-not-found
```

---

## Part 3 - Challenges

### C1 - Pick the patch type

For each change, say which patch type you would use and write it:

1. Change a Deployment's replica count.
2. Add an environment variable to one container without disturbing the others.
3. Remove the **second** container from a pod spec, whatever it is called.
4. Add an annotation whose key is `example.com/team`.
5. Replace a CRD's `spec.forProvider.tags` list entirely.
6. Add a `tolerations` entry to every Deployment with `tier=backend`.

### C2 - Predict the merge

Base:

```yaml
    containers:
      - name: app
        image: nginx:1.27
        env:
          - {name: A, value: "1"}
          - {name: B, value: "2"}
        ports:
          - {containerPort: 80}
```

Patch:

```yaml
    containers:
      - name: app
        env:
          - {name: B, value: "changed"}
          - {name: C, value: "3"}
        ports:
          - {containerPort: 443}
```

1. What is the final `env` list?
2. What is the final `ports` list?
3. What image does the container have?
4. Change the patch so `env` ends up containing **only** `C`.

### C3 - Overlay or component

Classify each and say why:

1. prod runs 5 replicas; dev runs 1.
2. Some environments need an external Redis; some use an in-process cache.
3. prod objects go in the `production` namespace.
4. Any environment may optionally enable request tracing, which needs a sidecar
   and two environment variables.
5. staging uses a different container registry.

Then say what you would do about a requirement that is *genuinely* conditional
on a value rather than on which overlay is being built.

### C4 - Debug a patch that does nothing

`kubectl apply -k overlays/prod` succeeds and the change is absent from the
cluster.

1. Give the first command you would run, and why it beats looking at the
   cluster.
2. List five reasons a patch silently matches nothing.
3. How would you make this failure loud in CI?

### C5 - Design the repository

Design the Kustomize layout for: 3 environments (dev, staging, prod), 2 regions
in prod (`eu`, `us`) that differ only in a hostname and a node selector, and two
optional features (external database, tracing).

1. Draw the directory tree.
2. Say what is in each `kustomization.yaml`.
3. Give the command that deploys prod-eu.
4. Which parts stack, and what is the risk of stacking too deep?

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Runs without a cluster. Checks: the base renders four objects; strategic merge
modifies rather than duplicates a container and merges `env` by name;
`$patch: delete` removes one and `$patch: replace` discards the list; the JSON
6902 patch appends with `-`, removes by index and escapes `~1`; a label-selector
target hits two Deployments; both overlays build with different namespaces and
prefixes; the `external-db` component adds Postgres **and** patches `api`; and
`monitoring` reaches three Deployments in prod but zero in dev.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# render, diff against the base, diff against the cluster
kubectl kustomize overlays/prod
diff <(kubectl kustomize base) <(kubectl kustomize overlays/prod)
kubectl diff -k overlays/prod
kubectl apply -k overlays/prod

# the modern patch field, both types, both forms
patches:
  - path: patch.yaml                       # strategic merge, target from the file
  - path: ops.yaml                         # JSON 6902 -- needs an explicit target
    target: {kind: Deployment, name: web}
  - target: {kind: Deployment, labelSelector: "tier=backend"}
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 3

# the two strategic-merge directives
$patch: delete       # remove a list element
$patch: replace      # discard the base's list

# JSON 6902 essentials
/spec/template/spec/containers/0/env/-        # append
/spec/template/spec/containers/1              # by index
/metadata/annotations/example.com~1team       # ~1 is an escaped /
```

**Traps**

- **A patch that matches nothing is silently ignored.** Always `diff` against the
  base.
- **`target:` overrides the `metadata.name` inside a strategic merge patch**, and
  `name` is a **regex**.
- **A JSON 6902 patch always needs a `target:`** — the file has no `kind` or
  `name`.
- **Lists merge by key**: containers by `name`, ports by `containerPort`, env by
  `name`.
- **Omitting a list element means "leave it alone".** Deleting one needs
  `$patch: delete`.
- **`op: add` fails if the parent path does not exist.** Create the map first.
- **`-` appends; an index replaces.**
- **`~1` escapes `/` and `~0` escapes `~`** in JSON 6902 paths.
- **Components use `apiVersion: kustomize.config.k8s.io/v1alpha1` and
  `kind: Component`** — not `Kustomization`.
- **Components apply in order, after `resources`**, and a later component's
  wildcard target sees what earlier ones added.
- **`patchesStrategicMerge` and `patchesJson6902` are deprecated** in favour of
  `patches`.
- **Overlays stack**, because an overlay is just a kustomization with a base.

---

**Previous:** [CKA 29 — Kustomize: Structure and Transformers](../29-kustomize-structure-transformers/)
**Next: CKA 31 — Troubleshooting: Three Failure Domains** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
