# Day 14 — Volumes, PersistentVolumes & PersistentVolumeClaims

**Time:** 75-90 minutes
**Prerequisites:** Days 11-13

Since Day 11 you have lost your data every time the Postgres pod restarted.
Today you fix that, and learn the storage model that every stateful workload on
Kubernetes depends on.

---

## Part 1 - Concepts

### 14.1 The problem, restated

Containers are ephemeral, and so is their filesystem. Delete the pod, and
everything written inside the container is gone. You have felt this repeatedly:

```bash
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('will not survive', 1);"
kubectl delete pod -n devboard -l app=postgres
# ...wait for the new pod...
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "SELECT * FROM tasks WHERE title='will not survive';"      # (0 rows)
```

Docker solves this with `-v /host/path:/container/path`. That works because
there is exactly one host. In a cluster the pod might restart **on a different
node**, where that path does not exist or holds different data.

Kubernetes therefore separates *what the pod asks for* from *what physically
provides it*.

### 14.2 The volume types you will actually meet

| Type | Lives as long as | Use |
|---|---|---|
| `emptyDir` | **the pod** | scratch space, caches, sharing between containers in a pod |
| `hostPath` | the node | node-level agents only. **A security risk in apps** |
| `configMap` / `secret` | the pod | config and credentials as files (Days 09-10) |
| `persistentVolumeClaim` | **independent of the pod** | **anything that must survive** |
| `projected` | the pod | combine several sources into one directory |
| CSI drivers | the storage system | EBS, Cloud Disk, Ceph, NFS... |

**`hostPath` deserves a warning.** It mounts a path from the node into the pod.
It is how monitoring agents read `/var/log`, and it is also a straightforward
privilege escalation: mount `/var/run/docker.sock` or `/etc/kubernetes` and you
own the node. Modern clusters block it with Pod Security admission. Never use it
for application data.

### 14.3 The PV / PVC split

Two objects, deliberately separated by *who owns them*:

| | **PersistentVolume (PV)** | **PersistentVolumeClaim (PVC)** |
|---|---|---|
| Is | a piece of storage in the cluster | a *request* for storage |
| Scope | **cluster-scoped** (no namespace) | **namespaced** |
| Owned by | the cluster administrator, or a provisioner | the application developer |
| Analogy | an available apartment | a rental application |

A pod references a **PVC**, never a PV. That indirection is the point: the
developer says "I need 5Gi of ReadWriteOnce storage" and does not care whether
it is EBS, Ceph or a directory on a node.

```
Pod
 └── volumes:
      └── persistentVolumeClaim: { claimName: postgres-data }
                                        |
                                     PVC "postgres-data"   (namespaced)
                                     5Gi, RWO, storageClass: standard
                                        |  binds to
                                     PV  "pvc-8a3f..."     (cluster-scoped)
                                        |  backed by
                                     an actual disk / directory / EBS volume
```

### 14.4 Static vs dynamic provisioning

**Static:** an administrator creates PVs in advance; a PVC binds to one that
fits. Rare now, but understanding it makes the model clear, so you will do it
once today.

**Dynamic:** the PVC names a **StorageClass**, and a provisioner creates a PV on
demand. This is how essentially all real clusters work.

