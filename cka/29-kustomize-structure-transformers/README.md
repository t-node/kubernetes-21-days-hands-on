# CKA 29 — Kustomize: Structure and Transformers

**Time:** 90-110 minutes
**Prerequisites:** [CKA 04](../04-imperative-declarative-and-apply/), [CKA 28](../28-helm/), [Day 09](../../days/day-09-configmaps/)
**Source lectures:** 261, 262, 263, 264, 265, 266, 267, 268, 270, 271, 272

[CKA 28](../28-helm/) solved "the same app in three environments" with
templating. Kustomize solves it a different way: **no templates at all.** The
files stay plain Kubernetes YAML, and changes are expressed as declarative
overlays on top of them.

This assignment covers structure and transformers. **CKA 30** covers patches,
overlays and components.

---

## Part 1 - Concepts

### 29.1 The idea: plain YAML, modified declaratively

```
   base/          plain, valid, applicable Kubernetes manifests
     |
     |  kustomization.yaml says WHAT to change
     v
   kustomize build  ->  modified manifests  ->  kubectl apply
```

**Nothing in a base is templated.** Every file in it is something you could
`kubectl apply` on its own, so your editor's YAML support, `kubectl explain` and
schema validation all work on it normally.

That is the design argument, and it is a real one: a Helm chart's templates are
**not valid YAML** — they are Go templating that happens to produce YAML — so a
large chart is hard to read and hard to reason about without rendering it first.

**The cost is expressive power.** No conditionals, no loops, no functions, no
hooks. If a value must be computed, Kustomize cannot compute it.

### 29.2 Kustomize or Helm

| | **Kustomize** | **Helm** |
|---|---|---|
| Mechanism | overlay plain YAML | render Go templates |
| Files are valid YAML | **yes** | no |
| Conditionals / loops / functions | **no** | yes |
| Packaging and distribution | no | **yes** -- charts, repositories, versions |
| Release tracking and rollback | **no** | yes |
| Needs installing | **no** -- built into kubectl | yes |

**They are not competitors so much as different jobs.** Helm is a *package
manager*, and its real value is distributing software you did not write.
Kustomize is a *configuration tool* for software you did.

**Most clusters use both**: Helm to install Prometheus and cert-manager,
Kustomize for the company's own applications. Kustomize can also consume a
rendered chart as a base (`helmCharts:` in newer versions), which is how teams
patch a third-party chart without forking it.

> Choosing for a new project: **Kustomize until you need conditionals.** The
> moment a manifest must exist in staging and not in prod, you reach for Helm —
> or for Kustomize `components`, which is CKA 30.

### 29.3 It is already installed

```bash
kubectl kustomize ./base           # render to stdout
kubectl apply -k ./base            # render and apply
kubectl diff -k ./base             # render and diff against the cluster
```

**`-k` is to Kustomize what `-f` is to a file.** No installation, no plugin.

The standalone binary is newer than the embedded one:

```bash
kustomize build ./base | kubectl apply -f -
```

**The embedded version lags**, sometimes by a year. If a documented field is
rejected by `kubectl kustomize`, that is usually why — check with the standalone
binary before assuming you wrote it wrong.

### 29.4 `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ../db                    # a DIRECTORY containing another kustomization.yaml

namespace: production
namePrefix: prod-
nameSuffix: -v2

labels:
  - pairs:
      app.kubernetes.io/part-of: shop
    includeSelectors: false

commonAnnotations:
  owner: platform-team

images:
  - name: nginx
    newName: haproxy
    newTag: "2.4"

replicas:
  - name: web
    count: 5

configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=info
```

**`resources` is the only required field.** Everything else modifies what those
resources produce.

**An entry in `resources` may be a file or a directory.** A directory must
contain its own `kustomization.yaml` — that is how a large tree stays readable.

### 29.5 Directory structure is the point

A single `kustomization.yaml` listing two hundred files is technically valid and
unusable. The pattern:

```
  k8s/
    kustomization.yaml          resources: [api, web, db]
    api/
      kustomization.yaml        resources: [deployment.yaml, service.yaml]
      deployment.yaml
      service.yaml
    web/
      kustomization.yaml
      ...
    db/
      kustomization.yaml
      ...
