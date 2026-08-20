# CKA 26 solution

## Challenge answers

### C1 - Size three clusters

**1. Learning, on a laptop.**
**One node, everything on it, stacked etcd, no workers.** `kind`, minikube, or a
single `kubeadm init` with the control-plane taint removed. HA is meaningless
here: the failure domain is the laptop, and no amount of quorum survives closing
the lid.

**2. Dev/test, 20 engineers, ~150 pods, rebuilt monthly.**
**One control plane, stacked etcd, 3 workers.** The deciding phrase is *rebuilt
monthly* — the cluster is disposable, so the recovery plan is "recreate it",
which is faster than any HA failover and costs nothing to maintain. Two-thirds of
the machines go to workers where they do useful work.

**3. Production, 3 AZs, ~2,000 pods, 99.95%, small platform team.**
**Three control planes, one per AZ, stacked etcd, workers spread across all
three.** Three is the minimum that tolerates a failure (26.5); one per AZ means
losing an entire AZ leaves quorum (2 of 3). Stacked, because six machines and a
separate etcd cluster is work a *small* team should not take on. Workers sized so
that any one AZ's share can be absorbed by the other two.

99.95% is about 4.4 hours of downtime a year — comfortably achievable with this
shape, and **not** achievable if the recovery plan is manual.

**Which would I put on a managed service: number 3**, and probably number 2.

**Why that is not defeat.** The hard part of a production control plane is not
building it — it is the year afterwards: certificate rotation before the
365-day expiry (C5.1), etcd defragmentation and backups, quarterly version
upgrades across three nodes, and someone awake when a control plane fails at
04:00. **A small platform team's scarce resource is attention, not skill.**
Spending it on the control plane means not spending it on the things only you can
do — the platform your engineers actually use.

Run your own when you have a genuine constraint: air-gapped, a regulator that
requires it, or a scale where the managed service's limits bind. "We want to
understand it" is a good reason to build number 1, not number 3.

### C2 - Quorum arithmetic

**1. The table:**

| Members | Quorum ⌊N/2⌋+1 | Tolerates |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | 0 |
| 3 | 2 | **1** |
| 4 | 3 | 1 |
| 5 | 3 | **2** |
| 6 | 4 | 2 |
| 7 | 4 | **3** |

**2. Why 4 is never sensible.** It tolerates one failure, exactly like 3, so the
fourth machine buys nothing. It costs: another machine, another member every
write must be replicated to, and — the real problem — **a 2/2 network partition
leaves neither side with quorum**, a failure mode 3 cannot have.

**3. Five members across two DCs, 3 + 2. Quorum is 3.**

- **The 2-member DC goes dark:** 3 remain, quorum met, **the cluster keeps
  working**.
- **The 3-member DC goes dark:** 2 remain, **quorum lost, the cluster stops** —
  and it cannot recover on its own; it needs the other DC back, or a manual
  `--force-new-cluster` restore from snapshot.

**Two DCs cannot give you DC-failure tolerance.** Whichever way you split an odd
number, one side holds the majority and the other is helpless. **A 3+2 split is
not "highly available across two data centres" — it is a cluster in one DC with
two spare members in another.**

**4. Five members across three DCs, 2 + 2 + 1. Quorum is still 3.**

- lose the **1-member DC**: 4 remain -> **survives**
- lose either **2-member DC**: 3 remain -> **survives**

**Every single-DC failure is survivable.** That is the whole argument for a third
location: not more members, but a distribution in which no single site holds a
majority.

**5. Three.** With two you can never place members so that both sides survive
(question 3). With three, the standard shapes are 1+1+1 for a 3-member cluster or
2+2+1 for a 5-member one, and in both, **no site holds a majority alone** — so
losing any one leaves the remaining two with quorum.

The subtler point: the third site does not need to be a full data centre. It
needs to be an independent failure domain with enough capacity for one etcd
member and a reliable network path — which is why cloud "3 AZ" designs work and
why an etcd witness in a third region is a real pattern.

### C3 - The lease moved and nothing happened

**1. Three benign causes:**

- **A rolling restart of the control plane** — a kubeadm upgrade, a node reboot,
  a manifest edit. Each restart hands the lease on.
- **A brief API server hiccup on the holder's node.** The holder cannot renew
  within `renew-deadline` (10s), someone else takes it, and the original becomes
  a standby. Nothing is lost.
