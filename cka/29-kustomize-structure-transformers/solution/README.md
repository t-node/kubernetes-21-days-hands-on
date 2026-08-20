# CKA 29 solution

## Challenge answers

### C1 - Structure a real application

**1. The layout:**

```
  k8s/
    kustomization.yaml         resources: [payments, orders, catalog, users, shared]
    payments/
      kustomization.yaml       resources: [deployment.yaml, service.yaml, hpa.yaml]
      deployment.yaml
      service.yaml
      hpa.yaml
    orders/      ...same shape
    catalog/     ...
    users/       ...
    shared/
      kustomization.yaml       resources: [ingress.yaml, configmap.yaml, secrets.yaml]
      ingress.yaml
      configmap.yaml
      secrets.yaml
```

The root is five lines of `resources`; each service directory is three. **No file
lists more than a handful of things**, which is the whole objective (29.5).

**2. The shared Ingress goes in `shared/`, not in a service's directory.**

Because it **references all four Services**. Put it in `payments/` and
`kubectl kustomize k8s/payments` renders an Ingress with three backends that do
not exist in that build — the directory is no longer independently valid, which
was the reason for the structure in the first place.

The general rule: **an object belongs to the directory it can be rendered
without breaking.** Anything spanning components belongs one level up.

(An alternative that scales better once there are twenty services: give each
service its own Ingress with its own host or path prefix, so nothing is shared
at all. That is usually the better design, and it is worth proposing before
accepting the shared object.)

**3. Rendering one service:**

```bash
kubectl kustomize k8s/payments
```

**4. What this gives you that a flat directory does not:**

- **Reviewable ownership.** A change to `payments/` touches files no other team
  owns. On GitHub, a `CODEOWNERS` entry per directory is now possible; with a
  flat layout every change touches the same directory and the same reviewers.
- **Independent verification.** CI can run `kubectl kustomize k8s/payments` for
  the payments team's PR and render the whole tree only on merge. A flat layout
  forces every check to be all-or-nothing.
- **A blast radius you can see.** `kustomize build k8s/payments | kubectl diff -f -`
  answers "what does this change actually do" for one service.
- **Transformers scoped where they belong.** A `namePrefix` inside
  `payments/kustomization.yaml` affects only that service; in a flat directory
  every transformer is global whether or not you meant it to be.

### C2 - Predict the output

**1. `stg-web`.** `namePrefix: stg-` renames it; the `namespace` moves it but
does not affect the name.

**2. `myregistry.io/nginx:1.25`** — on **both** Deployments, because `images`
matches the **image name** `nginx` wherever it appears (29.6), and both
containers use it. Nothing named either Deployment.

**3. `web` ends up with 2 replicas — the base's value. The `replicas`
transformer did nothing.**

Because **`replicas` matches the object's name *before* `namePrefix` is
applied**. The kustomization says `name: stg-web`, but at the moment the replica
transformer runs, the object is still called `web`. There is no object named
`stg-web` for it to match, so it silently matches nothing.

**And that is the trap: no error.** Kustomize does not warn that a `replicas`
entry matched no object. The build succeeds, the output looks plausible, and the
replica count is wrong. The same applies to `images` and to patch targets.

**4. The fix — use the pre-prefix name:**

```yaml
replicas:
  - name: web
    count: 3
```

**How to catch this class of bug generally:** render and grep, every time.

```bash
kubectl kustomize overlays/staging | grep -B5 "replicas:"
diff <(kubectl kustomize base) <(kubectl kustomize overlays/staging)
```

**If a transformer produced no diff, it matched nothing.**

### C3 - The ConfigMap that will not update

**1. The mechanism they removed.**

The **content hash suffix** (29.7). Kustomize appends a hash of the ConfigMap's
content to its name and rewrites every reference to match. A config change
therefore changes the ConfigMap's *name*, which changes the Deployment's
`configMapRef`, which changes the pod template — **and a changed pod template is
what makes a Deployment roll.**

With `disableNameSuffixHash: true` the name is fixed. The ConfigMap's contents
are updated in place, the Deployment is byte-for-byte identical, and the
controller has no reason to do anything. **New value in etcd, old value in the
running processes** — exactly the failure from [CKA 28](../../28-helm/) C2,
reached by a different route.

**2. Three ways to make the pods pick it up, ranked:**

**Best — turn the hash back on.** Delete `disableNameSuffixHash: true`. It is
automatic, correct on every future change, and needs nobody to remember
anything. The "confusing random names" objection is answered by the fact that
nothing should ever reference those names by hand — Kustomize rewrites the
references for you.

**Second — a rollout restart, in the deploy pipeline:**

```bash
kubectl rollout restart deployment/web
```