```

```bash
kubectl kustomize k8s/           # everything
kubectl kustomize k8s/api        # just the api component
```

**Each directory is independently buildable**, and therefore independently
testable and reviewable. `kubectl kustomize k8s/api` is how you check one team's
change without rendering the whole estate.

**Transformers apply to everything the kustomization pulls in**, including
resources from subdirectories. A `namespace:` in the root applies to all of
them; a `namePrefix:` inside `api/` applies only to the api objects.

### 29.6 Transformers

The five you will use constantly:

| Field | Does |
|---|---|
| **`namespace`** | sets `metadata.namespace` on everything |
| **`namePrefix` / `nameSuffix`** | renames every object **and updates references to them** |
| **`labels`** | adds labels; `includeSelectors` decides whether selectors get them too |
| **`commonAnnotations`** | adds annotations to everything |
| **`images`** | rewrites image names and tags wherever they appear |

**`namePrefix` updating references is the feature that makes it safe.** Rename a
Service to `prod-api` and every environment variable, Ingress backend and
`serviceName` that pointed at `api` is rewritten to match — Kustomize knows which
fields are references.

**`images` matches on the image *name*, not the container name** — a distinction
that catches everyone:

```yaml
images:
  - name: nginx           # matches any container whose image is `nginx:*`
    newTag: "1.27-alpine"
```

You can change the name, the tag, or both; `newTag` alone is the common case for
promoting a build.

> **`commonLabels` is the old field and is deprecated.** It always wrote into
> selectors, which is dangerous (below). The replacement is `labels:` with an
> explicit `includeSelectors`. `commonLabels` still works in the version embedded
> in `kubectl`, and you will meet both.

**The selector trap, which is the same one as [CKA 28](../28-helm/):**

A Deployment's `spec.selector` is **immutable**. A transformer that writes into
selectors is fine on the first `apply` and **fails forever afterwards** if the
label's value ever changes:

```
The Deployment "web" is invalid: spec.selector: Invalid value: ...: field is immutable
```

**Use `includeSelectors: false` for anything that varies** — a version, a build
number, an environment name. Reserve selector labels for values fixed for the
life of the object.

### 29.7 Generators, and the hash suffix

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=info
    files:
      - settings.conf

secretGenerator:
  - name: db-creds
    literals:
      - password=hunter2
```

These **create** objects rather than transforming them, and they do something
clever:

```bash
kubectl kustomize . | grep "name: app-config"
```

```
  name: app-config-9f8hg7d4kt
```

**A hash of the content is appended to the name, and every reference to it is
rewritten to match.** Change a literal and the name changes, so the Deployment's
`configMapRef` changes, so the pod template changes, so **the Deployment rolls
automatically**.

**That is Kustomize's answer to the problem [CKA 28](../28-helm/) solved with a
`checksum/config` annotation** — and it is the better answer, because it is
automatic rather than something the chart author must remember.

It also leaves the old ConfigMap behind:

```
app-config-9f8hg7d4kt   # the current one
app-config-b2k4m8x1qc   # the previous one, still there
```

**Nothing cleans those up**, which is deliberate — a rollback needs the old one to
exist. `kubectl apply -k --prune` can, with care.

Turn the hash off if you must:

```yaml
generatorOptions:
  disableNameSuffixHash: true
```

**That reintroduces the stale-pod problem**, so do it only for a ConfigMap
something else references by a fixed name.

> **`secretGenerator` puts the value in your Git repository.** It is base64 in
> the output and plaintext in the kustomization. For anything real, use `files:`
> pointing at something excluded from Git, or a proper secret store
> ([Day 10](../../days/day-10-secrets/)).

### 29.8 Building, diffing, applying

