# CKA 28 solution

## Challenge answers

### C1 - Three environments

```yaml
# values-dev.yaml
replicaCount: 1
config:
  environment: "dev"
extraEnv:
  - {name: LOG_LEVEL, value: "debug"}
ingress:
  enabled: false
owner: "team-a"
```

```yaml
# values-staging.yaml
replicaCount: 2
config:
  environment: "staging"
extraEnv:
  - {name: LOG_LEVEL, value: "info"}
resources:
  requests: {cpu: 50m, memory: 64Mi}
  limits:   {cpu: 200m, memory: 128Mi}
ingress:
  enabled: true
  className: nginx
  host: app-staging.local
owner: "team-a"
```

```yaml
# values-prod.yaml  (as shipped)
replicaCount: 4
config:
  environment: "prod"
extraEnv:
  - {name: LOG_LEVEL, value: "warn"}
resources:
  requests: {cpu: 50m, memory: 64Mi}
  limits:   {cpu: 200m, memory: 128Mi}
ingress:
  enabled: true
  className: nginx
  host: app.local
owner: "sre"
```

**Installing all three into one cluster:**

```bash
for env in dev staging prod; do
  helm upgrade --install "app-$env" ./mychart \
    -n "$env" --create-namespace \
    -f "values-$env.yaml"
done
```

**What keeps them from colliding — three separate mechanisms, and it is worth
being able to name all three:**

1. **Different namespaces.** Object names only need to be unique within one, and
   release names are per-namespace in Helm 3 (28.2). Two releases could even
   share a name in different namespaces.
2. **`mychart.fullname` prefixes every object with the release name**, so even in
   one namespace `app-dev-mychart` and `app-prod-mychart` do not clash.
3. **`app.kubernetes.io/instance` is in the selector labels**, so each
   Deployment's selector matches only its own pods. Without it, three Deployments
   in one namespace would fight over the same pods — each seeing the others'
   replicas as its own and scaling them down.

**Use `helm upgrade --install`, not `helm install`.** It creates the release if it
does not exist and upgrades it if it does, which makes the loop idempotent and
safe to re-run — the standard form in CI (28.6).

Note what is *not* duplicated: the templates. A fix to the chart applies to all
three on the next deploy, which is the entire point (28.1).

### C2 - The upgrade that changed nothing

**1. Why.**

**The pods were never restarted.** The upgrade updated the ConfigMap object, and
nothing about the Deployment's pod template changed — same image, same replicas,
same everything — so the Deployment controller had no reason to roll.

The subtlety is *how* the ConfigMap is consumed. Mounted as a volume, the kubelet
updates the file in the container **eventually** (up to about a minute), but
almost every application reads its configuration once at startup and never again.
Consumed via `envFrom` or `valueFrom.configMapKeyRef`, the value is **fixed at
container start** and never updates at all.

Either way: **new value in etcd, old value in the process.**

**2. The two commands that prove it:**

```bash
# the ConfigMap has the new value
kubectl get cm myapp-mychart -o jsonpath='{.data.greeting}{"\n"}'

# the pods are older than the upgrade
kubectl get pods -l app.kubernetes.io/instance=myapp \
  -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp
helm history myapp | tail -2
```

**A pod `creationTimestamp` earlier than the revision's `UPDATED` time is the
whole diagnosis.** Confirm from inside if you like:

```bash
kubectl exec deploy/myapp-mychart -- cat /etc/mychart/greeting
```

**3. The fixes.**

**Chart-level, and the right one** — an annotation on the pod template that
changes whenever the ConfigMap's content does (28.5):

```yaml
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Now any config change alters the pod template, so the Deployment rolls
automatically. That is what `solution/mychart` does, and Step 7 demonstrates it.

**One-off, without touching the chart:**

```bash
kubectl rollout restart deployment/myapp-mychart
```

**4. Why `helm rollback` does not help.**

Rollback reverts the ConfigMap to its previous *content* — which the pods are
already serving. So the release goes back and the observable behaviour does not
change at all, because it never changed in the first place.

Worse, it is actively confusing: the team sees "we rolled back and it is still
wrong", and concludes the problem is somewhere else entirely. **The pods were
always the stale component**, and no amount of manifest manipulation restarts
them (28.9).

### C3 - Read a hostile chart

In order, before `helm install`:

```bash
# 1. Who published it, and is it the project itself?
helm search hub CHARTNAME              # or check artifacthub.io for the verified badge
helm repo list

# 2. What does the chart claim to be?
helm show chart REPO/CHART

# 3. What can be configured -- and what the defaults are
helm show values REPO/CHART

# 4. What will it ACTUALLY create?    <-- the important one
helm template x REPO/CHART | grep "^kind:" | sort | uniq -c

# 5. What permissions does it grant itself?
helm template x REPO/CHART | grep -A15 -E "kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding)"

# 6. What runs privileged, or reaches the host?
helm template x REPO/CHART | grep -E "privileged|hostNetwork|hostPID|hostPath|runAsUser: 0"

