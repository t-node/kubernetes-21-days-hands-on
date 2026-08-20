# CKA 26 — Cluster Design and High Availability

**Time:** 90-110 minutes
**Prerequisites:** [CKA 01](../01-control-plane-components/), [CKA 03](../03-etcd-and-cluster-data/), [CKA 12](../12-cluster-maintenance/)
**Source lectures:** 239, 240, 241, 242

Every cluster you have used so far has one control-plane node. This assignment
builds a **three-control-plane cluster**, watches leader election move, and takes
etcd below quorum on purpose to see what that actually looks like.

---

## Part 1 - Concepts

### 26.1 The questions that decide the design

Before any YAML:

| Question | Changes |
|---|---|
| **Purpose** -- learning, dev, production? | one node, one control plane, or three |
| **Cloud or on-prem?** | managed service vs kubeadm vs a turnkey platform |
| **How many applications, of what kind?** | node size and count, storage classes |
| **Traffic shape** -- steady or bursty? | autoscaling, over-provisioning, node sizing |
| **Who operates it?** | how much you are willing to run yourself |

The documented upper limits, worth knowing and almost never the real constraint:

| Limit | Value |
|---|---|
| nodes per cluster | **5,000** |
| pods per cluster | **150,000** |
| containers per cluster | 300,000 |
| **pods per node** | **110** (default `maxPods`, configurable) |

**You will hit etcd write throughput, API server memory, or your own
blast-radius tolerance long before 5,000 nodes.** The practical advice is the
opposite of these numbers: several medium clusters usually beat one enormous
one, because a cluster is a failure domain.

### 26.2 Managed, or your own

| | You run | You get |
|---|---|---|
| **Managed** (EKS, GKE, AKS) | worker nodes, workloads | the control plane, its HA, its upgrades, its backups |
| **kubeadm** | everything | full control, and every 3am page |
| **Turnkey** (OpenShift, Rancher) | the platform | an opinionated stack, plus its own upgrade cycle |

**The honest default for production is managed**, and the reason is not
technical difficulty — it is that control-plane HA, etcd backups, certificate
rotation and version upgrades are *ongoing* work that never appears on a
roadmap. If nobody's job description includes them, they will not happen.

**The exam is kubeadm**, and so is this assignment, because you cannot understand
what the managed service does for you without doing it once.

### 26.3 What actually breaks when the control plane dies

This is what motivates HA, and the answer is more nuanced than "everything".

**Keeps working:**

- **every running pod.** The kubelet does not need the API server to keep
  containers running.
- **Service traffic between pods.** kube-proxy's rules are already in the kernel
  ([CKA 23](../23-service-networking/)).
- **DNS**, as long as the CoreDNS pods are alive.
- **Ingress traffic**, for the same reason.

**Stops working:**

- **`kubectl`** — everything you do goes through the API server.
- **rescheduling.** A crashed pod is never replaced; a failed node's pods never
  move.
- **scaling**, rollouts, HPA.
- **every controller** — no ReplicaSet reconciliation, no endpoint updates, no
  certificate renewal.
- **new pods**, anywhere, for any reason.

**A cluster with a dead control plane looks healthy until something changes.**
Users notice nothing; then one pod crashes and never comes back, and failures
accumulate from there. That delay is exactly why the outage is often found late.

### 26.4 Two different HA models in one control plane

**The API server is stateless and runs active/active.** Every replica handles
requests independently, so you put a load balancer in front and point every
client at it:

```
   kubectl / kubelets / controllers
              |
        [ load balancer ]  :6443
         /       |       \
      api-1    api-2    api-3
```

**The scheduler and controller manager must not run in parallel.** Two schedulers
would place the same pod twice; two ReplicaSet controllers would create twice the
replicas. They run **active/passive**, decided by **leader election**:

```yaml
--leader-elect=true                      # the default
--leader-elect-lease-duration=15s
--leader-elect-renew-deadline=10s
--leader-elect-retry-period=2s
```

The mechanism is a **Lease object** in `kube-system`:

```bash
kubectl -n kube-system get lease
kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.holderIdentity}{"\n"}'
```

The holder renews every 10 seconds; the others retry every 2 seconds; if the
lease is not renewed within 15 seconds, someone else takes it.

> **Older material says "an Endpoints object".** Leader election used
> `Endpoints`, then `ConfigMap`, and now **`Lease`** in `coordination.k8s.io`.
> If a question mentions the endpoint, it is describing an older release — the
> concept is identical.

**All three replicas of the scheduler are running.** Two are idle, waiting. That
is not waste; it is a hot standby with a 15-second worst-case failover.

### 26.5 etcd, quorum, and why odd numbers

etcd uses **Raft**. One member is the leader; writes go to it and are replicated;
**a write completes when a majority has it.**