```bash
kubectl kustomize ./base                 # render, change nothing
kubectl apply -k ./base
kubectl diff -k ./base                   # what WOULD change
kubectl delete -k ./base
```

**`kubectl diff -k` before `apply -k` is the habit worth forming.** It renders
locally and compares against the live cluster — the safest possible preview, and
the exact analogue of `helm template` plus `helm get manifest`.

---

## Part 2 - Hands-on lab

```bash
kubectl version --client
kubectl kustomize --help | head -5
```

Nothing to install (29.3).

```bash
kubectl create namespace cka29
kubectl config set-context --current --namespace=cka29
find solution/base -type f | sort
```

### Step 1: A base is just Kubernetes YAML

```bash
cat solution/base/api/deployment.yaml
kubectl apply -f solution/base/api/deployment.yaml --dry-run=server
```

**It applies on its own.** No rendering step, no placeholder values, no tool
required to read it (29.1). Compare with a Helm template from
[CKA 28](../28-helm/):

```bash
head -12 ../28-helm/solution/mychart/templates/deployment.yaml
```

One of those two files is valid YAML and one is not.

### Step 2: Build each directory independently

```bash
kubectl kustomize solution/base/api
kubectl kustomize solution/base/db
```

**Each subdirectory renders on its own** (29.5), because each has its own
`kustomization.yaml`. Now the root:

```bash
kubectl kustomize solution/base | grep -E "^kind:|^  name:"
```

```
kind: ConfigMap
  name: app-config-4b6mt7hg2c
kind: Service
  name: api
kind: Service
  name: db
kind: Service
  name: web
kind: Deployment
  name: api
kind: Deployment
  name: web
kind: StatefulSet
  name: db
```

**Seven objects from three directories plus a generator**, and the root
`kustomization.yaml` is nine lines long.

### Step 3: The generated ConfigMap and its hash

```bash
kubectl kustomize solution/base | grep -A6 "kind: ConfigMap"
kubectl kustomize solution/base | grep -B2 -A2 "configMapRef"
```

```
  name: app-config-4b6mt7hg2c
...
            - configMapRef:
                name: app-config-4b6mt7hg2c
```

**The reference was rewritten to the hashed name** (29.7). Now change one
character of the content and watch every affected name move together:

```bash
kubectl kustomize solution/base | grep "app-config-" | sort -u
sed -i 's/GREETING=hello-from-base/GREETING=hello-CHANGED/' solution/base/kustomization.yaml
kubectl kustomize solution/base | grep "app-config-" | sort -u
```

**A different hash, in both places.** The `web` Deployment's pod template
therefore changed, so applying this rolls the pods automatically — the thing a
Helm chart needs a `checksum/config` annotation to achieve
([CKA 28](../28-helm/), 28.5).

Prove the `files:` source counts too:

```bash
sed -i 's/timeout=30/timeout=60/' solution/base/settings.conf
kubectl kustomize solution/base | grep "app-config-" | sort -u
```

Put both back:

```bash
sed -i 's/GREETING=hello-CHANGED/GREETING=hello-from-base/' solution/base/kustomization.yaml
sed -i 's/timeout=60/timeout=30/' solution/base/settings.conf
```

### Step 4: Every transformer at once

```bash
cat solution/transformers/kustomization.yaml
diff <(kubectl kustomize solution/base) <(kubectl kustomize solution/transformers) | head -60
```

Read the diff against the six numbered comments in that file. The interesting
parts:

```bash
kubectl kustomize solution/transformers | grep -E "^  name:|namespace:"
```

```
  name: prod-app-config-4b6mt7hg2c-v2
  namespace: cka29
  name: prod-api-v2
  name: prod-db-v2
  name: prod-web-v2
```

**Now the part that matters — every *reference* was rewritten too** (29.6):

```bash
kubectl kustomize solution/transformers | grep -E "DB_HOST|API_URL|serviceName" -A1
```