# 7. Where do the images come from?
helm template x REPO/CHART | grep -E "^\s+image:" | sort -u
```

**Number 5 is the one that catches a `cluster-admin` binding.** Rendering the
chart and grepping the RBAC objects shows exactly what the release will be able
to do — and a `ClusterRoleBinding` to `cluster-admin` is visible in one line:

```bash
helm template x REPO/CHART | grep -B5 -A5 "name: cluster-admin"
```

**The general principle: `helm install` is `kubectl apply` of manifests you have
not read** (28.3). `helm template` costs nothing, needs no cluster, and turns an
act of trust into a code review.

Two more worth doing in a regulated environment: check the chart is signed
(`helm verify`, `--verify`), and install into a namespace with Pod Security
Admission set to `restricted` ([CKA 17](../../17-image-security-and-security-contexts/))
so that anything privileged is refused rather than merely noticed.

### C4 - The release Helm forgot

**1. What most likely happened.**

**The release Secrets were deleted** (28.7). Helm 3 keeps no server-side state
beyond one `helm.sh/release.v1` Secret per revision, in the release's namespace.
Delete those and Helm has no record the release ever existed — while every object
it created keeps running, because nothing about them depends on Helm.

The usual causes: a namespace cleanup script matching on `kubectl delete secret
--all`, a backup restore that skipped Secrets, an over-eager
`kubectl delete secret -l` selector, or someone tidying up what looked like
noise.

A second possibility worth ruling out first: **you are looking in the wrong
namespace**. Release names are per-namespace in Helm 3, and `helm list` defaults
to the current context's namespace.

**2. Confirming it:**

```bash
# rule out the boring explanation
helm list -A

# the objects say Helm made them
kubectl get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.labels}{"\n"}{end}' \
  | grep managed-by

