# CKA 28 — Helm

**Time:** 100-120 minutes
**Prerequisites:** [CKA 04](../04-imperative-declarative-and-apply/), [Day 09](../../days/day-09-configmaps/), [Day 20](../../days/day-20-ingress-and-gateway-api/)
**Source lectures:** 250, 251, 253, 254, 255, 256, 257, 259

Every manifest in this repo so far has been a literal file. Helm is what you use
when the same application must be deployed five times with five different sets of
values — and it is how most third-party software is shipped to Kubernetes.

**You will install a chart, take its release apart, and then write one.**

---

## Part 1 - Concepts

### 28.1 The problem Helm solves

You have a Deployment, a Service, a ConfigMap and an Ingress. You need them in
`dev`, `staging` and `prod`, with different replica counts, hostnames and image
tags.

The options without Helm:

| Approach | Problem |
|---|---|
| three copies of the directory | they diverge; a fix lands in one of them |
| `sed` in a shell script | unreadable, untestable, and yours to maintain |
| one set of files edited by hand | no record of what differs, or why |

Helm's answer: **one templated package plus a values file per environment.**

```
   chart (templates + defaults)  +  values.yaml  ->  rendered manifests  ->  cluster
```

**And a second, bigger reason:** it is how software is distributed. Prometheus,
cert-manager, Argo CD, every database vendor — all ship a chart, and
`helm install` is how you get them.

### 28.2 Helm 3 is not Helm 2

If you meet older material, these are the differences that matter:

| | Helm 2 | Helm 3 |
|---|---|---|
| **Tiller** | a privileged in-cluster server that did everything | **gone.** The client talks to the API server directly |
| Permissions | Tiller's, usually cluster-admin | **yours**, from your kubeconfig -- RBAC applies normally |
| Release storage | ConfigMaps in `kube-system` | **Secrets in the release's own namespace** |
| Release names | cluster-wide unique | **unique per namespace** |
| Upgrade / rollback | compared old chart vs new chart | **three-way merge**: old chart, new chart, **and the live state** |

**The three-way merge is the same idea as `kubectl apply`**
([CKA 04](../04-imperative-declarative-and-apply/)). Helm 2 would silently
discard a change someone made with `kubectl edit`, because it was in neither
chart. Helm 3 sees the live object and preserves it.

> **Tiller's removal is the security story.** A cluster-admin daemon reachable by
> anyone with the Helm client was the worst thing about Helm 2.

### 28.3 Five nouns

| Term | Is |
|---|---|
| **Chart** | the package -- templates, defaults, metadata |
| **Values** | the parameters, from `values.yaml`, `-f` files and `--set` |
| **Release** | **one installation** of a chart, with a name |
| **Revision** | one version of a release; every change makes a new one |
| **Repository** | where charts are published |

**A release is not a chart.** Install the same chart twice with different names
and you get two independent releases, tracked and upgraded separately:

```bash
helm install site-a bitnami/wordpress
helm install site-b bitnami/wordpress
```

**Artifact Hub** (`artifacthub.io`) indexes charts from every repository. Prefer
charts with the *verified publisher* badge, and read what they deploy before
running them — **`helm install` is `kubectl apply` of somebody else's
manifests.**

### 28.4 What is inside a chart

```
mychart/
  Chart.yaml          metadata -- name, versions, dependencies
  values.yaml         the DEFAULT parameters
  templates/          the manifests, with Go templating
    deployment.yaml
    service.yaml
    _helpers.tpl      named templates; the underscore means "not a manifest"
    NOTES.txt         printed after install
  charts/             subcharts this one depends on
  .helmignore         what not to package
```

`Chart.yaml`:

```yaml
apiVersion: v2            # v2 = Helm 3. `v1` means the chart was built for Helm 2
name: mychart
version: 0.1.0            # the CHART's version -- bump it when the chart changes
appVersion: "1.27.0"      # the APPLICATION's version -- informational
type: application         # or `library`, for charts that only provide helpers
dependencies:
  - name: mariadb
    version: "18.x.x"
    repository: https://charts.bitnami.com/bitnami
```

**`version` and `appVersion` are different and both matter.** `version` tracks
the packaging; `appVersion` tracks what is packaged. Moving nginx 1.27.0 to
1.27.1 changes `appVersion`; fixing a typo in a template changes `version`.