Correct but manual, and it will be forgotten. Acceptable only if it is a scripted
step immediately after `apply -k`, never a human's responsibility.

**Third — an annotation you maintain yourself:**

```yaml
    metadata:
      annotations:
        config-revision: "2024-08-20-a"
```

This is the Helm `checksum/config` pattern done by hand, and it is worse than
Helm's because nothing computes it — someone must remember to bump it, and the
failure mode when they forget is silence.

**3. When `disableNameSuffixHash: true` is right:**

- **Something outside this kustomization references the ConfigMap by a fixed
  name** — another team's manifest, a CRD's `spec.configMapName`, a Helm chart's
  values, an operator that looks up `app-config` literally.
- **The consumer watches for changes itself.** An application that reloads its
  configuration on file change (or a sidecar doing it) does not need a restart,
  so the hash buys nothing and costs orphaned objects.
- **A ConfigMap referenced by name in a `kubectl` command or a runbook** that you
  cannot change.

In every case, note that you have **taken on the restart responsibility
yourself** and should write down how it happens.

**4. The cost of leaving the hash on.**

**Old ConfigMaps accumulate and nothing removes them** (29.7):

```bash
kubectl get cm | grep app-config
```

Every config change leaves the previous one behind. That is deliberate — a
rollback needs the old object to still exist — but over a year of daily deploys
it is hundreds of dead ConfigMaps in a namespace, cluttering `kubectl get cm` and
consuming a small amount of etcd.

The mitigations, in order of preference: `kubectl apply -k --prune` with a
label selector (powerful and easy to get wrong — test it on a scratch
namespace); a GitOps tool such as Argo CD, which prunes what is no longer
rendered; or a periodic sweep of unreferenced ConfigMaps.

**None of that is a reason to disable the hash.** Clutter is a smaller problem
than pods silently serving stale configuration.

### C4 - Kustomize or Helm

| # | Case | Choice | Why |
|---|---|---|---|
| 1 | Installing Prometheus | **Helm** | it is someone else's software, versioned and distributed as a chart -- that is exactly what a package manager is for |
| 2 | 12 internal services across 3 environments | **Kustomize** | you own the YAML, it stays readable, and the per-environment differences are small and declarative |
| 3 | A manifest in prod but not dev | **Kustomize components**, or Helm | Kustomize has no `if`; the answer is a `component` you include only in prod (CKA 30). Without components, this is where Helm wins |
| 4 | Shipping an operator to customers | **Helm** | customers need versions, an upgrade path, and values they can set without reading your directory layout |
| 5 | Patching one field of an unforkable chart | **both** | render the chart with `helmCharts:` in a kustomization and patch the output |

**Number 5 is the pattern worth remembering.** You want a chart's maintained
templates and one change its values do not expose:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: some-chart
    repo: https://charts.example.com
    version: 1.4.2
    releaseName: app
    valuesInline:
      replicaCount: 3
patches:
  - path: add-the-field-values-do-not-expose.yaml
    target: {kind: Deployment, name: app-some-chart}