```bash
kubectl get storageclass
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

kind ships `local-path` as the default StorageClass. On EKS it would be
`gp2`/`gp3` via the EBS CSI driver.

Note **`VOLUMEBINDINGMODE: WaitForFirstConsumer`** — it matters. The PV is not
created until a pod actually needs it, so the provisioner can place the volume
on the node where the pod was scheduled. With `Immediate`, the volume might be
created in an availability zone the pod cannot reach. This is why a freshly
created PVC sits in `Pending` with no error: it is waiting for a consumer, and
that is correct.

### 14.5 Access modes — and the thing everyone gets wrong

| Mode | Short | Meaning |
|---|---|---|
| `ReadWriteOnce` | RWO | read-write by **one node** |
| `ReadOnlyMany` | ROX | read-only by many nodes |
| `ReadWriteMany` | RWX | read-write by many nodes |
| `ReadWriteOncePod` | RWOP | read-write by exactly **one pod** (1.22+) |

> **`ReadWriteOnce` means one NODE, not one POD.** Several pods on the *same
> node* can mount the same RWO volume simultaneously. This surprises people, and
> it is exactly why two Postgres replicas scheduled to one node can corrupt a
> data directory. `ReadWriteOncePod` is the mode that genuinely guarantees one
> writer.

Most block storage (EBS, local disks) is RWO only. RWX needs a shared
filesystem: NFS, EFS, CephFS, Azure Files.

### 14.6 Reclaim policy — what happens when the PVC is deleted

| Policy | Effect |
|---|---|
| `Delete` | the PV **and the underlying storage** are deleted. Default for dynamic provisioning |
| `Retain` | the PV survives with status `Released`; data is kept; an admin must clean up manually |
| `Recycle` | deprecated, gone |

**Default `Delete` plus `kubectl delete pvc` equals data gone, immediately, with
no confirmation.** For anything you care about, use a StorageClass with
`reclaimPolicy: Retain`. You will do exactly this in Break It, on purpose.

### 14.7 The PVC lifecycle

```
Pending  ──▶  Bound  ──▶  (pod uses it)  ──▶  Released  ──▶  Deleted/Retained
   │            │
   │            └── a matching PV was found or provisioned
   │
   └── waiting for a consumer (WaitForFirstConsumer), or
       no PV matches size/accessMode/storageClass, or
       no provisioner exists for the named StorageClass
```

`Pending` is the state you will debug most. `kubectl describe pvc` names the
reason.

### 14.8 Why this still is not enough for a database

You are about to give Postgres a real PVC and its data will survive pod deletes.
But a Deployment still has one PVC shared by the whole template, so:

- Scale to 2 and both pods try to mount the same volume.
- If they land on one node, both mount it — **and corrupt the data directory**.
- If they land on different nodes, the second stays `Pending` forever with
  `Multi-Attach error`.

Storage alone does not make a workload stateful-safe. That is tomorrow.

---

## Part 2 - Hands-on lab

### Step 1: Prove the data loss one more time

```bash
kubectl apply -f ../day-12-wire-the-three-tier-app/solution/
kubectl rollout status deployment/postgres -n devboard

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id, status) VALUES ('before the delete', 1, 'todo');"
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks;"        # 11

kubectl delete pod -n devboard -l app=postgres
kubectl rollout status deployment/postgres -n devboard
sleep 10

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks;"        # 10  -- back to the seed
```

Eleven, then ten. Your row is gone. Fix it.

### Step 2: Look at what the cluster offers

```bash
kubectl get storageclass
kubectl describe storageclass standard
kubectl get pv          # probably empty
kubectl get pvc -A
```

### Step 3: A PVC, and the Pending state that is not an error

```bash
kubectl apply -f solution/01-postgres-pvc.yaml
kubectl get pvc -n devboard
```

```
NAME            STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
postgres-data   Pending                                      standard
```

`Pending`, and that is **correct**:

```bash
kubectl describe pvc postgres-data -n devboard | tail -5
# waiting for first consumer to be created before binding
```

`WaitForFirstConsumer` from section 14.4. No pod uses it yet, so no volume has
been provisioned. Learn to recognise this message — it is not a failure.

### Step 4: Give Postgres the PVC

```bash
kubectl apply -f solution/02-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n devboard

kubectl get pvc,pv -n devboard
```

```
NAME            STATUS   VOLUME                CAPACITY   ACCESS MODES   STORAGECLASS
postgres-data   Bound    pvc-3f8a92e1-...      2Gi        RWO            standard

NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
pvc-3f8a92e1-...   2Gi        RWO            Delete           Bound    devboard/postgres-data
```

`Bound`. A PV was created automatically and the pod is using it.

Note two things in the PV:

- **`RECLAIM POLICY: Delete`** — deleting the PVC destroys the data. Remember
  this for Break It.
- **`CLAIM: devboard/postgres-data`** — the PV is cluster-scoped, so it names
  the claim with its namespace.

Confirm the mount inside the pod, and see the subdirectory trick paying off:

```bash
kubectl exec -n devboard deploy/postgres -- df -h /var/lib/postgresql/data
kubectl exec -n devboard deploy/postgres -- ls -la /var/lib/postgresql/data
# lost+found  and  pgdata/    <- exactly why PGDATA points one level down
kubectl exec -n devboard deploy/postgres -- ls /var/lib/postgresql/data/pgdata | head
```

If `PGDATA` had pointed at the mount root, `initdb` would have refused because
of `lost+found`. Section 11.3, now concrete.

### Step 5: The moment of truth

```bash
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id, status, priority)
      VALUES ('I will survive', 1, 'done', 'high');"

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks;"          # 11

kubectl delete pod -n devboard -l app=postgres
kubectl rollout status deployment/postgres -n devboard
sleep 10

kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "SELECT id,title,status FROM tasks WHERE title='I will survive';"
```

**It is still there.** Different pod, different IP, same data.

Now the stronger test — delete the whole Deployment:

```bash
kubectl delete deployment postgres -n devboard
kubectl get pvc -n devboard                    # STILL BOUND. The PVC outlives it.

kubectl apply -f solution/02-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n devboard
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks;"           # 11 -- your row survived
```

Note the logs on that restart:

```bash
kubectl logs -n devboard -l app=postgres --tail=20 | head
```

No `initdb`, no `01_schema.sql`, no seeding — the data directory was not empty,
so the entrypoint skipped all of it. **This is section 11.2 in the other
direction:** with a real PV, your init scripts run exactly once, ever. Adding a
new SQL file to the ConfigMap now does nothing at all. Schema changes from here
on need a migration, not an init script.

Check the UI at <http://localhost:30080> — your task is on the board.

### Step 6: Static provisioning, once, to understand the model

Dynamic provisioning hides the PV. Create one by hand so you have seen it:

```bash
kubectl apply -f solution/03-static-pv.yaml
kubectl get pv manual-pv
# STATUS: Available

kubectl apply -f solution/04-static-pvc.yaml
kubectl get pv,pvc -n devboard | grep -E "manual|static"
# manual-pv -> Bound to devboard/static-claim
```

The binding happened because **every** attribute matched: `storageClassName`
(`manual` on both), size (the PVC asks for no more than the PV offers), and
access mode. Change any one and it stays `Pending` forever.

Note the PV is `hostPath` — fine for a single-node demo, wrong for anything
real, because the data lives on one specific node.

```bash
kubectl delete -f solution/04-static-pvc.yaml
kubectl get pv manual-pv          # STATUS: Released (not Available!)
```

**`Released` is not reusable.** With `reclaimPolicy: Retain` the PV keeps the
old claim reference, so no new PVC can bind to it until an administrator clears
`spec.claimRef`. That is a deliberate safety interlock against another team's
PVC silently binding to your data.

```bash
kubectl patch pv manual-pv -p '{"spec":{"claimRef":null}}'
kubectl get pv manual-pv          # Available again
kubectl delete pv manual-pv
```

### Step 7: Resize a PVC

Most CSI drivers support online expansion.

```bash
kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}{"\n"}'

kubectl patch pvc postgres-data -n devboard \
  -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'

kubectl get pvc postgres-data -n devboard
kubectl describe pvc postgres-data -n devboard | tail -5
```

Two rules: **you can grow a PVC, never shrink it**, and the StorageClass must
have `allowVolumeExpansion: true`. Some drivers need a pod restart to grow the
filesystem; `local-path` on kind is a directory on the node, so the reported
size is somewhat notional.

---

## Validate

```bash
kubectl apply -f solution/01-postgres-pvc.yaml
kubectl apply -f solution/02-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n devboard --timeout=180s

kubectl get pvc postgres-data -n devboard -o jsonpath='{.status.phase}{"\n"}'   # Bound
kubectl get pv | grep devboard/postgres-data