**Files beginning with `_` are not rendered as manifests.** That is how
`_helpers.tpl` holds reusable snippets.

### 28.5 Templating, in the amount you need

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "mychart.fullname" . }}
  labels:
    {{- include "mychart.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          {{- if .Values.resources }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          {{- end }}
```

Four built-in objects supply everything:

| Object | Holds |
|---|---|
| **`.Values`** | the merged values |
| **`.Release`** | `.Name`, `.Namespace`, `.IsUpgrade`, `.Revision` |
| **`.Chart`** | everything in `Chart.yaml` |
| **`.Capabilities`** | the cluster's version and available API versions |

The functions you will actually use:

| | |
|---|---|
| `default` | `{{ .Values.tag \| default "latest" }}` |
| `quote` | force a string -- **essential for values like `"true"` or `8080`** |
| `toYaml` | render a whole values subtree as YAML |
| `nindent N` | newline + indent by N -- **almost always what you want, not `indent`** |
| `required` | fail the render with a message if a value is missing |
| `include` | call a named template, then pipe it through `nindent` |

**`{{-` and `-}}` trim whitespace**, and getting them wrong produces output that
is valid Go template output and invalid YAML. `helm template` shows you at once.

### 28.6 The commands

```bash
# repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo nginx
helm show values bitnami/nginx | head -40      # READ THIS BEFORE INSTALLING

# install and inspect
helm install myrel bitnami/nginx
helm install myrel bitnami/nginx --set replicaCount=3
helm install myrel bitnami/nginx -f prod-values.yaml
helm install myrel ./mychart --dry-run --debug   # render + validate, create nothing

# what did I actually get?
helm list -A
helm status myrel
helm get manifest myrel        # the rendered YAML
helm get values myrel          # the values that were supplied
helm get values myrel --all    # including every default

# lifecycle
helm upgrade myrel ./mychart --set replicaCount=5
helm history myrel
helm rollback myrel 1
helm uninstall myrel

# authoring
helm create mychart            # scaffolding
helm lint ./mychart
helm template myrel ./mychart  # render WITHOUT a cluster
```

**`helm template` and `helm install --dry-run` are not the same.** `template`
renders locally and needs no cluster; `--dry-run` sends the result to the API
server for validation and catches errors a local render cannot see. Use
`template` while writing, `--dry-run` before installing.

### 28.7 A release lives in a Secret

```bash
kubectl get secrets -l owner=helm
kubectl get secret sh.helm.release.v1.myrel.v1 -o jsonpath='{.type}{"\n"}'
```

```
sh.helm.release.v1.myrel.v1   helm.sh/release.v1
```

**One Secret per revision**, in the release's namespace, holding a
base64-gzipped record of the chart, the values and the rendered manifests. That
is the entire state — there is no Helm database and no server.

Two consequences:

- **Delete the Secrets and Helm forgets the release**, while the objects keep
  running. That is how a release becomes "unmanaged".
- **Anyone with `get secrets` in that namespace can read the values**, including
  any password passed with `--set`.

### 28.8 Revisions and rollback

```bash
helm history myrel
```

```
REVISION  UPDATED       STATUS      CHART        APP VERSION  DESCRIPTION
1         Mon Aug 18..  superseded  mychart-0.1  1.27.0       Install complete
2         Mon Aug 18..  superseded  mychart-0.2  1.27.1       Upgrade complete
3         Mon Aug 18..  deployed    mychart-0.1  1.27.0       Rollback to 1
```

**A rollback does not return you to revision 1 — it creates revision 3 holding
revision 1's content.** History is append-only, which is what makes it auditable
and what lets you roll *forward* out of a bad rollback.

Three flags worth knowing:

| Flag | Does |
|---|---|
| `--atomic` | roll back automatically if the upgrade fails |
| `--wait` | do not report success until the resources are Ready |
| `--timeout 5m` | how long `--wait` waits |

**`--atomic` implies `--wait`** and is what you want in CI.

### 28.9 What Helm does not do

| | |
|---|---|
| **Rollback does not restore data.** | It reverts *manifests*. A database's PV keeps whatever is in it -- roll a StatefulSet back and the pods return to their old spec with the new data. |
| **CRDs are installed, not upgraded.** | Files in `crds/` are applied on install and **skipped on upgrade**, by design. Upgrading a CRD is a manual `kubectl apply`. |
| **It is not a controller.** | Nothing reconciles a release. Edit an object with `kubectl` and Helm notices only at the next upgrade. |
| **`helm uninstall` does not remove PVCs** | created by a StatefulSet's `volumeClaimTemplates`. They outlive the release. |

**The first is the one that causes incidents.** "We rolled back" is often heard as
"we undid everything", and the data layer never moved.

---

## Part 2 - Hands-on lab

### Step 0: Helm

```bash
helm version
```

If that fails, install it — a single binary, with no cluster-side component
(28.2):

```bash
# Linux / WSL / macOS
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Windows
winget install Helm.Helm
```

```bash
helm version --short
kubectl config use-context kind-devops
kubectl create namespace cka28
kubectl config set-context --current --namespace=cka28
```

### Step 1: Install someone else's chart, and read it first

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/nginx | head -3
```

**Read the values before installing anything.** This is the habit, not an
optional step:

```bash
helm show chart bitnami/nginx | head -20
helm show values bitnami/nginx | head -40
```

Render it locally, with no cluster involved:

```bash
helm template demo bitnami/nginx --set replicaCount=2 | head -40
helm template demo bitnami/nginx | grep -c "^kind:"
```

**That is the whole chart, rendered, before anything is created** (28.6). Now
install:

```bash
helm install demo bitnami/nginx --set replicaCount=2 --set service.type=ClusterIP
helm list
kubectl get all -l app.kubernetes.io/instance=demo
```

### Step 2: Where the release actually lives

```bash
kubectl get secrets -l owner=helm
kubectl get secret sh.helm.release.v1.demo.v1 -o jsonpath='{.type}{"\n"}'
kubectl get secret sh.helm.release.v1.demo.v1 -o jsonpath='{.metadata.labels}' | tr ',' '\n'
```

```
helm.sh/release.v1
"name":"demo"
"owner":"helm"
"status":"deployed"
"version":"1"
```

**One Secret, in this namespace, is the entire record of the release** (28.7).
No server, no database. Prove it holds the manifests:

```bash
helm get manifest demo | head -20
helm get values demo
helm get values demo --all | head -20
```

`get values` shows what *you* supplied; `--all` shows the merged result including
every default. **The difference between those two outputs is your drift from the
chart's defaults**, and it is the first thing to look at when an installation
behaves oddly.

### Step 3: Upgrade, roll back, read the history

```bash
helm upgrade demo bitnami/nginx --set replicaCount=4 --set service.type=ClusterIP
helm history demo
kubectl get deploy -l app.kubernetes.io/instance=demo
```

Now roll back and watch what the history does:

```bash
helm rollback demo 1
helm history demo
```

```
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         superseded  Upgrade complete
3         deployed    Rollback to 1
```

**Revision 3, not revision 1** (28.8). The content matches revision 1; the
history is append-only.

```bash
kubectl get deploy -l app.kubernetes.io/instance=demo -o jsonpath='{.items[0].spec.replicas}{"\n"}'
kubectl get secrets -l owner=helm
```

**Three Secrets now — one per revision.** That is where the history comes from.

```bash
helm uninstall demo
kubectl get all -l app.kubernetes.io/instance=demo
kubectl get secrets -l owner=helm
```

### Step 4: Read a chart written to be read

```bash
find solution/mychart -type f | sort
cat solution/mychart/Chart.yaml
cat solution/mychart/values.yaml
```

Six template files, about 120 lines in total. Read them in this order —
`_helpers.tpl` first, because everything else calls into it:

```bash
cat solution/mychart/templates/_helpers.tpl
cat solution/mychart/templates/deployment.yaml
cat solution/mychart/templates/configmap.yaml
cat solution/mychart/templates/ingress.yaml
```

Four things in there are worth pausing on:

- **`mychart.selectorLabels` is a strict subset of `mychart.labels`**, and
  deliberately excludes the chart version. A Deployment's selector is immutable
  ([Day 04](../../days/day-04-labels-replicasets-deployments/)) — put a changing
  value in it and **every upgrade fails**.
- **`checksum/config`** in the pod template annotations hashes the rendered
  ConfigMap. Without it, changing a config value updates the ConfigMap and leaves
  the running pods on the old one.
- **`ingress.yaml` wraps the entire file in `{{- if }}`**, so a disabled Ingress
  emits nothing at all.
- **`required` on `owner`** turns a missing value into a readable error instead
  of a manifest with an empty label.

### Step 5: Render it before installing it

```bash
helm lint solution/mychart
helm template myapp solution/mychart | head -50
```

**No cluster was involved** (28.6). Now watch values change the output:

```bash
helm template myapp solution/mychart | grep -E "replicas:|image:|greeting"
helm template myapp solution/mychart --set replicaCount=7 | grep "replicas:"
helm template myapp solution/mychart -f solution/values-prod.yaml | grep -E "replicas:|greeting"
```

**`-f` merged a file; `--set` overrode one key.** Both leave everything else at
its default (28.1).

Note what the prod values turned on:

```bash
helm template myapp solution/mychart | grep -c "kind: Ingress"                                # 0
helm template myapp solution/mychart -f solution/values-prod.yaml | grep -c "kind: Ingress"   # 1
```

And the `required` guard:

```bash
helm template myapp solution/mychart -f solution/values-broken.yaml
```

```
Error: execution error at (mychart/templates/deployment.yaml:6:5):
values.owner is required -- set it with --set owner=<team>
```

**A message you wrote, at render time, before anything reached the cluster.**

### Step 6: Install your chart, twice

```bash
helm install myapp solution/mychart
kubectl get all -l app.kubernetes.io/instance=myapp
```

Read the NOTES output — it is a template too, and it printed your release's real
values.

Now install the **same chart again** under a different name:

```bash
helm install myapp-two solution/mychart --set replicaCount=1 --set config.environment=test
helm list
kubectl get deploy
```

```
NAME                READY
myapp-mychart       2/2
myapp-two-mychart   1/1
```

**Two releases, one chart, independent** (28.3). The `mychart.fullname` helper
kept their names apart; `app.kubernetes.io/instance` keeps their selectors apart.

```bash
kubectl get cm -l app.kubernetes.io/name=mychart \
  -o custom-columns=NAME:.metadata.name,ENV:.data.environment
```

### Step 7: The checksum annotation earns its place

```bash
POD=$(kubectl get pod -l app.kubernetes.io/instance=myapp -o name | head -1)
kubectl exec "$POD" -- cat /etc/mychart/greeting; echo
```

Change one config value and watch the pods roll:

```bash
helm upgrade myapp solution/mychart --set config.greeting="changed at $(date +%T)"
kubectl rollout status deployment/myapp-mychart --timeout=90s
POD=$(kubectl get pod -l app.kubernetes.io/instance=myapp -o name | head -1)
kubectl exec "$POD" -- cat /etc/mychart/greeting; echo
```

**New pods, new value.** The mechanism:

```bash
kubectl get deploy myapp-mychart -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
```

The checksum changed, so the pod template changed, so the Deployment rolled
(28.5). **Without it the ConfigMap would have been updated and the pods would
have kept serving the old value indefinitely** — a bug that is very hard to see.

### Step 8: A failed upgrade, and `--atomic`

```bash
helm upgrade myapp solution/mychart --set image.tag=this-tag-does-not-exist --wait --timeout 60s
```

It fails after the timeout and leaves the release mid-upgrade:

```bash
helm list
helm history myapp
kubectl get pods -l app.kubernetes.io/instance=myapp
```

```
STATUS: failed
```

**Some pods are `ImagePullBackOff` and the release says `failed`.** Recover by
hand:

```bash
helm rollback myapp
kubectl get pods -l app.kubernetes.io/instance=myapp
```

Now the same thing with `--atomic`:

```bash
helm upgrade myapp solution/mychart --set image.tag=also-does-not-exist --atomic --timeout 60s
helm history myapp
kubectl get pods -l app.kubernetes.io/instance=myapp
```

**Helm rolled it back itself**, and the history records both the failed upgrade
and the automatic rollback. **`--atomic` is what you want in CI** (28.8) — the
alternative is a pipeline that reports failure and leaves a half-upgraded
release.

### Cleanup

```bash
helm uninstall myapp myapp-two
kubectl delete namespace cka28 --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Three environments

Using `solution/mychart`, produce `values-dev.yaml`, `values-staging.yaml` and
`values-prod.yaml` for:

- dev: 1 replica, no Ingress, `LOG_LEVEL=debug`
- staging: 2 replicas, Ingress on `app-staging.local`, prod's resources
- prod: 4 replicas, Ingress on `app.local`, resource limits, `LOG_LEVEL=warn`

Then give the command that installs all three **into one cluster** and say what
makes them not collide.

### C2 - The upgrade that changed nothing

A colleague runs `helm upgrade myapp ./mychart --set config.greeting=hello`.
`helm history` shows a new revision, the ConfigMap has the new value, and the
application still returns the old greeting.

1. Explain exactly why.
2. Give the two commands that prove it.
3. Give the chart-level fix and the one-off fix.
4. Why does `helm rollback` not help?

### C3 - Read a hostile chart

You are asked to install a chart from a repository you have not used before.
List, in order, the six things you would check before running `helm install`,
with the command for each — and say which one would catch a chart that creates a
`ClusterRoleBinding` to `cluster-admin`.

### C4 - The release Helm forgot

`helm list` is empty, but the application is running and its objects have
`app.kubernetes.io/managed-by: Helm`.

1. What most likely happened?
2. How would you confirm it?
3. Can you get Helm to manage it again? Say what that costs.
4. What is the general lesson about where Helm's state lives?

### C5 - Rollback did not roll back

A team upgrades a PostgreSQL chart from `appVersion` 15 to 16. The StatefulSet
rolls, the new pods start, and the application breaks. They run
`helm rollback db 1`, the pods return to the 15 image, and the database still
does not work.

Explain what happened at each step, why the rollback was insufficient, and what
the correct procedure would have been.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: helm is installed and is version 3; the chart lints; `helm template`
renders a Deployment, a Service and a ConfigMap with no Ingress by default, and
an Ingress with the prod values; the `required` guard fails the broken values
file; two releases of the same chart coexist with distinct names and selectors;
the checksum annotation is present and changes when a config value changes; and
the release's state is a `helm.sh/release.v1` Secret per revision.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# repositories
helm repo add NAME URL && helm repo update
helm search repo KEYWORD
helm show values REPO/CHART            # before installing anything

# install and inspect
helm install REL REPO/CHART -n NS --create-namespace
helm install REL ./chart --dry-run --debug
helm list -A
helm status REL -n NS
helm get manifest REL -n NS
helm get values REL -n NS --all

# lifecycle
helm upgrade REL ./chart --set key=value --atomic --timeout 5m
helm upgrade --install REL ./chart          # idempotent -- use this in CI
helm history REL
helm rollback REL [REVISION]
helm uninstall REL --keep-history

# authoring
helm create NAME
helm lint ./chart
helm template REL ./chart -f values.yaml
helm package ./chart

# where the state is
kubectl get secrets -l owner=helm
```

**Traps**

- **Helm 3 has no Tiller.** Permissions are your kubeconfig's, so RBAC applies.
- **Release names are unique per namespace**, not per cluster.
- **A rollback creates a new revision.** History is append-only.
- **`helm template` needs no cluster; `--dry-run` does** and validates against
  the API server.
- **`helm get values` shows overrides only** — add `--all` for the merged set.
- **Release state is Secrets in the release namespace.** Delete them and Helm
  forgets the release while the objects keep running.
- **Anything passed with `--set` is stored in that Secret**, readable by anyone
  with `get secrets` there.
- **`selectorLabels` must never contain a changing value** — the selector is
  immutable and the upgrade will fail.
- **Without a `checksum/config` annotation**, a ConfigMap change does not restart
  pods.
- **CRDs in `crds/` are installed once and never upgraded.**
- **Rollback reverts manifests, not data.** PVs keep their contents.
- **`--atomic` implies `--wait`** and is the CI-safe form.
- **`helm upgrade --install`** is the idempotent one-liner for pipelines.
- `apiVersion: v2` in `Chart.yaml` means Helm 3; `v1` means the chart predates it.

---

**Previous:** [CKA 27 — Build a Cluster with kubeadm](../27-build-a-cluster-with-kubeadm/)
**Next: CKA 29 — Kustomize: Structure and Transformers** *(not yet built — see [CURRICULUM.md](../CURRICULUM.md))*