- **Normal node maintenance** — draining or cordoning a control-plane node.

In all three, **the handover is the mechanism working**. Failover takes at most
15 seconds and no scheduling decision is lost, because the incoming leader reads
current state from the API server rather than resuming anything.

**2. Two that are not benign:**

- **The holder is being OOMKilled or crash-looping**, so the lease moves every
  time it dies. The lease is a symptom; the memory limit is the problem.
- **Network instability between control-plane nodes**, so the holder cannot renew
  reliably. Here the lease flapping is a *leading indicator* of something that
  will also affect etcd — and etcd losing peers is far more serious than a
  scheduler restarting.

**3. Distinguishing them:**

```bash
# is the component restarting?
kubectl -n kube-system get pods -l component=kube-controller-manager
#   RESTARTS climbing == cause 1 of the malignant pair
kubectl -n kube-system describe pod <holder-pod> | grep -A5 "Last State"

# was it OOMKilled?
kubectl -n kube-system get pod <holder-pod> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'

# is etcd also unhappy? (the network case)
etcdctl endpoint status --cluster --write-out=table
etcdctl endpoint health --cluster
kubectl -n kube-system logs -l component=etcd --tail=50 | grep -iE "lost|elect|slow|took too long"

# was it just a restart of everything?
kubectl -n kube-system get pods -o wide --sort-by=.status.startTime | tail -10
kubectl get events -A --field-selector reason=NodeNotReady
```

**The discriminator is `RESTARTS` plus etcd health.** Zero restarts and a healthy
etcd means the handovers were benign; either one unhealthy and the lease is
telling you about a different problem.

**4. What to alert on.**

**Not the lease changing.** It is normal, it is frequent during maintenance, and
an alert on it will be muted within a week.

Alert on:

- **`kube_pod_container_status_restarts_total` for control-plane components** —
  the actual fault behind a flapping lease.
- **`etcd_server_leader_changes_seen_total` increasing** — etcd leader elections
  are much rarer than Kubernetes lease handovers and almost always indicate
  network or disk trouble.
- **`etcd_server_has_leader == 0`** — quorum loss, the thing from Step 5. This is
  the page.
- **API server availability from outside the cluster**, which catches every cause
  at once and is the only symptom users experience.

**The lease is diagnostic, not an alert.** Look at it when something else fires.

### C4 - Design the load balancer

**1. What it must do, and at which layer.**

**Layer 4 — TCP passthrough on port 6443**, round-robin or least-connections
across the three control-plane nodes. That is all. It accepts a TCP connection
and forwards the bytes.

```
frontend kube-apiserver
    bind *:6443
    mode tcp
    default_backend kube-apiservers

backend kube-apiservers
    mode tcp
    option httpchk GET /readyz
    http-check expect status 200
    balance roundrobin
    server cp1 10.0.1.11:6443 check check-ssl verify none
    server cp2 10.0.1.12:6443 check check-ssl verify none
    server cp3 10.0.1.13:6443 check check-ssl verify none
```

**2. Why it must not terminate TLS.**

Because **Kubernetes authenticates clients with certificates**
([CKA 13](../../13-tls-in-kubernetes/)). The API server reads `CN` and `O` from
the client certificate presented during the handshake, and turns them into a
username and groups. **Terminating TLS at the load balancer destroys that** — the
API server would see a connection from the load balancer with no client
certificate, and every request would be anonymous.

There is a second reason: the API server's serving certificate has a SAN list
(13.7). A terminating proxy would need its own certificate covering the
`--control-plane-endpoint` name, and would then need to re-originate TLS to the
backends — at which point you are running an authenticating proxy, which is a
supported but very different design.

**Pass the bytes through. `mode tcp`, not `mode http`.**

**3. The health check.**

**`/readyz`, not `/healthz`.**

| Endpoint | Means |
|---|---|
| `/livez` | the process is alive — restart it if not |
| `/healthz` | deprecated aggregate of the other two |
| **`/readyz`** | **ready to serve requests** — etcd reachable, caches synced, webhooks resolvable |

An API server can be *alive* while still syncing its caches or unable to reach
etcd. `/healthz` may pass in that state and the load balancer would send it
traffic that fails. **`/readyz` is the one that answers "should this receive
requests".**

Note the check must be made over **HTTPS without verifying the certificate**
(`check-ssl verify none` above, or an explicit CA) — the endpoint is only served
on the TLS port.

