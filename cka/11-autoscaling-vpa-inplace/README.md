# CKA 11 — Autoscaling: In-Place Resize and the Vertical Pod Autoscaler

**Time:** 90-120 minutes
**Prerequisites:** [Day 16](../../days/day-16-resources-requests-limits-metrics-server/), [Day 17](../../days/day-17-horizontal-pod-autoscaler/), [CKA 07](../07-admission-controllers/)
**Source lectures:** 121, 122, 125, 126

[Day 17](../../days/day-17-horizontal-pod-autoscaler/) built an HPA: more pods
when the load rises. This assignment is the other axis — **bigger pods** — and
the two features that make it possible: in-place resize, and the Vertical Pod
Autoscaler.

---

## Part 1 - Concepts

### 11.1 Four kinds of scaling

Two independent questions — *what* are you scaling, and in *which direction*:

| | **Horizontal** (more of them) | **Vertical** (bigger) |
|---|---|---|
| **Workload** | more pods — `kubectl scale`, **HPA** | more CPU/memory per pod — `kubectl edit`, **VPA** |
| **Cluster** | more nodes — `kubeadm join`, **Cluster Autoscaler** | bigger nodes — replace the machine |

Three of these four are routine. **Vertical scaling of a *node* is the odd one
out**: it means draining the node, resizing the machine and bringing it back, so
in practice nobody does it — you add a larger node and remove the smaller one.
Say that if asked; it is the answer that shows you have run a cluster.

Note also that the exam and real life care about different quadrants. The exam
tests workload scaling. Production spends most of its money on cluster scaling.

### 11.2 The default behaviour: resource changes recreate the pod

Change a container's `resources` in a Deployment and the outcome is not subtle:

```
kubectl edit deployment myapp        # requests: 250m -> 1
       |
       v
  new ReplicaSet -> new pod created -> old pod terminated
```

**Pod resources have historically been immutable.** The only way to change them
was to replace the pod. For a stateless web tier that is a rolling update and
nobody notices. For a database, a JVM with a long warm-up, or a cache holding
gigabytes of state, **it is an outage you scheduled on purpose**.

That single fact is the reason the next two features exist.

### 11.3 In-place resize

Since Kubernetes **1.27** (alpha) and **1.33** (beta, on by default), a pod's
CPU and memory can be changed **without restarting the container**.

It is controlled by the `InPlacePodVerticalScaling` feature gate, and per
container by a new field:

```yaml
containers:
  - name: app
    image: nginx:alpine
    resizePolicy:
      - resourceName: cpu
        restartPolicy: NotRequired      # change CPU live
      - resourceName: memory
        restartPolicy: RestartContainer # a memory change restarts THIS container
    resources:
      requests: {cpu: "250m", memory: "128Mi"}
      limits:   {cpu: "500m", memory: "256Mi"}
```

`restartPolicy` here takes two values, and it is **per resource**:

| Value | Meaning |
|---|---|
| `NotRequired` | apply the change to the running container |
| `RestartContainer` | restart **this container** (not the pod) to apply it |

CPU is genuinely adjustable live — it is a cgroup value the kernel will happily
change. Memory often is not, because many runtimes read their heap limits once
at start-up; `RestartContainer` for memory is the conservative default choice.

**Note what restarts and what does not.** `RestartContainer` restarts one
container in place; the pod keeps its name, its IP, its node and its volumes.
That is still enormously better than pod replacement.

**The limitations, and they are examinable:**

- **CPU and memory only.** No other resource type.
- **QoS class cannot change.** A `Burstable` pod cannot be resized into
  `Guaranteed`.
- **Init containers and ephemeral containers cannot be resized.**
- **You cannot add or remove requests/limits** — only change values that are
  already set.
- **A memory limit cannot be lowered below current usage.** The resize simply
  stays `InProgress` until it becomes feasible, rather than failing.
- **Windows pods are not supported.**