```
            - name: DB_HOST
              value: prod-db-v2
            - name: API_URL
              value: http://prod-api-v2:80
  serviceName: prod-db-v2
```

**Nothing in the base mentioned `prod-` or `-v2`.** Kustomize knows which fields
are references to other objects and rewrote all three — an environment variable,
a URL inside a string, and a StatefulSet's `serviceName`. **That is the feature
that makes renaming safe**, and it is why `namePrefix` is not the same as `sed`.

Check the image and replica transformers:

```bash
kubectl kustomize solution/transformers | grep -E "image:|replicas:"
```

```
  replicas: 2       <- api, untouched
  replicas: 4       <- web, from the `replicas:` transformer
  replicas: 1       <- db
          image: nginx:1.27.2-alpine    (x3)
```

**`images` matched the image name `nginx` in all three objects** without either
of them being named. The `replicas` transformer matched `web` by object name —
**the name before the prefix was applied**, which is the ordering people get
wrong.

### Step 5: The selector trap

```bash
diff solution/safe-labels/kustomization.yaml solution/unsafe-labels-BAD/kustomization.yaml
```

One word. See what it does to the output:

```bash
kubectl kustomize solution/safe-labels        | grep -A4 "matchLabels"
kubectl kustomize solution/unsafe-labels-BAD  | grep -A4 "matchLabels"
```

```
  selector:
    matchLabels:
      app: web                 <- safe

  selector:
    matchLabels:
      app: web
      build: "0001"            <- in the IMMUTABLE selector
```

Now break it for real. Apply the unsafe one, change the value, apply again:

```bash
kubectl apply -k solution/unsafe-labels-BAD
sed -i 's/build: "0001"/build: "0002"/' solution/unsafe-labels-BAD/kustomization.yaml
kubectl apply -k solution/unsafe-labels-BAD
```

```
The Deployment "web" is invalid: spec.selector: Invalid value:
v1.LabelSelector{...}: field is immutable
```

**Every future apply fails**, and it stays broken until the Deployment is
deleted. Now the safe version, with the same changing label:

```bash
kubectl delete -k solution/unsafe-labels-BAD --ignore-not-found
sed -i 's/build: "0002"/build: "0001"/' solution/unsafe-labels-BAD/kustomization.yaml

kubectl apply -k solution/safe-labels
sed -i 's/build: "0001"/build: "0002"/' solution/safe-labels/kustomization.yaml
kubectl apply -k solution/safe-labels
kubectl get deploy web -o jsonpath='{.metadata.labels.build}{"  selector="}{.spec.selector.matchLabels}{"\n"}'
```

**It applies cleanly every time**, and the label is still on the object where you
can select on it — just not in the immutable field (29.6).

```bash
sed -i 's/build: "0002"/build: "0001"/' solution/safe-labels/kustomization.yaml
kubectl delete -k solution/safe-labels --ignore-not-found
```

### Step 6: Diff before apply

```bash
kubectl apply -k solution/base
kubectl get all
```

Now change something and preview it:

```bash
kubectl diff -k solution/transformers | head -30
```

**`diff -k` renders locally and compares against the cluster** (29.8). It is the
Kustomize equivalent of `helm template` plus `helm get manifest`, in one command
and without installing anything.

```bash
kubectl apply -k solution/transformers
kubectl get all -n cka29
```

Note what happened: the base's objects are **still there**, and the transformed
ones were created alongside them under different names. **Kustomize has no
concept of a release** (29.2) — it renders manifests, and `kubectl apply` does
what it always does.

### Cleanup

```bash
kubectl delete -k solution/transformers --ignore-not-found
kubectl delete -k solution/base --ignore-not-found
kubectl delete namespace cka29 --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Structure a real application

An application has 4 microservices, each with a Deployment, a Service and an
HPA, plus a shared Ingress, a shared ConfigMap and two Secrets — 17 files.

1. Lay out the directories and say what each `kustomization.yaml` contains.
2. Where does the shared Ingress go, and why not inside a service's directory?
3. Give the command that renders **only** the `payments` service.
4. One team owns `payments`; another owns everything else. What does this layout
   give you that a flat directory does not?

### C2 - Predict the output

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [../base]
namespace: staging
namePrefix: stg-
images:
  - name: nginx
    newName: myregistry.io/nginx
    newTag: "1.25"
replicas:
  - name: stg-web
    count: 3
```

