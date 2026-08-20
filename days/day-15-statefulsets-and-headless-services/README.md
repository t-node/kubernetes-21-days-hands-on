# Day 15 — StatefulSets & Headless Services

**Time:** 75-90 minutes
**Prerequisites:** Day 14 (Postgres on a PVC)

You have persistent storage. You still have a Deployment, which means no stable
identity, one shared volume, and no ordering. Today you fix all three — and see
precisely what a StatefulSet buys and what it does not.

---

## Part 1 - Concepts

### 15.1 What a Deployment cannot give a database

| Need | Deployment | StatefulSet |
|---|---|---|
| **Stable name** | `postgres-6d4f8c-2xk9p` (random, changes) | `postgres-0`, `postgres-1` (permanent) |
| **Stable storage** | one PVC shared by all replicas | **one PVC per replica**, reattached by ordinal |
| **Stable network identity** | none; only the Service name | `postgres-0.postgres.devboard.svc.cluster.local` |
| **Ordered start** | all at once | `0`, then `1`, then `2`, each Ready first |
| **Ordered stop** | all at once | reverse: `2`, `1`, `0` |

Why a database needs each:

- **Stable name** — replication config must say "replicate from `postgres-0`".
  With random names there is nothing to point at.
- **Per-replica storage** — each replica needs *its own* data directory. One
  shared volume means either corruption or Multi-Attach errors, both of which
  you saw yesterday.
- **Stable DNS** — a replica must connect to a specific peer, not "whichever
  pod the Service picks".
- **Ordering** — a replica must not start before the primary exists.

### 15.2 The three defining pieces

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres-headless     # 1. REQUIRED: the governing headless Service
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers: [...]

  volumeClaimTemplates:              # 2. one PVC created PER REPLICA
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: standard
        resources:
          requests:
            storage: 2Gi
```

3. **Pod names are ordinals**: `postgres-0`, `postgres-1`, ... permanently.

`volumeClaimTemplates` is the key difference from a Deployment. Kubernetes
creates `data-postgres-0`, `data-postgres-1` — one PVC per replica, named
`<template>-<statefulset>-<ordinal>`. Delete `postgres-0` and the replacement,
also called `postgres-0`, **reattaches the same PVC**. Identity and storage move
together.

### 15.3 Headless Services, and why a StatefulSet needs one

From Day 06: a headless Service (`clusterIP: None`) gets no virtual IP, and DNS
returns **pod IPs** instead of load balancing.

For a StatefulSet, the headless Service named in `serviceName` also creates
**per-pod DNS records**:

```
postgres-0.postgres-headless.devboard.svc.cluster.local  ->  10.244.1.12
postgres-1.postgres-headless.devboard.svc.cluster.local  ->  10.244.2.8
```

That is what makes "connect to the primary specifically" possible.

**Real StatefulSets usually have two Services:**

| Service | Type | Purpose |
|---|---|---|
| `postgres-headless` | `clusterIP: None` | per-pod DNS, required by the StatefulSet |
| `postgres` | `ClusterIP` | a normal load-balanced endpoint for clients |

Your backend keeps using `postgres` and does not care that Postgres became a
StatefulSet — which is the point. **The application should not have to change.**

### 15.4 Ordered operations

**Scale up** — strictly sequential: `postgres-0` must be Running **and Ready**
before `postgres-1` is created. A pod that never becomes Ready blocks the whole
StatefulSet forever, which is a good reason to get readiness probes right.

**Scale down** — reverse order: highest ordinal first.

**Rolling update** — reverse ordinal order, one at a time, each fully Ready
before the next. Slow and deliberate, which is what a database wants.

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 2        # only update pods with ordinal >= 2 (canary)
```

`partition` is a genuinely useful trick: set it to N and only pods `>= N` update,
so you can test a new version on the highest-ordinal replica before rolling the
rest.

`podManagementPolicy: Parallel` disables the ordering if you do not need it —
appropriate for sharded systems where replicas are independent.

### 15.5 What a StatefulSet does NOT do

Be precise about this; it is where interviews separate people.

- **It does not set up replication.** It gives you stable names and volumes. Any
  actual clustering — primary election, streaming replication, failover — is
  your job, usually via an init container, a sidecar, or the image's own
  clustering logic.
- **It does not make a database highly available.** `postgres-0` and
  `postgres-1` from a plain StatefulSet are two **independent** databases, just
  like the Deployment case, unless something configures replication between them.