The API also differs by version, which matters when you sit the exam on an
unknown cluster:

```bash
# 1.27 - 1.32 (alpha): patch the pod spec directly
kubectl patch pod app --patch '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"500m"}}}]}}'

# 1.33+ (beta): a dedicated subresource
kubectl patch pod app --subresource resize --patch '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"500m"}}}]}}'
```

Watch the result in `status`, not `spec`:

```bash
kubectl get pod app -o jsonpath='{.status.containerStatuses[0].allocatedResources}{"\n"}'
kubectl get pod app -o jsonpath='{.status.resize}{"\n"}'      # "" | InProgress | Infeasible | Deferred
```

**`spec` is what you asked for; `allocatedResources` is what the node gave you.**
When they disagree, `status.resize` says why.

### 11.4 The Vertical Pod Autoscaler

**The VPA is not built in.** Unlike the HPA, no controller ships with
Kubernetes; you install it, and there is **no `kubectl autoscale` equivalent** —
VPA objects are created declaratively or not at all.

It is three components, and knowing which does what is the exam question:

```
  metrics-server / Prometheus
            |
            v
    +---------------+   recommends only, changes nothing
    |  RECOMMENDER  |----------------------------+
    +---------------+                            |
            |                                    v
            |  reads recommendation      +-----------------+
            v                            | VPA object      |
    +---------------+                    | .status         |
    |    UPDATER    |  EVICTS pods that  +-----------------+
    +---------------+  are mis-sized              ^
            |                                     |
            v  (deployment recreates the pod)     |
    +------------------------+  mutates the new pod's
    |  ADMISSION CONTROLLER  |  resources at creation
    +------------------------+
```

| Component | Job |
|---|---|
| **Recommender** | watches usage, writes recommendations into the VPA object's `status`. **Never changes a pod.** |
| **Updater** | compares running pods against recommendations and **evicts** the bad ones |
| **Admission controller** | a **mutating webhook** ([CKA 07](../07-admission-controllers/)) that rewrites the resources of pods as they are created |

Read the loop once more: **the updater does not resize anything — it deletes.**
The Deployment then recreates the pod, and the *admission controller* stamps the
new numbers on the way in. Vertical autoscaling is currently implemented as
"kill it and let it come back bigger", which is why the modes matter so much.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: myapp-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: myapp
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed: {cpu: "100m", memory: "64Mi"}
        maxAllowed: {cpu: "2",    memory: "1Gi"}
```

| `updateMode` | Recommender | Updater | Admission ctrl | Effect |
|---|---|---|---|---|
| **`Off`** | yes | no | no | recommendations only — **nothing is touched** |
| **`Initial`** | yes | no | yes | new pods get the recommended size; existing pods are left alone |
| **`Recreate`** | yes | **yes** | yes | mis-sized pods are evicted and come back resized |
| **`Auto`** | yes | yes | yes | today, identical to `Recreate` |

**`Auto` is a promise, not a behaviour.** It is defined as "use the best
available mechanism", and once in-place resize is stable it will use that. Until
then it evicts, exactly like `Recreate`. If a question asks what `Auto` does
today, the answer is *the same as `Recreate`*.

**Start with `Off`.** It costs nothing, disrupts nothing, and after a day you
have real numbers for every container in the cluster:

```bash
kubectl describe vpa myapp-vpa
```

```
  Recommendation:
    Container Recommendations:
      Container Name:  app
      Lower Bound:   cpu: 25m,   memory: 262144k
      Target:        cpu: 587m,  memory: 262144k
      Uncapped Target: cpu: 587m, memory: 262144k
      Upper Bound:   cpu: 1235m, memory: 393216k