```

This is strictly better than forking: chart upgrades are a version bump, and your
change is one visible file. It needs `--enable-helm` and the standalone
`kustomize` binary, not `kubectl -k`.

**Number 3 is the honest boundary.** Kustomize cannot express "sometimes".
`components` (CKA 30) cover the common case — an opt-in bundle of extra
resources — but anything genuinely conditional on a *value* rather than on which
overlay you built is outside what Kustomize does, and reaching for Helm there is
not a defeat.

### C5 - Migrate a chart to Kustomize

**1. What becomes the base, and how to produce it.**

**Render the chart with its default values and keep the output.**

```bash
helm template myapp ./mychart > base/all.yaml
# then split it into one file per object
```

That output is plain, valid, applicable YAML — exactly what a base is (29.1). Do
not hand-convert the templates; render them, because the render is the ground
truth about what the chart actually produces.

Then split `all.yaml` into `deployment.yaml`, `service.yaml`, `configmap.yaml`
and so on, and give each a `kustomization.yaml`, following C1's structure.

**One decision to make deliberately: which values become the base.** Render with
the *most common* environment's values, not the defaults, so most overlays have
the least to say.

**2. Direct equivalents:**

| Chart feature | Kustomize |
|---|---|
| `values.yaml` defaults | the base's literal values |
| `-f values-prod.yaml` | an overlay directory |
| `--set image.tag=x` | the `images` transformer |
| `--set replicaCount=n` | the `replicas` transformer |
| `.Release.Namespace` | the `namespace` transformer |
| `fullname` prefixing | `namePrefix` |
| `labels` / `commonLabels` helpers | the `labels` transformer |
| **`checksum/config`** | **the generator hash, automatically** (29.7) |
| arbitrary field changes | patches (CKA 30) |

**Note the checksum row.** The chart needed a hand-written annotation to make
pods roll on a config change; Kustomize does it by construction. That is a
genuine improvement, not a workaround.

**3. What has no equivalent, and what to do:**

| Chart feature | What you do |
|---|---|
| **`{{ if .Values.ingress.enabled }}`** | a **component** (CKA 30) included only by the overlays that want it |
| **`{{ range .Values.extraEnv }}`** | write the list out literally in each overlay, or patch it |
| **`required`** | nothing -- Kustomize has no validation hook. Use a CI check, or admission policy ([CKA 07](../../07-admission-controllers/)) |
| **`_helpers.tpl` computed names** | literal names plus `namePrefix` |
| **hooks** (pre-install jobs, etc.) | a separate `kubectl apply` step, or an operator |
| **`helm rollback`** | Git revert plus `apply -k` -- see below |
| **packaging and versioning** | Git tags, or an OCI artefact if you must distribute it |

**The `range` row is the one that hurts most in practice.** A chart that
generates N similar objects from a list has no Kustomize equivalent, and the
answer is either writing them out (fine for 3, awful for 30) or accepting that
this application should stay on Helm.

**4. What you lose, and whether it is worth it.**

**You lose:**

- **Release tracking.** No `helm list`, no `helm history`, no record of what is
  deployed. `kubectl get -o yaml` is the only source of truth.
- **`helm rollback`.** The replacement is `git revert` plus `kubectl apply -k`,
  which is arguably better — the change is reviewable and the history is in Git —
  but it is not one command, and it does nothing about data
  ([CKA 28](../../28-helm/) C5) in either tool.
- **Distribution.** Nobody can `helm install` your application.
- **Conditionals**, as above.

**You gain:**

- **Files anyone can read** without rendering them first.
- **Nothing to install** — `kubectl apply -k` works everywhere (29.3).
- **The generator hash** instead of a remembered annotation.
- **Real diffs.** `kubectl diff -k` against the cluster, and `git diff` between
  overlays, both show actual YAML rather than template changes whose effect you
  must infer.

**Is it worth it?** For **12 internal services deployed by one organisation
(C4.2), yes** — none of what you lose matters when Git is the source of truth and
nobody outside the company installs your software.

For **anything you distribute, no.** Rewriting a chart your customers already
know how to configure, to gain readability they will never see, is a poor trade.

**And there is a third answer worth stating: do not migrate a working chart
without a reason.** "Kustomize is simpler" is not a reason on its own — the
migration costs weeks and introduces new failure modes (C2's silent
non-matching transformers among them). Migrate when the chart has become
unreadable, when nobody can safely change it, or when you keep needing to patch
around it.

---

## Files

| Path | Purpose |
|---|---|
| `base/kustomization.yaml` | the root: three directories plus a `configMapGenerator` |
| `base/api/`, `base/web/`, `base/db/` | one kustomization each -- independently buildable (29.5) |
| `base/settings.conf` | a file the generator reads, so `files:` changes move the hash too |
| `transformers/` | every common transformer at once, numbered to match 29.6 |
| `safe-labels/` | a changing label with `includeSelectors: false` |
| `unsafe-labels-BAD/` | the same label with `includeSelectors: true` -- breaks on the second apply |
| `verify.sh` | mostly runs without a cluster |

**The base contains cross-object references on purpose** — `api`'s `DB_HOST`,
`web`'s `API_URL` inside a URL string, and `db`'s `serviceName`. Step 4 of the
lab exists to show all three being rewritten by `namePrefix`, because that is
the behaviour that distinguishes Kustomize from `sed` and it is invisible unless
the references are there to rewrite.

---

## On `unsafe-labels-BAD`

It is the only file in this assignment that damages the cluster, and it does so
on the **second** apply, not the first — which is precisely why it is worth
doing.

```yaml
labels:
  - pairs:
      build: "0001"
    includeSelectors: true
```

The first `kubectl apply -k` succeeds and everything looks correct. Change
`0001` to `0002` and:

```
The Deployment "web" is invalid: spec.selector: Invalid value:
v1.LabelSelector{...}: field is immutable
```

**Every subsequent apply fails, and deleting the Deployment is the only fix.**
On a production Deployment that means an outage to repair a labelling decision.

The deprecated `commonLabels` field behaves exactly this way with **no way to opt
out**, which is why it was replaced by `labels:` with an explicit
`includeSelectors`. If you inherit a kustomization using `commonLabels`, check
what it puts in there before changing any of the values.

**The general rule, and it is the same one as [CKA 28](../../28-helm/)'s
`selectorLabels`:** a selector may contain only values that are fixed for the
life of the object. Everything else — versions, build numbers, environments,
deploy timestamps — goes on the object and stays out of the selector.
