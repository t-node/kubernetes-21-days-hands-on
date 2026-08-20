# CKA 06 — Cluster Maintenance: Upgrades, Drains and etcd Backup/Restore

**Time:** 90-120 minutes
**Prerequisites:** [CKA 02](../02-etcd-and-cluster-data/), [Day 18](../../days/day-18-scheduling-taints-affinity-daemonsets/)

CKA 02 stopped short of backup and restore and said so. This day finishes it.

**Restoring etcd is the single most likely hands-on task on the exam.** It is
also the one people fail, because they practise `snapshot save` and never once
practise `snapshot restore`. You will do both.

---

## Part 1 - Concepts

### 6.1 What happens when a node goes away

```
node goes offline
      |
      +-- comes back within ~5 min --> kubelet restarts, pods resume
      |
      +-- stays down longer --------> pods are EVICTED and rescheduled
                                       ...if they belong to a controller
```

That five-minute window is the **pod eviction timeout**. Modern Kubernetes
implements it with taints rather than a single timer: the node controller adds
`node.kubernetes.io/unreachable:NoExecute` or `not-ready:NoExecute`, and pods
carry a default toleration with `tolerationSeconds: 300`. Same outcome, more
flexible mechanism — and you can change it per pod.

**The critical distinction:** a pod owned by a ReplicaSet, Deployment,
StatefulSet or DaemonSet is recreated elsewhere. **A bare pod is simply gone
forever.** Nothing owns it, so nothing rebuilds it.

That is why "is it a bare pod?" is the first question when a node dies.

### 6.2 cordon, drain, uncordon

| Command | Marks unschedulable | Evicts existing pods |
|---|---|---|
| `kubectl cordon <node>` | **yes** | no |
| `kubectl drain <node>` | **yes** | **yes** |
| `kubectl uncordon <node>` | reverses it | n/a |

`cordon` is just a taint — you saw this on Day 18:

```bash
kubectl cordon devops-worker
kubectl describe node devops-worker | grep -A3 Taints
# node.kubernetes.io/unschedulable:NoSchedule
```

The maintenance sequence, which you should be able to recite:

```
cordon -> drain -> patch/reboot/upgrade -> uncordon
```

Two flags `drain` almost always needs:

```bash
kubectl drain node01 --ignore-daemonsets --delete-emptydir-data
```

- **`--ignore-daemonsets`** — DaemonSet pods cannot be meaningfully evicted; the
  controller would immediately recreate them. Without this, drain refuses.
- **`--delete-emptydir-data`** — acknowledges that `emptyDir` contents are lost.
  Without it, drain refuses for any pod with one.
- **`--force`** — required for **bare pods**, and it means exactly what Day 6.1
  said: those pods are destroyed, not moved. Read the warning before typing it.

> **Pods do not come back on their own.** After `uncordon`, the node is merely
> *eligible* again. Workloads that moved stay where they are until something
> reschedules them. Expect an unbalanced cluster after a rolling node upgrade —
> that is normal, not a fault.

A **PodDisruptionBudget** (Day 18) makes `drain` block rather than take a
service below its floor. On a real cluster, drain hanging is usually a PDB doing
its job, not a bug.

### 6.3 Version numbers and the support window

```
v1.33.2
  │  │  └── patch  -- bug and security fixes, frequent
  │  └───── minor  -- new features, roughly every 3-4 months
  └──────── major
```

Kubernetes supports the **three most recent minor releases**. When 1.34 ships,
1.31 falls out of support — which is the natural trigger to upgrade.

Two things that are *not* on the Kubernetes version line: **etcd** and
**CoreDNS**. Both are separate projects with their own versions, and each
Kubernetes release note states which versions it expects. `kubeadm upgrade`
handles them for you.

### 6.4 The version skew policy — memorise this table

Components may run at different versions, and that is what makes a live upgrade
possible. The rules are one-directional:

| Component | Allowed relative to `kube-apiserver` (N) |
|---|---|
| **kube-apiserver** | N — the reference point |
| kube-controller-manager, kube-scheduler | **N-1** |
| **kubelet**, kube-proxy | **N-3** (was N-2 before Kubernetes 1.28) |
| **kubectl** | **N+1 to N-1** |

> **Nothing may ever be *newer* than the API server**, with the single exception
> of `kubectl`, which may be one minor ahead.

This is why the upgrade order is fixed: **control plane first, workers second.**
Upgrading a kubelet past the API server is unsupported and will bite you.

### 6.5 Upgrade rules

**One minor version at a time.** 1.31 → 1.33 is not a supported jump; you do
1.31 → 1.32 → 1.33. Patch versions within a minor can be skipped freely.

**While the control plane is upgrading:** the API server, scheduler and
controller-manager are briefly down. Your **applications keep serving** — the
kubelets and running containers are untouched. What you lose is *management*:
no `kubectl`, no new deployments, and no self-healing, so a pod that dies during
the window stays dead until the control plane returns.

Three strategies for the worker nodes:

| Strategy | Downtime | Cost |
|---|---|---|
| All at once | **yes, full outage** | cheapest |
| One node at a time (drain, upgrade, uncordon) | none | slowest |
| Add new nodes, move workloads, retire old | none | needs spare capacity — **ideal on cloud** |

The second is what the exam asks for. The third is what you would do on EKS with
a node group.

### 6.6 kubeadm upgrade mechanics

Three facts that catch people out:

1. **You upgrade `kubeadm` itself first.** The tool follows the same version
   line, and it cannot upgrade a cluster to a version it does not know about.
2. **`kubeadm` never upgrades the kubelet.** It upgrades the control-plane
   components (which are static pods, so it swaps their images), then tells you
   to upgrade the kubelet package yourself with the OS package manager.
3. **`kubectl get nodes` shows the *kubelet* version, not the API server's.**
   After upgrading the control plane, that column still reads the old version
   until you upgrade the kubelet on that node. This confuses everyone once.

```bash
kubeadm upgrade plan                 # what can I upgrade to, and what will it touch
kubeadm upgrade apply v1.33.2        # control-plane node
kubeadm upgrade node                 # every OTHER node -- different subcommand
```

The full sequence per node:

```bash
# --- control plane node ---
apt-mark unhold kubeadm && apt-get install -y kubeadm=1.33.2-1.1 && apt-mark hold kubeadm
kubeadm upgrade plan
kubeadm upgrade apply v1.33.2

kubectl drain <cp-node> --ignore-daemonsets
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.33.2-1.1 kubectl=1.33.2-1.1
apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
kubectl uncordon <cp-node>

# --- each worker node ---
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
#   (on the node itself:)
apt-mark unhold kubeadm && apt-get install -y kubeadm=1.33.2-1.1 && apt-mark hold kubeadm
kubeadm upgrade node                          # NOT `upgrade apply`
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.33.2-1.1 kubectl=1.33.2-1.1
apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet
#   (back on your machine:)
kubectl uncordon <node>
```

`apt-mark hold` exists because these packages must **never** be upgraded by a
routine `apt upgrade`. Unhold, pin an exact version, re-hold.

Since Kubernetes 1.28 the packages come from version-specific repositories
(`pkgs.k8s.io/core:/stable:/v1.33/deb/`), so moving between minor versions also
means **editing the apt source list**. Miss that and `apt-cache madison kubeadm`
will not even list the version you want.

### 6.7 What to back up, and how

Three things exist in a cluster, and they need different treatment:

| What | Backup method |
|---|---|
| **Object definitions** | your manifests, in **git** — the real answer |
| **Cluster state** | **etcd snapshot**, or querying the API |
| **Application data** | PersistentVolume snapshots (CSI), or app-level dumps |

**Manifests in git is the primary strategy.** If every object was created
declaratively and committed, losing the cluster costs you a `kubectl apply`, not
a restore. That is the whole argument for the discipline the main track has been
pushing for 21 days.