```

Four numbers, and they are not four guesses at the same thing:

| Field | Meaning |
|---|---|
| **Target** | what the VPA would set requests to |
| **Lower Bound** | below this, the pod is definitely under-provisioned |
| **Upper Bound** | above this, it is definitely wasting money |
| **Uncapped Target** | what Target would be without your `maxAllowed` — **if these differ, your cap is binding** |

### 11.5 HPA or VPA

| | **HPA** | **VPA** |
|---|---|---|
| Changes | **number of pods** | **size of pods** |
| Built in | **yes** | no — install it |
| Disruption | none — adds pods alongside | **evicts pods** to apply |
| Traffic spikes | **good** — seconds | poor — needs a restart |
| Cost control | removes idle pods | stops over-provisioning |
| Best for | stateless web, APIs, queues | **databases, JVMs, ML jobs, anything singleton** |
| Ceiling | node count | **one node's capacity** |

> **Do not point both at the same metric on the same workload.** An HPA scaling
> on CPU and a VPA adjusting CPU requests form a feedback loop: the VPA raises
> requests, per-pod utilisation appears to fall, the HPA scales in, load per pod
> rises, the VPA raises requests again. The workload oscillates and neither
> controller is wrong. **The supported combination is HPA on CPU/memory + VPA on
> nothing, or HPA on a custom metric (requests per second) + VPA on CPU/memory.**

The dividing line in one sentence: **HPA is for load that arrives in parallel;
VPA is for load that cannot be split.** One pod that needs 8 GB is a VPA problem
no number of replicas will solve.

### 11.6 Where the Cluster Autoscaler fits

Both pod autoscalers eventually ask for capacity the cluster does not have — the
HPA creates a pod that stays `Pending`, the VPA evicts a pod that cannot be
rescheduled at its new size. **The Cluster Autoscaler watches for exactly that
signal** — unschedulable pods — and adds a node.

It is out of scope for the exam and absent from a kind cluster (there is no
cloud API to call), but the failure it prevents is one you will meet in Part 2:
a resize request that is `Infeasible` because no node is large enough.

---

## Part 2 - Hands-on lab

Three parts, on two clusters:

- **A.** the default behaviour, on your normal `devops` cluster
- **B.** in-place resize, on a **throwaway cluster** with the feature gate on
- **C.** the VPA, back on `devops`

### A. What happens today when you change resources

```bash
kubectl create namespace cka11
kubectl config set-context --current --namespace=cka11
kubectl apply -f solution/02-load-target.yaml
kubectl rollout status deployment/hungry
kubectl get pods -o wide
```

Note the pod names and their `startTime`, then change the size:

```bash
kubectl get pods -o custom-columns=NAME:.metadata.name,START:.status.startTime
kubectl set resources deployment/hungry --requests=cpu=100m --limits=cpu=600m
kubectl rollout status deployment/hungry
kubectl get pods -o custom-columns=NAME:.metadata.name,START:.status.startTime
```

**Different names, new start times.** Nothing was resized — the pods were
replaced. Confirm what actually happened:

```bash
kubectl get rs -l app=hungry
kubectl describe deployment hungry | grep -A5 Events
```

A second ReplicaSet, a rolling update, every process restarted. For a database
that is the whole problem in one command.

Now watch a related trap:

```bash
kubectl get pod -l app=hungry -o jsonpath='{.items[0].status.qosClass}{"\n"}'
```

`Burstable` — requests below limits ([Day 16](../../days/day-16-resources-requests-limits-metrics-server/)).
**Remember this for part B**: in-place resize cannot move a pod between QoS
classes, so it can never take this pod to `Guaranteed`.

### B. In-place resize, on a feature-gated cluster

`InPlacePodVerticalScaling` is alpha in 1.31 (this repo's version) and off by
default. Rather than editing the API server *and* the kubelet on your working
cluster, create a small one with the gate on:

```bash
kind create cluster --name resize-lab --config solution/kind-inplace-resize.yaml
kubectl config get-contexts | grep resize-lab
kubectl config use-context kind-resize-lab
```

Confirm the gate reached both places that need it:

```bash
docker exec resize-lab-control-plane grep -i feature-gates /etc/kubernetes/manifests/kube-apiserver.yaml
docker exec resize-lab-control-plane grep -i -A3 featureGates /var/lib/kubelet/config.yaml
```

**Both must show it.** The API server decides whether the *field* is accepted;
**the kubelet is what actually rewrites the cgroup**. A gate on the API server
alone gives you a resize that is accepted and never applied — a confusing state
worth being able to recognise.

```bash
kubectl create namespace cka11
kubectl apply -f solution/01-resizable-pod.yaml
kubectl wait --for=condition=Ready pod/resizable -n cka11 --timeout=60s
```

Record the baseline. **The restart count is the measurement**:

```bash
kubectl get pod resizable -n cka11 -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
kubectl get pod resizable -n cka11 -o jsonpath='{.status.containerStatuses[0].allocatedResources}{"\n"}'
docker exec resize-lab-control-plane sh -c \
  'cat $(find /sys/fs/cgroup -name "cpu.max" -path "*kubepods*" | head -1)' 2>/dev/null || true