**Quorum = floor(N/2) + 1.**

| Members | Quorum | Can lose |
|---|---|---|
| 1 | 1 | **0** |
| 2 | 2 | **0** |
| **3** | **2** | **1** |
| 4 | 3 | 1 |
| **5** | **3** | **2** |
| 6 | 4 | 2 |
| **7** | **4** | **3** |

Two things fall out of that table:

**Two members are worse than useless.** Quorum is 2, so losing either breaks the
cluster — you have doubled the failure probability and gained nothing.

**Even numbers never buy fault tolerance.** Four tolerates the same single
failure as three, while adding a machine and slowing every write.

**The network partition argument is the real reason for odd numbers.** Split a
6-member cluster 3/3 and **neither side has quorum** — the cluster stops
entirely. Split a 7-member cluster and you get 4/3, and the majority keeps
working. An odd number cannot split evenly.

**Three is the normal answer; five if you must survive two simultaneous
failures.** Beyond five, every write must reach more members and latency rises
for no meaningful gain.

### 26.6 Stacked or external

```
  STACKED                          EXTERNAL
  +----------------+               +----------------+     +--------+
  | api  sched  cm |               | api  sched  cm |---->| etcd-1 |
  |      etcd      |               +----------------+     | etcd-2 |
  +----------------+               ...x3                  | etcd-3 |
  ...x3                                                   +--------+
  3 machines                       6 machines
```

| | Stacked | External |
|---|---|---|
| Machines | **3** | **6** |
| Setup | kubeadm does it | more steps, more certificates |
| Losing a node | loses a control plane **and** an etcd member | loses only one of them |
| Blast radius | coupled | **decoupled** |

**Stacked is the default and right for most clusters.** External earns its extra
three machines when etcd is under heavy load and you want to size it
independently, or when a compliance requirement puts the datastore on separate
hardware.

Either way, **the API server is the only component that talks to etcd**, and it
is given the full member list:

```
--etcd-servers=https://10.0.1.11:2379,https://10.0.1.12:2379,https://10.0.1.13:2379
```

### 26.7 What HA does not give you

Worth being blunt about, because it is where people are surprised:

| HA protects against | HA does **not** protect against |
|---|---|
| a node failing | **a bad `kubectl delete`** |
| a machine rebooting | **etcd data corruption** -- replicated instantly to every member |
| an AZ outage (if spread) | **a failed upgrade** applied to all members |
| a control-plane process crashing | **a certificate expiring** -- same date on every node |

**Replication is not backup.** Every member holds the same data, including the
data you just destroyed. The etcd snapshot from
[CKA 12](../12-cluster-maintenance/) is the only thing that protects against
those four, and an HA cluster needs it exactly as much as a single-node one.

---

## Part 2 - Hands-on lab

**This creates a second cluster.** Your `devops` cluster is untouched throughout
and you switch back at the end.

> Five containers, each a full node. If your machine is tight, remove the worker
> from `solution/kind-ha.yaml` — nothing in this assignment needs it.

### Step 1: Build a three-control-plane cluster

```bash
kind create cluster --config solution/kind-ha.yaml
kubectl config use-context kind-ha-lab
kubectl get nodes
```

```
NAME                    STATUS   ROLES           AGE   VERSION
ha-lab-control-plane    Ready    control-plane   2m    v1.31.4
ha-lab-control-plane2   Ready    control-plane   90s   v1.31.4
ha-lab-control-plane3   Ready    control-plane   60s   v1.31.4
ha-lab-worker           Ready    <none>          45s   v1.31.4
```

Now look at what kind created that you did not ask for:

```bash
docker ps --filter "name=ha-lab" --format "{{.Names}}\t{{.Image}}"
```

```
ha-lab-control-plane           kindest/node:v1.31.4
ha-lab-control-plane2          kindest/node:v1.31.4
ha-lab-control-plane3          kindest/node:v1.31.4
ha-lab-worker                  kindest/node:v1.31.4
ha-lab-external-load-balancer  kindest/haproxy:...
```

**A fifth container running HAProxy.** kind added it automatically because there
is more than one control-plane node (26.4).

### Step 2: Read the whole HA setup

```bash
bash solution/ha-inspect.sh
```

Nine sections. The ones to read carefully:

**2 and 3** — the load balancer's backend list, and where your kubeconfig points:

```
backend kube-apiservers
    server ha-lab-control-plane  172.18.0.3:6443 check
    server ha-lab-control-plane2 172.18.0.4:6443 check
    server ha-lab-control-plane3 172.18.0.5:6443 check
```

```
https://127.0.0.1:36000
```

**Your `kubectl` talks to the load balancer, not to any node.** That is the whole
active/active model: three interchangeable API servers, one address.

**4 versus 5** — three API server pods, three scheduler pods, three
controller-manager pods. **All nine are `Running`.**