# ...and the release Secrets are gone
kubectl get secrets -n NS -l owner=helm
kubectl get secrets -n NS --field-selector type=helm.sh/release.v1
```

**`managed-by: Helm` on the objects plus zero release Secrets is the
diagnosis.** The label is a claim written at render time; the Secret is the
actual state.

**3. Can you get Helm to manage it again?**

**Yes — with `helm upgrade --install`, and it costs you the history.**

```bash
helm upgrade --install myapp ./mychart -n NS -f the-values-you-used.yaml
```

Helm finds no existing release, performs an **install**, and — because Helm 3 uses
a three-way merge (28.2) — adopts the existing objects rather than failing on
"already exists", provided they match what the chart renders.

What it costs:

- **The history is gone.** You start at revision 1. There is nothing to roll back
  to, and the record of what was deployed when is lost permanently.
- **You must reconstruct the values.** They lived in the deleted Secret. Getting
  them wrong means the "adoption" is actually a change — possibly a disruptive
  one. Compare `helm template` output against the live objects with
  `kubectl diff -f -` before committing.
- **Objects the chart no longer renders are orphaned.** They stay, unmanaged, and
  no future `helm uninstall` will remove them.

Newer Helm versions also want ownership metadata
(`meta.helm.sh/release-name` and `-namespace` annotations); if adoption is
refused, add them by hand:

```bash
kubectl annotate deploy myapp-mychart meta.helm.sh/release-name=myapp --overwrite
kubectl annotate deploy myapp-mychart meta.helm.sh/release-namespace=NS --overwrite
kubectl label deploy myapp-mychart app.kubernetes.io/managed-by=Helm --overwrite
```

**4. The general lesson.**

**Helm's state is data in the cluster, not a service.** There is no Helm server,
no database, and no reconciliation loop (28.9) — just Secrets that the client
reads and writes. That has three consequences:

- **Back them up.** They are in etcd, so an etcd snapshot
  ([CKA 12](../../12-cluster-maintenance/)) covers them — but a
  namespace-scoped backup tool that excludes Secrets does not.
- **Anyone with `get secrets` in the namespace can read every value ever
  passed**, including passwords from `--set` (28.7).
- **The source of truth should be the chart and the values file in Git**, not the
  cluster. If losing the release Secrets means losing the knowledge of how the
  application was deployed, the deployment was never reproducible. **A team using
  GitOps notices this incident as a curiosity; a team deploying by hand notices
  it as data loss.**

### C5 - Rollback did not roll back

**What happened, step by step:**

1. **`helm upgrade` changed the StatefulSet's image from PostgreSQL 15 to 16.**
   That is a pod template change, so the StatefulSet controller rolled the pods —
   one at a time, in reverse ordinal order
   ([Day 15](../../../days/day-15-statefulsets-and-headless-services/)).
2. **The PostgreSQL 16 binary started against the version-15 data directory.**
   PostgreSQL major versions have an incompatible on-disk format. The new process
   either refused to start, or — on some images that run an entrypoint migration —
   **began rewriting the data files in place**.
3. **The PVCs never changed.** `volumeClaimTemplates` produce PVCs that outlive
   the pods and are not part of the rolling update (28.9). Same volumes, same
   bytes, different binary.
4. **`helm rollback db 1` reverted the manifests**: the StatefulSet's image went
   back to 15 and the pods rolled again.
5. **The data directory did not go back.** If step 2 only failed to start,
   PostgreSQL 15 comes back up and works — this team's report says it did not, so
   step 2 got far enough to modify the data. **PostgreSQL 15 now refuses to open
   a version-16 data directory**, and there is no downgrade path in the engine.

**Why the rollback was insufficient, in one sentence:**

**Helm reverts declarations, not state** (28.9). It restored the StatefulSet's
spec perfectly and had no involvement with — and no knowledge of — the contents of
the PersistentVolumes. The pods are correct; the disk is not.

**The correct procedure:**

**Before the upgrade:**

1. **Read the chart's upgrade notes and the database's release notes.** A major
   PostgreSQL version bump is a *migration*, not an upgrade, and every chart that
   ships one says so.
2. **Take a logical backup**, not a volume snapshot alone:
   `pg_dumpall` to object storage. A volume snapshot restores the old format,
   which is enough here — but a logical dump is what survives a *partial*
   in-place conversion.
3. **Rehearse on a clone.** Restore the backup into a scratch namespace and run
   the upgrade there first.
4. **Pin the version explicitly** in values, so a chart update cannot move the
   major version by itself. This is the step that would have prevented the whole
   incident if the bump was unintentional:
   ```yaml
   image:
     tag: "15.6.0"
   ```

**The upgrade itself:**

5. **Scale to zero, or put the application in maintenance**, so nothing writes
   during the migration.
6. **Run the documented migration** — for PostgreSQL, `pg_upgrade` or dump and
   restore into a **new** volume, never in place.
7. **Keep the old PVC.** Point the new StatefulSet at a new volume so the old one
   is an untouched rollback target. **This is the step that makes rollback
   possible at all.**

**If it goes wrong anyway:**

```bash
helm rollback db 1                      # restores the manifests
# ...and then, separately:
#   restore the data from the backup, or
#   repoint the StatefulSet at the retained old PVC
```

**The general rule: for any stateful workload, a Helm rollback is half of a
rollback plan.** The other half is a data restore, and it has to be written down
before the upgrade, because it is not something Helm can do for you.

`reclaimPolicy: Retain` on the storage class
([CKA 20](../../20-storage-internals-and-csi/)) is the cheap insurance — it means
a deleted PVC leaves a `Released` PV holding the old data rather than deleting
it.

---

## Files

| File | Purpose |
|---|---|
| `mychart/Chart.yaml` | `apiVersion: v2`, and `version` vs `appVersion` |
| `mychart/values.yaml` | every value a template reads, with a default and a comment |
| `mychart/templates/_helpers.tpl` | `name`, `fullname`, `labels`, `selectorLabels` |
| `mychart/templates/deployment.yaml` | `include`, `nindent`, `default`, `range`, `toYaml`, `with`, and the config checksum |
| `mychart/templates/configmap.yaml` | `range` over a map, and why `quote` is not optional |
| `mychart/templates/ingress.yaml` | the whole file wrapped in `if` |
| `mychart/templates/NOTES.txt` | a template that renders after install |
| `values-prod.yaml` | a per-environment override file |
| `values-broken.yaml` | omits `owner`, so `required` fails the render |
| `verify.sh` | checks the chart mostly without a cluster |

**`mychart` is hand-written, not `helm create` output.** The scaffolding is about
300 lines with a ServiceAccount, an HPA, autoscaling toggles and a test hook —
useful in production and impossible to read in one sitting. This is 120 lines and
every one of them is doing something the assignment explains.

Run `helm create scratch` once to see what the real scaffolding looks like, then
delete it.

---

## Two details in the chart worth stealing

**`selectorLabels` is separate from `labels`, and smaller.**

```yaml
{{- define "mychart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mychart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

A Deployment's `spec.selector` is **immutable**
([Day 04](../../../days/day-04-labels-replicasets-deployments/)). Put
`helm.sh/chart: mychart-0.1.0` in it and the next `version` bump produces:

```
Error: UPGRADE FAILED: cannot patch "myapp-mychart" with kind Deployment:
Deployment.apps "myapp-mychart" is invalid: spec.selector: Invalid value: ...
field is immutable
```

**Every upgrade fails, forever, until someone deletes the Deployment.** This is
one of the most common bugs in home-grown charts, and the fix is to keep the
selector to values that never change.

**The config checksum.**

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

It renders `configmap.yaml` a second time, hashes the result, and puts the hash
in the pod template. A config change alters the hash, which alters the pod
template, which makes the Deployment roll (C2).

**`$.Template.BasePath` is the chart's `templates/` directory**, and `$` is the
root context — inside a `range` or `with`, plain `.` would be the wrong scope,
which is the usual reason this snippet fails when copied.