# write, destroy, verify
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('validate-day14', 1);"
kubectl delete pod -n devboard -l app=postgres
kubectl rollout status deployment/postgres -n devboard --timeout=120s
sleep 10
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks WHERE title='validate-day14';"     # 1
```

Ready for Day 15 when you can:

1. Explain PV vs PVC and which is namespaced.
2. Say what `ReadWriteOnce` actually restricts.
3. Explain why a new PVC sits in `Pending` with `WaitForFirstConsumer`.
4. Say what `reclaimPolicy: Delete` costs you.

---

## Break it

**A. Two Postgres replicas on one PVC — corruption or deadlock.**

```bash
kubectl scale deployment postgres --replicas=2 -n devboard
kubectl get pods -n devboard -l app=postgres -o wide
```

Two outcomes, both instructive:

- **Different nodes:** the second pod is stuck `ContainerCreating` forever.
  ```bash
  kubectl describe pod -n devboard -l app=postgres | grep -i -A3 "multi-attach\|FailedAttachVolume"
  ```
  `Multi-Attach error for volume ... Volume is already exclusively attached`.
  RWO doing its job.

- **Same node** (likely on kind with `local-path`): **both mount it**, because
  RWO means one *node*, not one *pod*. Two postmasters on one data directory.
  Postgres usually protects itself with a lock file:
  ```bash
  kubectl logs -n devboard -l app=postgres --tail=20 | grep -i "lock\|another"
  ```
  Other databases are not so careful. This is the case `ReadWriteOncePod` exists
  for.

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
```

**B. Delete the PVC and lose everything.**

Do this deliberately, once, so the reflex sticks.

```bash
kubectl get pv | grep postgres          # note: RECLAIM POLICY = Delete

kubectl delete deployment postgres -n devboard
kubectl delete pvc postgres-data -n devboard

kubectl get pv                          # the PV is gone too
```

The PVC, the PV and the data — all gone, with no confirmation prompt.

```bash
kubectl apply -f solution/01-postgres-pvc.yaml
kubectl apply -f solution/02-postgres-deployment-pvc.yaml
kubectl rollout status deployment/postgres -n devboard
kubectl exec -n devboard deploy/postgres -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks;"    # 10 -- a brand new database
```

Then protect against it:

```bash
kubectl apply -f solution/05-storageclass-retain.yaml
kubectl get storageclass
```

Anything using `standard-retain` keeps its PV as `Released` when the PVC goes,
so the data is recoverable. **Use a Retain class for every database you care
about.**

**C. Ask for a StorageClass that does not exist.**

```bash
kubectl apply -f solution/06-pvc-bad-storageclass.yaml
kubectl get pvc bad-class -n devboard          # Pending
kubectl describe pvc bad-class -n devboard | tail -5
# storageclass.storage.k8s.io "fast-ssd" not found
kubectl delete -f solution/06-pvc-bad-storageclass.yaml
```

**D. Ask for more than any PV offers (static binding).**

```bash
kubectl apply -f solution/03-static-pv.yaml           # offers 1Gi
kubectl apply -f solution/07-pvc-too-big.yaml         # asks for 50Gi
kubectl get pvc too-big -n devboard                   # Pending forever
kubectl describe pvc too-big -n devboard | tail -3
kubectl delete -f solution/07-pvc-too-big.yaml -f solution/03-static-pv.yaml
```

**E. Try to shrink a PVC.**

```bash
kubectl patch pvc postgres-data -n devboard \
  -p '{"spec":{"resources":{"requests":{"storage":"1Gi"}}}}'
# Forbidden: field can not be less than previous value
```

---

## Interview questions

<details>
<summary><b>1. Explain PV, PVC and StorageClass.</b></summary>

A PersistentVolume is a piece of storage in the cluster - cluster-scoped, and
either created by an administrator or provisioned dynamically. A
PersistentVolumeClaim is a namespaced request for storage: size, access mode,
class. A StorageClass describes a *kind* of storage and names the provisioner
that creates PVs on demand. Pods reference PVCs, never PVs, so developers ask
for capability without knowing the implementation.
</details>

<details>
<summary><b>2. Is a PersistentVolume namespaced?</b></summary>