```

**Resize the CPU** — declared `NotRequired`, so it should not restart:

```bash
kubectl patch pod resizable -n cka11 --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"300m","memory":"64Mi"},"limits":{"cpu":"600m","memory":"128Mi"}}}]}}'

sleep 5
kubectl get pod resizable -n cka11 -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
kubectl get pod resizable -n cka11 -o jsonpath='{.status.containerStatuses[0].allocatedResources}{"\n"}'
kubectl get pod resizable -n cka11 -o jsonpath='{.status.resize}{"\n"}'
```

**`restartCount` is still 0 and `allocatedResources` shows 300m.** The container
never stopped. Same PID, same connections, same warm cache — the thing that was
impossible in part A.

> On **1.33 and later** the same patch needs `--subresource resize`:
> ```bash
> kubectl patch pod resizable --subresource resize --patch '{...}'
> ```
> Both forms are worth knowing; which one works tells you the cluster's version.

**Now resize the memory** — declared `RestartContainer`:

```bash
kubectl patch pod resizable -n cka11 --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"300m","memory":"128Mi"},"limits":{"cpu":"600m","memory":"256Mi"}}}]}}'

sleep 8
kubectl get pod resizable -n cka11 -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
kubectl get pod resizable -n cka11
```

**`restartCount` is now 1 — but look at the pod:** same name, same IP, same
node, same age. **One container restarted; the pod did not.** That is a
different and much cheaper event than part A's replacement.

```bash
kubectl get pod resizable -n cka11 -o wide
kubectl describe pod resizable -n cka11 | grep -A8 Events
```

**Now hit a limitation on purpose.** Ask for more CPU than the node has:

```bash
kubectl patch pod resizable -n cka11 --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"64"},"limits":{"cpu":"64"}}}]}}'
sleep 5
kubectl get pod resizable -n cka11 -o jsonpath='{.status.resize}{"\n"}'
kubectl describe pod resizable -n cka11 | grep -A5 Events
```

`Infeasible` — **and the pod keeps running at its old size.** The request is not
rejected outright and the pod is not harmed; it simply is not applied. This is
the state a Cluster Autoscaler (11.6) would resolve by adding a bigger node.

Put it back and return to your real cluster:

```bash
kubectl patch pod resizable -n cka11 --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}'
kubectl config use-context kind-devops
kubectl config set-context --current --namespace=cka11
```

Keep `resize-lab` until `verify.sh` has run; delete it at the end of the
assignment.

### C. The Vertical Pod Autoscaler

Back on the `devops` cluster. The VPA needs metrics, so metrics-server must be
running — you installed it in [Day 16](../../days/day-16-resources-requests-limits-metrics-server/):

```bash
kubectl top nodes
kubectl top pods -n cka11
```

If `kubectl top` errors, fix that first; a VPA with no metrics produces no
recommendations and looks broken for the wrong reason.

```bash
bash solution/install-vpa.sh
```

It clones the pinned release, runs `hack/vpa-up.sh`, and shows you what was
registered. Two of those outputs matter:

```bash
kubectl -n kube-system get pods | grep vpa
kubectl get crd | grep verticalpodautoscaler
kubectl get mutatingwebhookconfiguration | grep vpa
```

**Three deployments, one CRD, and a mutating webhook.** That webhook is the
admission controller from 11.4 — the VPA is a direct application of
[CKA 07](../07-admission-controllers/), and now you know exactly what it does
when a pod is created.

#### C1 - Recommendation only

```bash
kubectl apply -f solution/03-vpa-off.yaml
kubectl get vpa -n cka11
```

The `hungry` pods are burning a full core each against a `50m` request. Give the
recommender a few minutes — it wants real observations, not one sample:

```bash
kubectl top pods -n cka11
sleep 180
kubectl describe vpa hungry-vpa -n cka11 | sed -n '/Recommendation/,$p'
```

```
  Container Recommendations:
    Container Name:    app
    Lower Bound:       cpu: 100m
    Target:            cpu: 300m
    Uncapped Target:   cpu: 1005m
    Upper Bound:       cpu: 300m