**6** — but only one scheduler is *doing* anything:

```
  kube-scheduler             holder=ha-lab-control-plane2_1f4e...
  kube-controller-manager    holder=ha-lab-control-plane_9a2b...
```

**Two components, two leases, and they need not be held by the same node.**
Watch a lease being renewed:

```bash
for i in 1 2 3; do
  kubectl -n kube-system get lease kube-scheduler \
    -o jsonpath='{.spec.holderIdentity}{"  "}{.spec.renewTime}{"\n"}'
  sleep 4
done
```

**Same holder, advancing `renewTime`** — a heartbeat every 10 seconds (26.4).

**7 and 8** — the etcd cluster, its leader, and the arithmetic:

```
  members:        3
  quorum:         2     (floor(N/2)+1)
  can afford to lose: 1
```

### Step 3: Kill the scheduler's leader

Find who holds it, then take that node away:

```bash
kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.holderIdentity}{"\n"}'
```

Say it is `ha-lab-control-plane2`. Delete just that scheduler pod:

```bash
kubectl -n kube-system delete pod kube-scheduler-ha-lab-control-plane2
sleep 20
kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.holderIdentity}{"\n"}'
```

**The holder is now a different node.** Nothing else was involved — one of the
two idle schedulers noticed the lease had not been renewed within 15 seconds and
took it (26.4).

Prove scheduling never stopped:

```bash
kubectl create deployment failover-test --image=nginx:alpine --replicas=3
kubectl rollout status deployment/failover-test --timeout=90s
kubectl get pods -o wide
```

**Pods were scheduled throughout.** Worst case they waited 15 seconds.

### Step 4: Lose one control plane — quorum holds

```bash
bash solution/ha-failover.sh status
bash solution/ha-failover.sh kill 2
```

```
==> stopping ha-lab-control-plane2
    control planes running: 2 of 3;  quorum needs 2
    QUORUM HELD -- the cluster should keep working.
```

After 30 seconds:

```
-- can we still talk to the API?
   YES
NAME                    STATUS     ROLES
ha-lab-control-plane    Ready      control-plane
ha-lab-control-plane2   NotReady   control-plane
ha-lab-control-plane3   Ready      control-plane
```

**One control plane is gone and the cluster is fully operational.** Both leases
have moved to surviving nodes if they were held by that one. Confirm you can
still change things:

```bash
kubectl scale deployment/failover-test --replicas=5
kubectl rollout status deployment/failover-test --timeout=90s
kubectl get pods -o wide | grep -c failover-test
```

And check etcd's own view:

```bash
kubectl -n kube-system exec etcd-ha-lab-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster --write-out=table 2>&1 | tail -8
```

**The dead member is reported unhealthy and the other two carry on.** That is
fault tolerance 1, from the table in 26.5, observed rather than believed.

### Step 5: Lose a second — quorum is gone

```bash
bash solution/ha-failover.sh kill 3
```

```
==> stopping ha-lab-control-plane3
    control planes running: 1 of 3;  quorum needs 2
    QUORUM LOST -- expect the API server to stop answering.
```

```
-- can we still talk to the API?
   NO -- the API server is not answering.
```

Try for yourself:

```bash
kubectl get nodes
```

```
Error from server: etcdserver: request timed out
```

or a connection error, depending on how far the request got. **Note the
message** — it names `etcdserver`, not the API server. The API server is running
perfectly and cannot reach a quorum of its datastore:

```bash
docker ps --filter "name=ha-lab-control-plane" --format '{{.Names}} {{.State}}'
docker exec ha-lab-control-plane crictl ps | grep -E "apiserver|etcd"
```

**Both processes are up.** This is not a crash; it is Raft refusing to serve
without a majority (26.5).

**Now the important half — what is still working:**

```bash
docker exec ha-lab-worker crictl ps | head -5
```