No, it is cluster-scoped; adding `metadata.namespace` is silently ignored. The
PVC that binds to it is namespaced, and a pod may only use a PVC from its own
namespace. This split is a common interview question.
</details>

<details>
<summary><b>3. What does ReadWriteOnce actually mean?</b></summary>

Read-write by a single **node**, not a single pod. Multiple pods scheduled to
the same node can mount the same RWO volume simultaneously, which is exactly how
two database replicas end up writing one data directory. `ReadWriteOncePod`,
added in 1.22, is the mode that guarantees a single pod.
</details>

<details>
<summary><b>4. A PVC is stuck in Pending. Walk me through it.</b></summary>

`kubectl describe pvc` and read the events. If it says "waiting for first
consumer", that is normal for `WaitForFirstConsumer` binding mode and it will
bind when a pod uses it. Otherwise: the named StorageClass does not exist, no
provisioner is running, no static PV matches on size, access mode or class, or
the cloud quota is exhausted. With static PVs, every attribute must match, not
just size.
</details>

<details>
<summary><b>5. What is WaitForFirstConsumer and why does it exist?</b></summary>

It delays PV creation until a pod that uses the PVC is scheduled, so the volume
can be provisioned in the same topology - the right availability zone or the
right node - as the pod. With `Immediate` binding, the volume can be created
somewhere the pod cannot be scheduled, producing a pod that is permanently
unschedulable.
</details>

<details>
<summary><b>6. What happens when you delete a PVC?</b></summary>

It depends on the PV's reclaim policy. With `Delete`, the default for dynamic
provisioning, the PV and the underlying storage are destroyed immediately and
irreversibly. With `Retain`, the PV survives in `Released` state with the data
intact, and an administrator must clear the `claimRef` before it can be reused.
Use a Retain StorageClass for anything you cannot afford to lose.
</details>

<details>
<summary><b>7. Can you resize a PVC?</b></summary>

You can grow one if the StorageClass sets `allowVolumeExpansion: true` and the
driver supports it - edit `spec.resources.requests.storage`. You cannot shrink
one; the API rejects it. Some drivers expand the filesystem online, others
require a pod restart.
</details>

<details>
<summary><b>8. When is hostPath acceptable?</b></summary>

Essentially only for node-level system components that must read node state -
log collectors reading `/var/log`, monitoring agents reading `/proc`. For
application data it is both fragile, because data is tied to one node, and a
security risk, because mounting paths like the container runtime socket enables
node takeover. Pod Security admission blocks it in restricted namespaces.
</details>

<details>
<summary><b>9. How would you back up a PVC?</b></summary>

Application-consistent backup is the strong answer: for Postgres, `pg_dump` or
`pg_basebackup` plus WAL archiving from a CronJob to object storage. At the
infrastructure level, CSI VolumeSnapshots give point-in-time copies but only
crash-consistent ones unless you quiesce writes first. Velero is the common
cluster-wide tool, combining object backup with volume snapshots. Whatever you
pick, test restores.
</details>

---

## Cheat card

```bash
kubectl get storageclass
kubectl get pv                                  # cluster-scoped: no -n
kubectl get pvc -n devboard
kubectl describe pvc postgres-data -n devboard  # WHY is it Pending

# what is a pod actually mounting?
kubectl get pod <pod> -n devboard -o jsonpath='{.spec.volumes}'
kubectl exec -n devboard deploy/postgres -- df -h /var/lib/postgresql/data

# grow (never shrink)
kubectl patch pvc postgres-data -n devboard \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'

# release a Retained PV for reuse
kubectl patch pv <pv> -p '{"spec":{"claimRef":null}}'
```

| Object | Scope | Created by |
|---|---|---|
| StorageClass | cluster | admin |
| PersistentVolume | cluster | admin or provisioner |
| PersistentVolumeClaim | **namespace** | developer |

| Access mode | Restricts to |
|---|---|
| RWO | one **node** |
| ROX | many nodes, read-only |
| RWX | many nodes, read-write (needs a shared filesystem) |
| RWOP | one **pod** |

---

**Next: [Day 15 - StatefulSets and headless Services](../day-15-statefulsets-and-headless-services/)**