- **It does not delete PVCs when you scale down.** Deliberately: scaling from 3
  to 1 keeps `data-postgres-1` and `data-postgres-2` so scaling back up
  reattaches the same data. It also means storage costs quietly accumulate.
  Kubernetes 1.27+ adds `persistentVolumeClaimRetentionPolicy` to control this.
- **It does not handle backups**, upgrades, or connection pooling.

**This is why operators exist.** CloudNativePG, the Zalando operator and Crunchy
build on StatefulSets and add the replication, failover, backup and upgrade
logic. In production, use one.

### 15.6 When to choose which

| Workload | Controller |
|---|---|
| Stateless web/API (frontend, backend) | **Deployment** |
| Database, message queue, anything with per-replica state | **StatefulSet** |
| One pod per node (log agent, monitoring, CNI) | **DaemonSet** (Day 18) |
| Run once to completion | **Job** |
| Run on a schedule | **CronJob** |

Do not reach for a StatefulSet just because a workload has a volume. A single
app pod with a PVC works fine as a Deployment. Use a StatefulSet when you need
**identity**.

---

## Part 2 - Hands-on lab

### Step 1: Preserve your data, then remove the Deployment

The StatefulSet manages its own PVCs, so the old one has to go. Back up first —
this is a good habit to build anyway:

```bash
kubectl exec -n devboard deploy/postgres -- \
  pg_dump -U devboard -d devboard --data-only --table=tasks --table=projects \
  > /tmp/devboard-backup.sql

wc -l /tmp/devboard-backup.sql
head -20 /tmp/devboard-backup.sql
```

Then remove the Deployment and its PVC:

```bash
kubectl delete deployment postgres -n devboard
kubectl delete pvc postgres-data -n devboard
kubectl get pv          # gone too, because reclaimPolicy is Delete
```

### Step 2: Deploy the StatefulSet

```bash
kubectl apply -f solution/01-postgres-headless-service.yaml
kubectl apply -f solution/02-postgres-service.yaml
kubectl apply -f solution/03-postgres-statefulset.yaml

kubectl get statefulset,pods,pvc -n devboard
```

```
NAME                        READY   AGE
statefulset.apps/postgres   1/1     45s

NAME             READY   STATUS    RESTARTS   AGE
pod/postgres-0   1/1     Running   0          45s

NAME                                    STATUS   VOLUME             CAPACITY
persistentvolumeclaim/data-postgres-0   Bound    pvc-9c1d...        2Gi
```

Three things changed and all of them matter:

- The pod is **`postgres-0`**, not `postgres-6d4f8c-2xk9p`. Predictable.
- The PVC is **`data-postgres-0`** — `<volumeClaimTemplate>-<sts>-<ordinal>` —
  and you never created it. The StatefulSet did.
- `kubectl get statefulset` shows `1/1`, same shape as a Deployment.

The backend needs no change at all: the `postgres` ClusterIP Service still
selects `app: postgres`, and the pod still carries that label.

```bash
kubectl get endpoints postgres -n devboard
kubectl rollout restart deployment/backend -n devboard
kubectl rollout status deployment/backend -n devboard
curl -s http://localhost:30080/api/tasks | head -c 200; echo
```

### Step 3: Per-pod DNS — the thing you could not do before

```bash
kubectl run dns --rm -it -n devboard --image=busybox:1.36 -- sh
```

Inside:

```sh
# the load-balanced Service: one virtual IP
nslookup postgres

# the headless Service: the pod IPs themselves
nslookup postgres-headless

# and the one that matters: a SPECIFIC pod, addressable by name
nslookup postgres-0.postgres-headless

exit
```

That last record is what makes replication configurable. `postgres-0` is
addressable forever, regardless of restarts, reschedules or IP changes.

### Step 4: Identity survives deletion

```bash
kubectl get pod postgres-0 -n devboard -o wide     # note the IP and node

kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id, status) VALUES ('sts survives', 1, 'done');"

kubectl delete pod postgres-0 -n devboard
kubectl wait --for=condition=Ready pod/postgres-0 -n devboard --timeout=120s

kubectl get pod postgres-0 -n devboard -o wide     # SAME NAME, new IP
kubectl get pvc -n devboard                        # SAME PVC, still Bound

kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -c "SELECT id,title FROM tasks WHERE title='sts survives';"
```

Same name, same volume, same data. The name is not a coincidence — it is the
identity the StatefulSet guarantees.

### Step 5: Watch ordered scaling

```bash
kubectl get pods -n devboard -l app=postgres -w      # terminal 1
```