The workload containers on the worker are running, untouched
([26.3](#263-what-actually-breaks-when-the-control-plane-dies)). A user hitting
those pods sees nothing wrong. **The cluster is unmanageable and the application
is up** — which is exactly the state that goes unnoticed until something needs
to be rescheduled.

### Step 6: Recover

```bash
bash solution/ha-failover.sh restore
```

```bash
kubectl get nodes
kubectl get pods -o wide
kubectl -n kube-system get lease
```

**Everything returns on its own.** No repair, no restore from snapshot, no
manual intervention — the members rejoin, Raft elects a leader, and the API
server starts answering. That is what makes quorum loss survivable *if the data
is intact*, and it is why `Retain`-style thinking does not apply here.

```bash
kubectl delete deployment failover-test
```

### Step 7: Compare against the single-node cluster

```bash
kubectl config use-context kind-devops
kubectl -n kube-system get lease
kubectl -n kube-system get pods -l component=kube-scheduler
```

**One scheduler, one lease, one holder — and the lease still exists.** Leader
election runs even with a single replica, because the component does not know how
many peers it has. That is worth seeing: **the mechanism is identical; only the
number of candidates differs.**

```bash
kubectl config use-context kind-ha-lab
```

### Cleanup

```bash
kubectl config use-context kind-devops
kind delete cluster --name ha-lab
docker ps --filter "name=ha-lab"      # nothing, including the load balancer
```

---

## Part 3 - Challenges

### C1 - Size three clusters

For each, give control-plane count, etcd topology, worker count and a one-line
justification:

1. A learning cluster on a laptop.
2. A dev/test cluster for 20 engineers, ~150 pods, rebuilt monthly.
3. Production: 3 availability zones, ~2,000 pods, 99.95% target, a small
   platform team.

Then say which of the three you would put on a managed service instead, and why
that is not an admission of defeat.

### C2 - Quorum arithmetic

1. Complete the table for 1–7 members: quorum, and failures tolerated.
2. Why is 4 never a sensible choice?
3. A 5-member cluster spread across 2 data centres, 3 + 2. One DC goes dark.
   What happens in each case?
4. The same 5 members across 3 DCs as 2 + 2 + 1. Now which single-DC failures
   are survivable?
5. What is the minimum number of DCs for a cluster that survives losing any one
   of them?

### C3 - The lease moved and nothing happened

A colleague sees `kube-controller-manager`'s lease holder change three times in
an hour and asks whether the cluster is unhealthy.

1. What are the three benign causes?
2. What are the two that are not benign?
3. Give the commands that distinguish them.
4. What would you actually alert on?

### C4 - Design the load balancer

You are building a kubeadm HA cluster with three control-plane nodes.

1. What exactly must the load balancer do, and at which OSI layer?
2. Why must it **not** terminate TLS?
3. What health check should it use, and why not `/healthz`?
4. What must `--control-plane-endpoint` be set to, and what happens if you
   forget it on the first `kubeadm init`?
5. The load balancer is now a single point of failure. Name two ways to remove
   it.

### C5 - HA did not help

Write the sequence of events for each, and say what would have prevented it:

1. A three-control-plane cluster becomes completely unusable at 00:00 UTC on a
   Tuesday, one year after installation.
2. Someone runs `kubectl delete ns production`. All three etcd members agree it
   is gone within milliseconds.
3. An upgrade of the first control-plane node succeeds; the second fails and the
   cluster is left with mixed versions and a failing API server.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Run it against `kind-ha-lab`. It checks that there are three control-plane
nodes and an external load balancer container; that the kubeconfig points at the
load balancer rather than at a node; that three API server, scheduler and
controller-manager pods are running; that exactly one holder is recorded per
lease and the lease is being renewed; that etcd has three members with one
leader; and that the quorum arithmetic matches the member count.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# who is the active scheduler / controller manager?
kubectl -n kube-system get lease
kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.holderIdentity}{"\n"}'

# etcd membership and health
ETCDCTL_API=3 etcdctl member list --write-out=table \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
etcdctl endpoint status --cluster --write-out=table   # IS LEADER column
etcdctl endpoint health --cluster

# what is the API server pointed at?
grep etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml
grep -E "leader-elect" /etc/kubernetes/manifests/kube-scheduler.yaml

# stacked or external?
kubectl -n kube-system get pods -l component=etcd -o wide

# what does kubectl talk to?
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

**Traps**

- **Quorum is floor(N/2)+1**, and **fault tolerance is N − quorum**.
- **Two members tolerate zero failures** — strictly worse than one.
- **Even numbers add cost, not tolerance.** 4 ≡ 3, 6 ≡ 5.
- **Odd numbers survive network partitions**; even ones can split with no
  majority.
- **The API server is active/active; the scheduler and controller manager are
  active/passive** via leader election.
- **Leader election uses `Lease` objects now**, not `Endpoints` or `ConfigMap`.
- **Failover takes up to `leader-elect-lease-duration`** — 15 seconds by
  default.
- **Losing quorum does not crash anything.** Processes stay up and etcd refuses
  to serve; the error names `etcdserver`.
- **Running pods survive a total control-plane outage.** Only changes stop.
- **`--control-plane-endpoint` must be set at `kubeadm init`** for a cluster you
  intend to make HA.
- **Replication is not backup.** Take etcd snapshots
  ([CKA 12](../12-cluster-maintenance/)) on HA clusters too.
- **Stacked is the default**; external etcd doubles the machine count.

---

**Previous:** [CKA 25 — Ingress and Gateway API in Depth](../25-ingress-gateway-in-depth/)
**Next:** [CKA 27 — Build a Cluster with kubeadm](../27-build-a-cluster-with-kubeadm/)