The base has Deployments `web` and `api`, both on `nginx:1.27-alpine`, `web` with
2 replicas.

1. What is the rendered name of the `web` Deployment?
2. What image do the containers get?
3. **How many replicas does `web` end up with, and why?**
4. Fix the mistake.

### C3 - The ConfigMap that will not update

A team disabled the name suffix hash because "the random names were confusing".
Now a config change updates the ConfigMap and the pods keep the old values.

1. Explain the mechanism they removed.
2. Give three ways to get the pods to pick up the change, and rank them.
3. When is `disableNameSuffixHash: true` actually the right call?
4. What is the cost of leaving the hash on?

### C4 - Kustomize or Helm

Choose for each, in one sentence:

1. Installing Prometheus into a new cluster.
2. Deploying your company's 12 internal services to dev/staging/prod.
3. A manifest that must exist in prod and not in dev.
4. Shipping an operator to customers who run their own clusters.
5. Patching one field of a third-party Helm chart you cannot fork.

### C5 - Migrate a chart to Kustomize

You inherit the chart from [CKA 28](../28-helm/). Convert it.

1. What becomes the base, and how do you produce it?
2. Which chart features have a direct Kustomize equivalent?
3. Which do not, and what do you do about each?
4. What do you lose, and is it worth it?

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Almost all of it runs without a cluster. Checks: every directory builds
independently; the root renders seven objects from three subdirectories; the
generated ConfigMap has a content hash and the `configMapRef` matches it;
changing a literal changes both; the transformers rename objects **and their
references**; `images` rewrites all three containers; `replicas` matches the
pre-prefix name; and `includeSelectors: false` keeps the changing label out of
`spec.selector` while `true` puts it in.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# render, diff, apply -- no installation needed
kubectl kustomize DIR
kubectl diff -k DIR
kubectl apply -k DIR
kubectl delete -k DIR

# the newer standalone binary, when kubectl's embedded one is too old
kustomize build DIR | kubectl apply -f -

# scaffold and edit from the command line
kustomize create --resources deployment.yaml,service.yaml
kustomize edit set image nginx=nginx:1.27.2
kustomize edit set namespace prod
kustomize edit add resource api

# see what a transformer did
diff <(kubectl kustomize base) <(kubectl kustomize overlays/prod)
kubectl kustomize DIR | grep -E "^kind:|^  name:"
```

The minimal file, from memory:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

**Traps**

- **`resources` is required**; a directory listed there must contain its own
  `kustomization.yaml`.
- **The file must be named `kustomization.yaml`** (or `kustomization.yml`, or
  `Kustomization`). Nothing else is found.
- **`namePrefix` rewrites references too** — that is the point, and it is why
  `sed` is not equivalent.
- **`replicas` and `images` match the name *before* `namePrefix` is applied.**
- **`images` matches the image name, not the container name.**
- **`includeSelectors: true` writes into an immutable field.** Use `false` for
  anything that changes.
- **`commonLabels` is deprecated** and always behaves like
  `includeSelectors: true`.
- **Generated ConfigMaps get a content hash** and every reference is rewritten —
  this is what makes pods roll on a config change.
- **Old generated ConfigMaps are never cleaned up.**
- **`secretGenerator` literals end up in Git.**
- **Kustomize has no releases, no history and no rollback.** It renders YAML;
  `kubectl apply` does the rest.
- **`kubectl`'s embedded Kustomize lags the standalone binary.**

---

**Previous:** [CKA 28 — Helm](../28-helm/)
**Next: CKA 30 — Kustomize: Patches, Overlays and Components** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