**4. `--control-plane-endpoint`.**

It must be **the load balancer's stable address**, ideally a DNS name:

```bash
kubeadm init --control-plane-endpoint "k8s-api.internal.example:6443" \
             --upload-certs --pod-network-cidr=10.244.0.0/16
```

**If you forget it on the first `kubeadm init`, you cannot add control-plane
nodes later** — not without real surgery. kubeadm writes the first node's own
address into the cluster's kubeconfigs, the `kubeadm-config` ConfigMap, and every
kubelet's `kubelet.conf`. Every component then talks to **that one node** rather
than to the load balancer, and `kubeadm join --control-plane` refuses.

Recovering means editing the ConfigMap, regenerating the API server certificate
with the new name in its SAN list, rewriting every kubeconfig on every node, and
restarting everything. **Setting the flag on a single-node cluster you *might*
grow costs nothing; forgetting it costs a rebuild.** Use a DNS name even if it
initially resolves to one node.

**5. Removing the load balancer as a single point of failure.**

- **A pair of load balancers with a virtual IP** — `keepalived` (VRRP) moving a
  VIP between two HAProxy nodes, which is the classic on-prem answer and what
  most kubeadm HA guides describe. The VIP is what
  `--control-plane-endpoint` names.
- **A managed load balancer** — a cloud NLB is already redundant across AZs and
  is somebody else's problem. This is the right answer wherever it is available.

A third, worth knowing: **run a load balancer on every node.** `kube-vip` in ARP
mode, or a local HAProxy on each node with `127.0.0.1:6443` as the endpoint, so
there is no shared component to fail — each client balances for itself. It is
how several distributions do it and it removes the VIP entirely.

**Note that kubelets already tolerate this partially** — but only partially. A
kubelet configured against the load balancer address fails over with it; a
kubelet pointed at one API server does not.

### C5 - HA did not help

**1. Unusable at 00:00 UTC, one year after installation.**

**Every certificate expired simultaneously.**

kubeadm issues leaf certificates with a **one-year** validity
([CKA 13](../../13-tls-in-kubernetes/)) — the API server's serving certificate,
its client certificates for etcd and the kubelets, every component's kubeconfig,
and etcd's peer and server certificates. **All of them were created within
minutes of each other at install time, so they expire within minutes of each
other.**

The sequence: at the expiry instant the API servers can no longer authenticate to
etcd, the kubelets can no longer authenticate to the API servers, the components'
kubeconfigs stop working, and `kubectl` reports
`x509: certificate has expired or is not yet valid`. **All three control planes
fail at once**, because HA replicates the configuration, and the configuration
includes the expiry date.

The tell is the timing: a *simultaneous* failure of independent machines is
almost never a coincidence and almost always a shared, time-triggered cause.

**What would have prevented it:**

- **`kubeadm certs check-expiration` on a schedule**, alerting at 30 days. One
  cron job.
- **`kubeadm upgrade` at least annually** — it renews all leaf certificates as a
  side effect, which is why clusters that are kept current rarely hit this.
- **Renewing deliberately**: `kubeadm certs renew all`, **then restarting each
  component** (CKA 13 Part F — the renewal and the restart are separate steps).

Note the CA is valid for ten years, so `renew all` is sufficient here; the
ten-year version of this incident is C5-adjacent and much worse (CKA 13 C5).

**2. `kubectl delete ns production`.**

**The sequence:** the API server accepts the request, sets a `deletionTimestamp`,
and the namespace controller begins deleting every object in it. Each deletion is
a write, replicated to all three etcd members and **acknowledged by a majority
within milliseconds**. Raft did exactly what it is designed to do: made the change
durable and consistent everywhere, instantly.

**HA made this faster and more thorough, not safer.** There is no version of a
replicated datastore that protects you from an authorised, valid, intentional
write.

**What would have prevented it:**

- **RBAC.** Almost nobody needs `delete` on `namespaces`
  ([Day 19](../../../days/day-19-rbac/), [CKA 15](../../15-certificates-api-and-authorization/)).
  The first question is why that credential could do this at all.
- **A validating admission policy** rejecting deletion of namespaces carrying a
  `protected: "true"` label ([CKA 07](../../07-admission-controllers/)). Fifteen
  lines of CEL, and it fails closed.