```bash
kubectl scale statefulset postgres --replicas=3 -n devboard     # terminal 2
```

Watch terminal 1 carefully: `postgres-1` is not even **created** until
`postgres-0` is Ready; `postgres-2` waits for `postgres-1`. Strictly sequential.

```bash
kubectl get pods,pvc -n devboard
```

Three pods, **three PVCs** — `data-postgres-0`, `-1`, `-2`. Each replica got its
own volume automatically. That is `volumeClaimTemplates` doing the thing a
Deployment cannot.

Now scale down and watch the reverse order:

```bash
kubectl scale statefulset postgres --replicas=1 -n devboard
kubectl get pods -n devboard -l app=postgres -w
```

`postgres-2` goes first, then `postgres-1`. Highest ordinal first.

```bash
kubectl get pvc -n devboard
```

**The PVCs are still there.** Deliberate: scale back to 3 and the same data
reattaches. It also means you are still paying for that storage.

```bash
kubectl delete pvc data-postgres-1 data-postgres-2 -n devboard
```

### Step 6: The honest limitation

Scale to 3 again and look at what you actually have:

```bash
kubectl scale statefulset postgres --replicas=3 -n devboard
kubectl wait --for=condition=Ready pod/postgres-2 -n devboard --timeout=180s

kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('only on zero', 1);"

for i in 0 1 2; do
  echo -n "postgres-$i task count: "
  kubectl exec -n devboard postgres-$i -- \
    psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
done
```

Different counts. **These are three independent databases, not a cluster.** The
StatefulSet gave you stable names and separate volumes; it did not configure
replication, because that is not its job.

Worse, the `postgres` ClusterIP Service load balances across all three, so your
API now returns different data per request:

```bash
for i in $(seq 1 6); do curl -s http://localhost:30080/api/tasks | head -c 60; echo; done
```

This is section 15.5, and it is the argument for operators. Real Postgres HA
needs streaming replication, a primary election, failover, and a Service that
points only at the current primary.

```bash
kubectl scale statefulset postgres --replicas=1 -n devboard
kubectl delete pvc data-postgres-1 data-postgres-2 -n devboard --ignore-not-found
```

### Step 7: Restore your backup

```bash
kubectl exec -i -n devboard postgres-0 -- \
  psql -U devboard -d devboard < /tmp/devboard-backup.sql 2>&1 | tail -5

kubectl exec -n devboard postgres-0 -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
```

You may see duplicate-key errors on the seeded rows — expected, since the fresh
volume re-ran `02_seed.sql` and then your dump inserted the same ids. Real
restores use `--clean` or restore into an empty database. The point is that
`kubectl exec -i` plus `pg_dump`/`psql` is a genuine, portable backup path, and
a perfectly reasonable answer to "how would you back this up?" for small
databases.

### Step 8: Rolling update with a partition

```bash
kubectl scale statefulset postgres --replicas=3 -n devboard
kubectl rollout status statefulset/postgres -n devboard --timeout=300s

kubectl patch statefulset postgres -n devboard -p \
  '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":2}}}}'

kubectl set image statefulset/postgres postgres=postgres:16.4-alpine -n devboard

kubectl get pods -n devboard -l app=postgres \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

Only `postgres-2` updated. Pods `0` and `1` are untouched. That is a canary on
one replica; drop the partition to 0 to roll the rest:

```bash
kubectl patch statefulset postgres -n devboard -p \
  '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":0}}}}'
kubectl rollout status statefulset/postgres -n devboard --timeout=300s
```

Note the update order: `2`, then `1`, then `0` — highest ordinal first, so the
lowest-numbered replica (conventionally the primary) changes last.

```bash
kubectl scale statefulset postgres --replicas=1 -n devboard
kubectl delete pvc data-postgres-1 data-postgres-2 -n devboard --ignore-not-found
```

---

## Validate

```bash
kubectl apply -f solution/
kubectl rollout status statefulset/postgres -n devboard --timeout=180s

# 1. the pod is an ordinal, not a hash
kubectl get pods -n devboard -l app=postgres -o name        # pod/postgres-0

# 2. its PVC was auto-created with the ordinal naming
kubectl get pvc -n devboard | grep data-postgres-0

# 3. per-pod DNS resolves
kubectl run dns --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  nslookup postgres-0.postgres-headless

# 4. identity survives deletion
kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('validate-day15', 1);"
kubectl delete pod postgres-0 -n devboard
kubectl wait --for=condition=Ready pod/postgres-0 -n devboard --timeout=180s
kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks WHERE title='validate-day15';"     # 1