```

Read those four numbers against the table in 11.4. **`Uncapped Target` is
roughly a full core while `Target` sits at exactly `300m`** — the `maxAllowed`
in `03-vpa-off.yaml`. The gap between them is the VPA telling you your own cap
is the binding constraint, not the workload.

Now confirm the mode did what it said:

```bash
kubectl get pods -n cka11 -o custom-columns=\
NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,START:.status.startTime
```

**Still `50m`, still the original pods.** `updateMode: "Off"` observed and
recommended and changed nothing — which is why it is safe to put on every
workload in a cluster you are trying to understand.

#### C2 - Let it act

```bash
kubectl apply -f solution/04-vpa-recreate.yaml
kubectl get pods -n cka11 -w
```

Within a few minutes the updater evicts a pod, the Deployment recreates it, and
the admission webhook rewrites its requests on the way in:

```bash
kubectl get pods -n cka11 -o custom-columns=\
NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,AGE:.metadata.creationTimestamp
kubectl get events -n cka11 --sort-by=.lastTimestamp | grep -i evict | tail -3
```

```
Normal  EvictedByVPA  pod/hungry-xxxxx  Pod was evicted by VPA Updater to apply resource recommendation.
```

**New pod names and a new CPU request.** Follow the chain once more, because
this is the exam answer: the **updater evicted**, the **Deployment recreated**,
the **admission controller mutated**. No component resized anything.

```bash
kubectl get pod -n cka11 -l app=hungry \
  -o jsonpath='{.items[0].metadata.annotations}{"\n"}' | tr ',' '\n' | grep -i vpa
```

The VPA leaves an annotation on the pods it has touched — evidence, on the
object, of a controller having rewritten what you submitted.

**Note it evicted one pod, not both.** The updater respects disruption limits;
with only two replicas it will not take them both at once. That behaviour is why
`updateMode: Recreate` on a single-replica Deployment is a bad idea — the one
eviction is a full outage.

### Cleanup

```bash
kubectl delete -f solution/04-vpa-recreate.yaml --ignore-not-found
kubectl delete namespace cka11 --ignore-not-found
bash solution/install-vpa.sh uninstall
kind delete cluster --name resize-lab
kubectl config use-context kind-devops
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Pick the autoscaler

For each workload, choose HPA, VPA, both, or neither — and say why in one line:

1. A stateless REST API whose traffic triples every weekday at 09:00.
2. A single-replica PostgreSQL StatefulSet whose working set has grown all year.
3. A JVM batch job that needs 6 GB for the first 90 seconds and 500 MB after.
4. A queue consumer whose backlog, not its CPU, indicates load.
5. A DaemonSet log collector.