- **An etcd snapshot** ([CKA 12](../../12-cluster-maintenance/)) — the only
  thing that actually recovers the data once it is gone. Note the restore is
  cluster-wide and loses everything since the snapshot, so it is a genuinely bad
  day even when it works.
- **GitOps.** If every object in `production` is reconciled from Git, the
  namespace is recreated in minutes and the incident becomes an outage rather
  than a data loss.

**The general point: HA is about availability, not durability, and certainly not
about authorisation.** Three copies of a mistake is three copies of a mistake.

**3. A partial upgrade leaves mixed versions and a failing API server.**

**The sequence:** `kubeadm upgrade apply` on the first node succeeded — it also
upgraded cluster-wide state, including the etcd version and any API changes.
`kubeadm upgrade node` on the second failed partway, leaving that node running
old binaries against a control plane whose stored data and configuration have
moved on. Depending on where it failed, you now have an API server that will not
start, or one that starts and disagrees with its peers.

**HA did not help because the upgrade is a cluster-wide operation, not a
per-node one.** The first node changed shared state; the redundancy was never
independent.

**What would have prevented it:**

- **`kubeadm upgrade plan` first**, which checks version skew and preconditions
  before anything changes.
- **An etcd snapshot immediately before the upgrade** — the documented
  prerequisite, and the only rollback that exists.
- **Respecting the version skew policy** ([CKA 12](../../12-cluster-maintenance/)):
  one minor version at a time, control plane before kubelets, never skipping.
- **Rehearsing on an identical non-production cluster.** The failure is
  reproducible and cheap to find in advance.
- **Draining the node first**, so a control plane that fails to come back is not
  also carrying workloads.

**The recovery**, if it happens anyway: finish the upgrade on the failed node
(`kubeadm upgrade node` is idempotent and usually succeeds on retry once the
underlying cause is fixed). If it cannot be finished, **remove the node from the
cluster and rejoin it at the new version** — `kubeadm reset` on it,
`kubectl delete node`, `etcdctl member remove` for its etcd member, then
`kubeadm join --control-plane`. Removing the member is the step people forget,
and leaving a dead member in the list changes the quorum arithmetic (26.5).

---

## Files

| File | Purpose |
|---|---|
| `kind-ha.yaml` | three control-plane nodes and a worker; kind adds the HAProxy load balancer |
| `ha-inspect.sh` | the whole HA setup in nine sections -- LB backends, leases, etcd members, quorum arithmetic |
| `ha-failover.sh` | `status` / `kill N` / `restore` -- stop control planes one at a time |
| `verify.sh` | checks every claim in Part 4 |

There are no application manifests. **This assignment is about the control
plane**, and the only workload it creates is one throwaway Deployment used to
prove that scheduling continued.

---

## On the second cluster

`kind-ha.yaml` builds `ha-lab` rather than modifying `devops`, for two reasons.

**You cannot add a control-plane node to an existing kind cluster.** kind builds
the topology at creation time, and — more fundamentally — the `devops` cluster
was created without `--control-plane-endpoint`, so it has no load balancer
address to grow into (C4.4). That limitation is not a kind quirk; it is the same
constraint on a real kubeadm cluster.

**Step 5 deliberately breaks the cluster.** Taking etcd below quorum on your
working cluster would cost you every other assignment's state. On a throwaway
cluster it costs a `kind delete`.

Five containers is the price. If your machine is tight, remove the worker from
the config — the control-plane nodes carry the `node-role.kubernetes.io/control-plane:NoSchedule`
taint, so untaint one if you need somewhere to schedule the test Deployment:

```bash
kubectl taint nodes ha-lab-control-plane node-role.kubernetes.io/control-plane:NoSchedule-
```

## What Step 5 looks like, and why it matters

The output of a quorum failure is worth recognising on sight:

```
Error from server: etcdserver: request timed out
```

**It names `etcdserver`, and the API server process is running fine.** That
combination — a healthy-looking control plane returning etcd errors — is the
signature, and it points you at `etcdctl endpoint status --cluster` rather than
at API server logs.

The recovery in Step 6 is equally worth seeing: **nothing is required.** Start the
members, Raft elects a leader, and the API server resumes. Quorum loss is an
availability event, not a data event — provided the disks survived. If they did
not, you are in [CKA 12](../../12-cluster-maintenance/)'s restore procedure
instead, and the difference between those two situations is the whole reason
snapshots exist.