The problem is people. Someone runs `kubectl create secret` imperatively and
never writes it down. So back up the **live state** as well:

```bash
kubectl get all --all-namespaces -o yaml > cluster-backup.yaml
```

Be honest about what that misses: `get all` covers a surprisingly small set of
kinds — no ConfigMaps, Secrets, PVCs, RBAC, CRDs or Ingresses. A real script
enumerates `kubectl api-resources` and loops. Which is exactly why
**[Velero](https://velero.io)** exists: it queries the API for everything,
handles PV snapshots, supports scheduled and selective restores, and is the
standard answer to "how do you back up a cluster?"

**On managed Kubernetes (EKS, GKE, AKS) you cannot reach etcd at all** — the
control plane is the provider's. There, API-level backup with Velero is the
*only* option, and that is a good thing to say out loud in an interview.

### 6.8 etcd snapshot and restore

```bash
ETCDCTL_API=3 etcdctl snapshot save /opt/snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Restore is where the real understanding is:

```bash
etcdutl snapshot restore /opt/snapshot.db --data-dir=/var/lib/etcd-from-backup
```

**Restore does not load data into a running etcd.** It writes a **brand-new data
directory** from the snapshot, and it deliberately gives the restored member a
**new cluster ID and member ID** — so a restored node cannot accidentally rejoin
the cluster it came from and corrupt it. You then point etcd at that new
directory.

Consequences worth stating:

- The target `--data-dir` must **not already exist**.
- Your existing data directory is left untouched, which means **the restore is
  reversible**: point the config back and you are where you started.
- Restoring is therefore always safe to *attempt*.

The full procedure on a kubeadm cluster:

```
1. save the snapshot                    etcdctl snapshot save
2. restore it to a NEW directory        etcdutl snapshot restore --data-dir=...
3. edit /etc/kubernetes/manifests/etcd.yaml
      -> change the hostPath volume to the new directory
4. the kubelet notices and recreates the etcd static pod
5. the API server reconnects; verify
```

**Step 3 is the one people get wrong.** You change the **`hostPath` volume**,
not the `--data-dir` flag. The flag is a *container* path and stays
`/var/lib/etcd`; the hostPath is what maps it to real storage on the node.

> ### A version trap
>
> In etcd **3.5+**, `snapshot restore` and `snapshot status` moved to a separate
> binary, **`etcdutl`**. `etcdctl snapshot restore` still works but prints a
> deprecation warning; in some builds it is removed. If `etcdctl snapshot
> restore` complains, use `etcdutl`. `snapshot save` stays on `etcdctl`, because
> it needs to talk to a live server.
>
> `save` needs `--endpoints` and certificates. `restore` **does not** — it only
> reads a file.

For a multi-member etcd you also pass `--name`, `--initial-cluster` and
`--initial-advertise-peer-urls` on restore, matching each member. Single-member
restores need none of it.

---

## Part 2 - Hands-on lab

### Step 1: Node maintenance, with the app watching

Terminal 1 — watch for outages using the Day 05 script:

```bash
bash ../../days/day-05-rolling-updates-and-rollbacks/solution/rollout-watch.sh
```

Terminal 2:

```bash
kubectl get pods -n devboard -o wide
kubectl cordon devops-worker
kubectl get nodes                      # Ready,SchedulingDisabled
```

Nothing moved — `cordon` only affects **future** scheduling. Now drain it:

```bash
kubectl drain devops-worker --ignore-daemonsets --delete-emptydir-data
kubectl get pods -n devboard -o wide   # nothing on devops-worker
```

Check terminal 1: with two replicas spread across nodes and a PDB in place, you
should see no `X`. That is a **zero-downtime node evacuation**.

```bash
kubectl uncordon devops-worker
kubectl get pods -n devboard -o wide
```

**The pods did not come back.** The node is schedulable again, nothing more.
Force a rebalance:

```bash
kubectl rollout restart deployment/frontend -n devboard
kubectl get pods -n devboard -o wide
```

### Step 2: Watch a drain get blocked

```bash
kubectl apply -f ../../days/day-18-scheduling-taints-affinity-daemonsets/solution/06-pdb.yaml
kubectl get pdb -n devboard

kubectl scale deployment backend --replicas=1 -n devboard
NODE=$(kubectl get pod -n devboard -l app=backend -o jsonpath='{.items[0].spec.nodeName}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

```
error when evicting pod "backend-..." (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
```

**The PDB did its job.** `minAvailable: 1` with only one replica means evicting
it is refused. This is the correct behaviour and a common exam scenario — the
fix is to scale up, not to force.

```bash
kubectl scale deployment backend --replicas=2 -n devboard
kubectl rollout status deployment/backend -n devboard
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
kubectl uncordon "$NODE"
```

### Step 3: A bare pod, and why `--force` is a warning

```bash
kubectl run orphan --image=nginx:alpine -n devboard
NODE=$(kubectl get pod orphan -n devboard -o jsonpath='{.spec.nodeName}')

kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

```
cannot delete Pods declared by ReplicationController, ... or StatefulSet
(use --force to override)
```

Drain refuses because it knows the pod cannot be recreated. With `--force`:

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
kubectl get pod orphan -n devboard
# NotFound -- permanently gone
kubectl uncordon "$NODE"
```

**`--force` means "destroy anything that cannot be rescheduled".** Check for
bare pods before typing it.

### Step 4: Read the version skew on your own cluster

```bash
kubectl version
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,\
PROXY:.status.nodeInfo.kubeProxyVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
```

Now the API server's own version, which is **not** what `get nodes` showed:

```bash
kubectl get --raw /version
docker exec devops-control-plane sh -c \
  "grep image: /etc/kubernetes/manifests/kube-apiserver.yaml"
docker exec devops-control-plane sh -c \
  "grep image: /etc/kubernetes/manifests/etcd.yaml"
```

Note etcd carries **its own version line** — 3.5.x, unrelated to 1.31.x.

On a kubeadm cluster you would now run:

```bash
docker exec devops-control-plane kubeadm upgrade plan
```

On kind that reports what it *would* do. Read the output — it names every
component, its current and target version, and reminds you that **kubelets must
be upgraded manually**. Actually upgrading a kind cluster is not worth doing;
you would recreate it with a newer node image instead:

```bash
# how you would "upgrade" kind: new node image, new cluster
kind create cluster --config cluster/kind-config.yaml   # after editing the image tag
```

### Step 5: Take an etcd snapshot

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- sh -c \
  "ETCDCTL_API=3 etcdctl snapshot save /var/lib/etcd/snapshot.db \
   --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key"
```

It is written inside the mounted data directory, so it is also on the node:

```bash
docker exec devops-control-plane ls -lh /var/lib/etcd/snapshot.db
```

Inspect it — note this is `etcdutl`, not `etcdctl`, on etcd 3.5+:

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- \
  etcdutl snapshot status /var/lib/etcd/snapshot.db --write-out=table
```

```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 8f2b1c04 |    41827 |       1214 |     4.9 MB |
+----------+----------+------------+------------+
```

**`TOTAL KEYS` is your sanity check.** A snapshot with a handful of keys is a
snapshot of nothing.

Get it off the node — a backup on the machine you are backing up is not a
backup:

```bash
docker cp devops-control-plane:/var/lib/etcd/snapshot.db /tmp/etcd-snapshot.db
ls -lh /tmp/etcd-snapshot.db
```

### Step 6: The restore drill

This is the exercise that matters. **kind is the ideal place to do it** — if it
goes wrong, `bash cluster/recreate-cluster.sh` gives you a fresh cluster in
90 seconds. Do it here so you never do it first on something real.

**Create a marker so you can prove the restore worked:**

```bash
kubectl create namespace before-snapshot
kubectl get ns | grep -E "before-snapshot|devboard"
```

**Take a fresh snapshot that includes it:**

```bash
bash solution/etcd-snapshot.sh
```

**Now change the cluster *after* the snapshot:**

```bash
kubectl create namespace after-snapshot
kubectl delete namespace before-snapshot
kubectl get ns | grep -E "before-snapshot|after-snapshot"
# after-snapshot exists, before-snapshot is gone
```

**Restore, and expect the reverse:**

```bash
bash solution/etcd-restore.sh
```

That script does the four steps from section 6.8. Watch the control plane come
back:

```bash
for i in $(seq 1 30); do kubectl get ns >/dev/null 2>&1 && break; echo "waiting..."; sleep 5; done
kubectl get ns | grep -E "before-snapshot|after-snapshot"
```

```
before-snapshot   Active      <-- back from the dead
                              <-- after-snapshot is GONE
```

**You have travelled the cluster back in time.** `before-snapshot` returned;
`after-snapshot`, created after the snapshot, never existed as far as the
restored etcd is concerned.

Confirm the application survived — its pods were never touched, because kubelets
kept them running throughout:

```bash
kubectl get pods -n devboard
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080
```

Clean up:

```bash
kubectl delete namespace before-snapshot --ignore-not-found
```

> **If the API server does not come back within ~3 minutes**, read
> `solution/etcd-restore.sh`'s rollback note — the old data directory is still
> there and pointing the manifest back restores the original state. Failing
> that, `bash cluster/recreate-cluster.sh`.

### Step 7: Back up by querying the API

The other strategy, and the only one on managed Kubernetes:

```bash
kubectl get all --all-namespaces -o yaml > /tmp/cluster-all.yaml
wc -l /tmp/cluster-all.yaml
```

Now see what it missed:

```bash
grep -c "kind: ConfigMap" /tmp/cluster-all.yaml || echo "ConfigMaps: 0"
grep -c "kind: Secret"    /tmp/cluster-all.yaml || echo "Secrets: 0"
grep -c "kind: Ingress"   /tmp/cluster-all.yaml || echo "Ingresses: 0"
```

**`get all` does not mean all.** It covers pods, services, deployments,
replicasets, statefulsets, daemonsets and jobs — and nothing else. A real
backup enumerates every namespaced kind:

```bash
bash solution/backup-by-api.sh
ls -la /tmp/cluster-backup/
```

Compare the two approaches:

| | etcd snapshot | API query |
|---|---|---|
| Completeness | **everything, exactly** | only what you enumerate |
| Works on EKS/GKE/AKS | **no** | **yes** |
| Restore granularity | whole cluster only | per object |
| Speed | seconds | minutes on a big cluster |
| Needs control-plane access | **yes** | no |

---

## Validate

```bash
# node maintenance
kubectl cordon devops-worker && kubectl get nodes | grep SchedulingDisabled
kubectl uncordon devops-worker

# snapshot, with a real key count
bash solution/etcd-snapshot.sh
kubectl -n kube-system exec etcd-devops-control-plane -- \
  etcdutl snapshot status /var/lib/etcd/snapshot.db --write-out=table

# and the one that counts -- a completed restore drill
kubectl create namespace restore-proof
bash solution/etcd-snapshot.sh
kubectl delete namespace restore-proof
bash solution/etcd-restore.sh
sleep 60
kubectl get ns restore-proof          # it is back
kubectl delete ns restore-proof
```

You are done when you can answer, without looking:

1. What is the maximum version skew for the kubelet relative to the API server?
2. Which is the only component allowed to be *newer* than the API server?
3. Why does `kubectl get nodes` still show the old version after upgrading the
   control plane?
4. What does `kubeadm upgrade` deliberately **not** upgrade?
5. Why does `snapshot restore` need a directory that does not yet exist?
6. Which file do you edit to point etcd at a restored data directory, and which
   field inside it?
7. Why can you not take an etcd snapshot on EKS?

---

## Break it

**A. Drain without `--ignore-daemonsets`.**

```bash
kubectl drain devops-worker --delete-emptydir-data
# error: cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore)
kubectl uncordon devops-worker
```

**B. Restore into a directory that already exists.**

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- \
  etcdutl snapshot restore /var/lib/etcd/snapshot.db --data-dir=/var/lib/etcd
# Error: data-dir "/var/lib/etcd" exists
```

Deliberate. Restoring over a live data directory would destroy the thing you
might still need to fall back to.

**C. Point the API server at a restored etcd but forget the hostPath.**

Edit `--data-dir` in `etcd.yaml` instead of the `hostPath` volume. The container
now writes to a path that is not backed by the restored directory, etcd
initialises an **empty** database, and `kubectl get ns` returns almost nothing.
The cluster is up and blank — far more alarming than a clean failure.

The fix is the same either way: correct the manifest, wait for the kubelet.

**D. Snapshot with the wrong certificates.**

```bash
kubectl -n kube-system exec etcd-devops-control-plane -- sh -c \
  "ETCDCTL_API=3 etcdctl snapshot save /tmp/x.db --endpoints=https://127.0.0.1:2379" 2>&1 | tail -3
```

A TLS error. `snapshot save` talks to a live server and **always** needs
`--cacert`, `--cert` and `--key`. `snapshot restore` never does — it only reads
a file. Knowing which needs what saves a minute under pressure.

**E. Skip a minor version.**

`kubeadm upgrade apply v1.35.0` from a 1.31 cluster is refused. One minor at a
time, always.

---

## Exam-style tasks

Timed. These are close to the real thing.

1. Take a snapshot of etcd to `/opt/etcd-backup.db` and report its total key
   count. *(5 min)*
2. Node `devops-worker` needs an OS patch. Evacuate it safely without taking the
   DevBoard app down, then return it to service. *(5 min)*
3. A namespace was deleted by mistake. A snapshot from before the deletion is at
   `/opt/etcd-backup.db`. Restore the cluster. *(15 min)*
4. Report the API server version, the kubelet version on every node, and state
   whether the skew is supported. *(3 min)*
5. Back up every ConfigMap and Secret in every namespace to a single file, using
   only the API. *(4 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# node maintenance
kubectl cordon   node01
kubectl drain    node01 --ignore-daemonsets --delete-emptydir-data
kubectl drain    node01 --ignore-daemonsets --delete-emptydir-data --force  # kills BARE PODS
kubectl uncordon node01

# etcd snapshot -- needs endpoint + 3 certs
ETCDCTL_API=3 etcdctl snapshot save /opt/snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# status + restore -- etcdutl on 3.5+, and NO certs needed
etcdutl snapshot status  /opt/snapshot.db --write-out=table
etcdutl snapshot restore /opt/snapshot.db --data-dir=/var/lib/etcd-from-backup

# then edit the HOSTPATH VOLUME in /etc/kubernetes/manifests/etcd.yaml:
#   volumes: - hostPath: { path: /var/lib/etcd-from-backup }
# the kubelet recreates the pod by itself -- nothing to restart

# upgrades
kubeadm upgrade plan
kubeadm upgrade apply v1.33.2      # control plane node
kubeadm upgrade node               # every other node
apt-mark unhold kubelet kubectl && apt-get install -y kubelet=1.33.2-1.1 && apt-mark hold kubelet kubectl
systemctl daemon-reload && systemctl restart kubelet

# api-level backup
kubectl get all -A -o yaml > backup.yaml       # INCOMPLETE -- see 6.7
```

| Component | Skew vs `kube-apiserver` (N) |
|---|---|
| controller-manager, scheduler | N-1 |
| **kubelet, kube-proxy** | **N-3** (N-2 before 1.28) |
| **kubectl** | **N+1 to N-1** — the only one allowed to be newer |

**Order:** control plane, then workers. **One minor version at a time.**
**`kubeadm` never upgrades the kubelet.**

---

**Back to the [CKA track](../) · [Main course](../../README.md)**