# 5. the app still works without any change to it
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks
```

Ready for Day 16 when you can:

1. Give the four guarantees a StatefulSet provides that a Deployment does not.
2. Explain what `volumeClaimTemplates` creates and how the PVCs are named.
3. Explain why a StatefulSet needs a headless Service.
4. State clearly what a StatefulSet does **not** do.

---

## Break it

**A. Forget `serviceName`.**

```bash
kubectl apply -f solution/BAD-01-no-servicename.yaml
# error: spec.serviceName: Required value
```

Unlike most fields, this one is mandatory and validated at admission.

**B. Point `serviceName` at a Service that does not exist.**

```bash
kubectl apply -f solution/BAD-02-wrong-servicename.yaml
kubectl get pods -n devboard -l app=broken-sts        # they DO start
kubectl run dns --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  nslookup broken-sts-0.nonexistent-svc
# NXDOMAIN
```

The pods run fine — but there are **no per-pod DNS records**, so anything
relying on peer addressing silently breaks. No error anywhere. A nasty one.

```bash
kubectl delete -f solution/BAD-02-wrong-servicename.yaml --ignore-not-found
```

**C. A pod that never becomes Ready blocks everything.**

```bash
kubectl scale statefulset postgres --replicas=2 -n devboard
kubectl patch statefulset postgres -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"postgres","readinessProbe":{"exec":{"command":["false"]},"periodSeconds":2}}]}}}}'

kubectl delete pod postgres-0 -n devboard
kubectl get pods -n devboard -l app=postgres -w      # Ctrl-C after a minute
```

`postgres-0` never becomes Ready, so `postgres-1` is never created — and if you
scale up, nothing happens at all. **Ordering guarantees cut both ways.** A
broken readiness probe on a StatefulSet is a full stop, not a degradation.

```bash
kubectl apply -f solution/03-postgres-statefulset.yaml
kubectl scale statefulset postgres --replicas=1 -n devboard
kubectl delete pvc data-postgres-1 -n devboard --ignore-not-found
```

**D. Try to change `volumeClaimTemplates`.**

```bash
kubectl patch statefulset postgres -n devboard -p \
  '{"spec":{"volumeClaimTemplates":[{"metadata":{"name":"data"},"spec":{"resources":{"requests":{"storage":"5Gi"}}}}]}}'
# Forbidden: updates to statefulset spec for fields other than 'replicas',
# 'ordinals', 'template', 'updateStrategy', 'persistentVolumeClaimRetentionPolicy'
# and 'minReadySeconds' are forbidden
```

`volumeClaimTemplates` is **immutable**. To grow the volumes you edit each PVC
individually (if the StorageClass allows expansion), or delete the StatefulSet
with `--cascade=orphan`, recreate it, and let it adopt the existing pods. Plan
volume sizes with that in mind.

**E. Delete the StatefulSet and see what remains.**

```bash
kubectl delete statefulset postgres -n devboard
kubectl get pvc -n devboard        # data-postgres-0 IS STILL THERE

kubectl apply -f solution/03-postgres-statefulset.yaml
kubectl wait --for=condition=Ready pod/postgres-0 -n devboard --timeout=180s
kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks;"        # your data is back
```

Deleting a StatefulSet **never** deletes its PVCs by default. That is a safety
feature and a cost trap. Since 1.27 you can opt into cleanup:

```yaml
persistentVolumeClaimRetentionPolicy:
  whenDeleted: Delete       # or Retain (default)
  whenScaled: Delete        # or Retain (default)
