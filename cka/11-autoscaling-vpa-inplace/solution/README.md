# CKA 11 solution

## Challenge answers

### C1 - Pick the autoscaler

| # | Workload | Answer | Why |
|---|---|---|---|
| 1 | stateless REST API, 3x at 09:00 | **HPA** | load arrives in parallel and can be split across replicas; seconds to react |
| 2 | single-replica PostgreSQL | **VPA, `updateMode: Initial` or `Off`** | one pod cannot be split, so only size helps -- but `Recreate` on one replica is an outage |
| 3 | JVM needing 6 GB then 500 MB | **neither, today** | see below |
| 4 | queue consumer, backlog-driven | **HPA on a custom metric** | CPU does not represent the load; queue depth does |
| 5 | DaemonSet log collector | **VPA only** | replica count is fixed by the node count -- an HPA has nothing to change |

**The two that are not an autoscaler:**

**Number 3** is the classic VPA pitch and the VPA handles it badly. The
recommender works from observed usage over hours; a 90-second startup spike is
noise it will smooth away, and reacting to it would mean evicting the pod at
exactly the moment it is starting. The real fixes are ordinary Kubernetes: give
the container a request sized for steady state and a limit that permits the
spike, or move the expensive warm-up into an **init container**
([CKA 10](../../10-multi-container-and-init/)) where it gets its own resources
and exits. If the cluster supports in-place resize, a start-up hook that
downsizes after warm-up is the modern answer — and that is a script, not an
autoscaler.

**Number 5** is half a trick: an HPA on a DaemonSet is not merely wrong, it is
**rejected** — a DaemonSet has no `replicas` field to scale, and the HPA's scale
subresource does not exist for it. A VPA is legitimate and useful here, since
log collectors are routinely over- or under-provisioned across a fleet.

Number 2 deserves the caveat spelled out: the VPA's only mechanism is eviction,
so on a single-replica database `Recreate` means a deliberate restart of your
primary. Use `Off` to get the numbers and apply them during a maintenance
window, or `Initial` so the next restart — whenever it happens for its own
reasons — comes back correctly sized.

### C2 - Diagnose a silent VPA

In order, because each step depends on the one before:

**1. Is there a metrics source at all?**
```bash
kubectl top pods -n NS
kubectl get apiservice v1beta1.metrics.k8s.io
```
Healthy: real numbers, and the APIService shows `True (Passed)`. The VPA reads
the same metrics API `kubectl top` does — if `top` is broken, the recommender
has nothing to work from, and it reports this by producing no recommendation
rather than by erroring.

**2. Is the recommender running, and what does it say?**
```bash
kubectl -n kube-system get pods -l app=vpa-recommender
kubectl -n kube-system logs -l app=vpa-recommender --tail=30
```
Healthy: `Running`, and log lines naming your VPA object. This is where a
version mismatch shows up as a CRD decoding error.

**3. Does `targetRef` actually match something?**
```bash
kubectl get vpa NAME -o jsonpath='{.spec.targetRef}{"\n"}'
kubectl get deployment <that name> -n <that namespace>
```
Healthy: the Deployment exists, **in the same namespace as the VPA**. A typo, a
wrong `kind`, or a cross-namespace reference produces silence — no event, no
error, no recommendation. This is the most common cause.

**4. Has it had enough observations?**
```bash
kubectl get vpa NAME -o jsonpath='{.status.conditions}{"\n"}'
```
Healthy: a condition `RecommendationProvided=True`. If instead you see
`NoPodsMatched`, step 3 was the answer after all. If there are no conditions at
all and the pods have been running for under a few minutes, the answer is
simply **wait** — the recommender deliberately refuses to guess from a handful
of samples.

### C3 - The oscillation

Start: 4 replicas, `requests.cpu: 200m`, each pod actually using `180m`. The HPA
targets 50% CPU. **The HPA's percentage is of the *request*, not of the node** —
that is the fact the whole loop turns on.

| Time | What happens |
|---|---|
| t+0 | utilisation = 180/200 = **90%**, well above the 50% target |
| t+1m | HPA scales out: 4 -> 7 replicas. Per-pod usage drops to ~100m, utilisation 50% |
| t+3m | VPA recommender sees pods using ~100-180m against a 200m request and, over the window, recommends **`400m`** to leave headroom |
| t+4m | VPA updater evicts pods; they return with `requests.cpu: 400m` |
| t+5m | utilisation is now 100/400 = **25%** -- half the target. Nothing about the workload changed; the denominator did |
| t+6m | HPA scales in: 7 -> 4 replicas. Per-pod usage climbs back toward 180m |
| t+8m | utilisation = 180/400 = 45%, close to target -- but the VPA now sees pods using 180m of a 400m request and recommends **lowering** it |
| t+10m | requests drop, utilisation jumps, the HPA scales out again |

**The feedback loop, stated exactly:** the HPA controls a ratio whose
denominator is the very number the VPA is changing. Each controller reacts
correctly to a signal the other is manipulating, so the system has no fixed
point — replica count and pod size chase each other indefinitely, and every VPA
adjustment is an eviction, so the workload is also being restarted throughout.

Neither controller is misconfigured, which is what makes this hard to diagnose:
both report success, and both are doing their job.

**The two supported configurations:**

1. **HPA on a custom or external metric, VPA on CPU/memory.** Scale out on
   requests-per-second or queue depth — a signal the VPA does not touch — and
   let the VPA size each pod. The loop is broken because the two controllers no
   longer share a variable.
2. **HPA on CPU/memory, VPA restricted to the other resource** via
   `controlledResources`. If the HPA scales on CPU, set
   `controlledResources: ["memory"]` on the VPA. Overlap is what causes the
   loop, not coexistence.