Two of these have answers that are *not* an autoscaler at all.

### C2 - Diagnose a silent VPA

A VPA has existed for an hour and `kubectl describe vpa` shows no
`Recommendation:` section at all. List, in order, the four things you would
check. For each, give the command and what a healthy answer looks like.

### C3 - The oscillation

Write out, step by step, what happens over ten minutes when an HPA targeting
50% CPU and a VPA in `Auto` mode are both applied to the same Deployment.
Identify the exact feedback loop, and give the two supported configurations that
avoid it.

### C4 - Resize that does not take

You patch a pod's CPU on a cluster where `InPlacePodVerticalScaling` is enabled.
The patch is accepted, `spec` shows the new value, but `allocatedResources`
never changes and `status.resize` stays empty. Give three distinct causes and
the command that distinguishes each.

### C5 - Argue against in-place resize

In-place resize sounds strictly better than pod replacement. Give two situations
where replacing the pod is the *correct* choice even on a cluster that supports
resizing, and explain what in-place resize cannot fix in each.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

It checks the parts it can reach: on `kind-resize-lab` it verifies the feature
gate is on both components and that a CPU resize left `restartCount` at 0; on
`kind-devops` it verifies the three VPA components, the CRD, the webhook, and
that a recommendation with a binding `maxAllowed` was produced.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# manual vertical scaling, without opening an editor
kubectl set resources deployment/app --requests=cpu=200m,memory=256Mi --limits=cpu=1,memory=512Mi

# manual horizontal scaling
kubectl scale deployment/app --replicas=5

# an HPA in one line (there is NO equivalent for VPA)
kubectl autoscale deployment app --cpu-percent=50 --min=1 --max=10

# what a VPA currently recommends
kubectl describe vpa NAME | sed -n '/Recommendation/,$p'
kubectl get vpa NAME -o jsonpath='{.status.recommendation.containerRecommendations}{"\n"}'

# what a pod ACTUALLY got, versus what it asked for
kubectl get pod X -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl get pod X -o jsonpath='{.status.containerStatuses[0].allocatedResources}{"\n"}'
kubectl get pod X -o jsonpath='{.status.resize}{"\n"}'

# is the feature gate on?
grep feature-gates /etc/kubernetes/manifests/kube-apiserver.yaml
grep -A5 featureGates /var/lib/kubelet/config.yaml
```

**Traps**

- **Changing resources on a Deployment replaces the pods.** That is the default
  and it is what a question means by "disruptive".
- **In-place resize needs the gate on the kubelet too**, not only the API
  server.
- **`resizePolicy.restartPolicy` is per resource** and takes only `NotRequired`
  or `RestartContainer`. It is unrelated to the pod's `restartPolicy`.
- **`RestartContainer` restarts a container, not the pod.** The pod keeps its
  name, IP and node.
- **Resize cannot change the QoS class**, cannot touch init containers, and
  cannot add a request that was not already there.
- **An infeasible resize is not an error.** The pod keeps running at its old
  size and `status.resize` says `Infeasible`.
- **The VPA is not built in.** No `kubectl autoscale` equivalent; install it,
  and it brings a CRD and a **mutating webhook**.
- **The updater evicts; it does not resize.** The admission controller applies
  the new numbers to the replacement pod.
- **`Auto` behaves exactly like `Recreate` today.**
- **`updateMode: "Off"` is the safe default** and the right answer to "how would
  you find out whether our requests are wrong".
- **Never run an HPA and a VPA on the same metric for the same workload.**
- **`maxAllowed` silently caps `Target`.** Compare it against `Uncapped Target`
  before believing a recommendation.

---

**Previous:** [CKA 10 — Multi-Container Pods, Init Containers and Sidecars](../10-multi-container-and-init/)
**Next:** [CKA 12 — Cluster Maintenance and etcd Backup](../12-cluster-maintenance/)