```

---

## Interview questions

<details>
<summary><b>1. Deployment vs StatefulSet?</b></summary>

A Deployment treats pods as interchangeable: random names, one shared pod
template and volume, parallel creation. A StatefulSet gives each pod a stable
ordinal identity that survives rescheduling, a dedicated PVC per replica through
volumeClaimTemplates, a stable per-pod DNS name via a headless Service, and
ordered creation, deletion and updates. Use a Deployment for stateless
workloads, a StatefulSet when a replica's identity matters.
</details>

<details>
<summary><b>2. What does volumeClaimTemplates do?</b></summary>

It makes the StatefulSet create one PVC per replica, named
`<template>-<statefulset>-<ordinal>` - `data-postgres-0`, `data-postgres-1`. A
replacement pod with the same ordinal reattaches the same PVC, so storage
follows identity. The templates are immutable after creation, and the PVCs are
not deleted when you scale down or delete the StatefulSet unless you set a
persistentVolumeClaimRetentionPolicy.
</details>

<details>
<summary><b>3. Why does a StatefulSet need a headless Service?</b></summary>

The Service named in `spec.serviceName` provides the per-pod DNS records
`<pod>.<service>.<ns>.svc.cluster.local`. Without them a replica cannot address
a specific peer, which is what replication and clustering require. The field is
mandatory, but nothing validates that the Service exists - point it at a
non-existent name and the pods run happily with no DNS records at all.
</details>

<details>
<summary><b>4. Does a StatefulSet give you a highly available database?</b></summary>

No. It gives stable identity, per-replica storage and ordering. Three replicas
of a plain Postgres StatefulSet are three independent databases; nothing sets up
streaming replication, elects a primary, or fails over. That logic must come
from an init container, a sidecar, the image itself, or - in practice - an
operator such as CloudNativePG or the Zalando operator.
</details>

<details>
<summary><b>5. In what order do StatefulSet pods start, stop and update?</b></summary>

Creation and scale-up are ascending and strictly sequential: pod N must be
Running and Ready before N+1 is created. Scale-down and deletion are descending.
Rolling updates go in descending order, one pod at a time, each fully Ready
before the next. `podManagementPolicy: Parallel` removes the ordering for
workloads that do not need it.
</details>

<details>
<summary><b>6. What is the partition field in updateStrategy?</b></summary>

Only pods with an ordinal greater than or equal to `partition` are updated. It
implements a canary: set partition to N-1 to update only the highest-ordinal
replica, verify it, then lower the partition to roll the rest. Since updates go
in descending order, the lowest-ordinal pod - conventionally the primary -
changes last.
</details>

<details>
<summary><b>7. You scale a StatefulSet from 3 to 1. What happens to the storage?</b></summary>

Pods 2 and 1 terminate in that order, but their PVCs remain. Scaling back up
reattaches the same volumes with the same data, which is usually what you want -
and it means the storage keeps costing money. From 1.27 you can set
`persistentVolumeClaimRetentionPolicy.whenScaled: Delete` to reclaim them
automatically.
</details>

<details>
<summary><b>8. How do you back up and restore a database in a StatefulSet?</b></summary>

`kubectl exec` plus `pg_dump` piped to a local file, and `kubectl exec -i` plus
`psql` to restore, is the portable minimum and fine for small databases. For
anything real: a CronJob running pgBackRest or WAL-G to object storage with
continuous WAL archiving, which gives point-in-time recovery. CSI VolumeSnapshots
are an infrastructure-level alternative, crash-consistent unless you quiesce
first. Test the restore path regularly.
</details>

<details>
<summary><b>9. Can you convert a Deployment to a StatefulSet in place?</b></summary>

No - different kinds, so you delete and recreate. The data migration is the real
work: back up from the Deployment's PVC, create the StatefulSet so its
volumeClaimTemplates provision fresh PVCs, restore into pod 0. Alternatively
pre-create a PVC with the exact name the template will ask for
(`data-postgres-0`) so the StatefulSet adopts the existing volume rather than
provisioning a new one - a trick worth knowing for migrations.
</details>

---

## Cheat card

```bash
kubectl get statefulset,pods,pvc -n devboard
kubectl describe statefulset postgres -n devboard

kubectl scale statefulset postgres --replicas=3 -n devboard
kubectl rollout status  statefulset/postgres -n devboard
kubectl rollout history statefulset/postgres -n devboard
kubectl rollout undo    statefulset/postgres -n devboard

# canary: only ordinals >= 2 update
kubectl patch statefulset postgres -n devboard -p \
  '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'

# per-pod DNS
kubectl run dns --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  nslookup postgres-0.postgres-headless

# address one specific replica
kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard -c "\dt"

# keep the pods, drop the controller (for migrations)
kubectl delete statefulset postgres -n devboard --cascade=orphan
```

| Object | Naming |
|---|---|
| Pod | `<statefulset>-<ordinal>` → `postgres-0` |
| PVC | `<template>-<statefulset>-<ordinal>` → `data-postgres-0` |
| Pod DNS | `<pod>.<headless-svc>.<ns>.svc.cluster.local` |

**Remember:** a StatefulSet gives identity and storage. It does **not** give you
replication, failover or backups. For production databases, use an operator.

---

**Next: [Day 16 - Requests, limits and metrics-server](../day-16-resources-requests-limits-metrics-server/)**