A third, honest option: **VPA in `updateMode: "Off"`** alongside any HPA. The
recommender never changes a request, so there is no loop — you get the sizing
data and apply it deliberately.

### C4 - Resize that does not take

The patch is accepted and `spec` updates, but nothing reaches the container.

**Cause 1: the gate is on the API server but not the kubelet.** The API server
validates and stores the field; the kubelet is what rewrites the cgroup. With
the gate off there, nobody acts on the change and `status.resize` is never even
set.

```bash
docker exec <node> grep -A5 featureGates /var/lib/kubelet/config.yaml
# ...or on a real node:
ps aux | grep [k]ubelet | tr ' ' '\n' | grep feature-gates
```
**Distinguishing signal:** the gate is present in the API server manifest and
absent from the kubelet config.

**Cause 2: you patched a field that cannot be resized.** Init containers,
ephemeral containers, a resource other than CPU/memory, or a request that was
not previously set — all are rejected as a *resize* while still being valid as a
*spec*. Some are rejected at validation; others are simply ignored.

```bash
kubectl get pod X -o jsonpath='{.spec.initContainers[*].name}{"\n"}'
kubectl describe pod X | grep -A10 Events
```
**Distinguishing signal:** the container you patched is in `initContainers`, or
the resource key you changed is absent from `allocatedResources` entirely.

**Cause 3: you are on 1.33+ and patched the wrong endpoint.** From 1.33 the
resize goes through a dedicated subresource. Patching the main pod resource
updates `spec` but is not treated as a resize request.

```bash
kubectl version --short
kubectl patch pod X --subresource resize --patch '{...}'    # succeeds on 1.33+
```
**Distinguishing signal:** the server is 1.33 or newer and the same patch works
once `--subresource resize` is added.

The single command that narrows it fastest is
`kubectl get pod X -o jsonpath='{.status.resize}'`: **empty** means nothing is
even trying (causes 1 or 3); `InProgress` or `Infeasible` means the kubelet
received it and the problem is capacity, not wiring.

### C5 - Argue against in-place resize

**1. When the process only reads the value at start-up.** A JVM sizes its heap
from `-Xmx` or from the cgroup limit at launch and never looks again; the same
is true of many connection pools, thread pools and Go programs setting
`GOMEMLIMIT`. Raise the container's memory limit in place and the cgroup is
larger, but the process still refuses to allocate past the number it read
minutes ago. **In-place resize changes the environment, not the program's
opinion of it.** You have paid nothing and gained nothing; a restart is what
actually applies the change, which is exactly why `RestartContainer` is the
sensible `resizePolicy` for memory.

**2. When the real problem is the node, not the pod.** A pod on a node with
noisy neighbours, failing local storage, a degraded NIC or an over-subscribed
kernel will not be fixed by getting bigger. Replacing the pod gives the
scheduler a fresh decision and may move it to a healthier node; resizing it in
place **guarantees it stays exactly where it is**. In-place resize removes the
reschedule, and the reschedule was sometimes the point.

A third, if you want one: **when you need to change the QoS class.** Moving from
`Burstable` to `Guaranteed` — to protect a workload from eviction under node
pressure — is explicitly outside what resize can do (11.3). Pod replacement is
the only route.

---

## Files

| File | Purpose |
|---|---|
| `kind-inplace-resize.yaml` | a throwaway single-node cluster with `InPlacePodVerticalScaling` on |
| `01-resizable-pod.yaml` | `resizePolicy`: CPU `NotRequired`, memory `RestartContainer` |
| `02-load-target.yaml` | a busy-loop Deployment whose requests are deliberately far too small |
| `03-vpa-off.yaml` | `updateMode: "Off"` with a **binding** `maxAllowed` |
| `04-vpa-recreate.yaml` | the same VPA switched to `Recreate` |
| `install-vpa.sh` | installs/uninstalls the VPA from a pinned upstream release |
| `verify.sh` | checks whichever cluster is reachable |

> `kind-inplace-resize.yaml` is a **kind** Config, not a Kubernetes object.
> `kubectl apply` would reject it; it is an argument to `kind create cluster`.

---

## Why a second cluster

The alternative is turning the feature gate on in place, and it is instructive
to know how even though the lab does not do it:

```bash
# API server -- a static pod manifest edit, as in CKA 07 and CKA 09
--feature-gates=InPlacePodVerticalScaling=true

# kubelet -- /var/lib/kubelet/config.yaml, then restart it
featureGates:
  InPlacePodVerticalScaling: true
# systemctl restart kubelet
```

Two reasons the lab uses a separate cluster instead:

1. **Restarting the kubelet on your only control-plane node is a bad habit to
   build** on a cluster holding twenty other assignments' state.
2. **The gate is not removable cleanly.** Feature-gated alpha fields already
   written into stored objects stay there, and a later `kubectl` may show
   fields the cluster no longer honours.

A throwaway kind cluster costs about ninety seconds and one `kind delete`.

## A note on the VPA version

`install-vpa.sh` pins a release rather than tracking `master`, because the VPA
is versioned against Kubernetes and a mismatch fails in an unhelpful way — the
recommender starts, logs a CRD decode error, and simply never writes a
recommendation. That is C2's step 2, and it is worth having seen the cause.

If the pinned version does not work on your cluster, check the compatibility
table in the upstream repository and override it:

```bash
VPA_VERSION=vertical-pod-autoscaler-1.3.0 bash solution/install-vpa.sh
```

`hack/vpa-up.sh` also generates the TLS certificate for the admission webhook,
using `openssl`, into a Secret — the same pattern you built by hand in
[CKA 07](../../07-admission-controllers/). Reading that script is a good use of
five minutes: it is a real-world example of the webhook certificate problem
solved the pragmatic way.
