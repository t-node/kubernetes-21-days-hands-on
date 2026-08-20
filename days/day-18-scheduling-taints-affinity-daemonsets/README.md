# Day 18 — Scheduling, Taints, Affinity & DaemonSets

**Time:** 75-90 minutes
**Prerequisites:** Day 04 (labels), Day 16 (requests)

Until now you have let the scheduler decide everything. Today you take control —
and answer one of the most commonly asked Kubernetes interview questions:
*"why don't application pods run on the control plane?"*

> **Multi-node cluster required.** If you used
> `kind-config-single-node.yaml`, recreate with
> `kind create cluster --config cluster/kind-config.yaml`.

---

## Part 1 - Concepts

### 18.1 How the scheduler picks a node

Two phases, from Day 01:

1. **Filtering (predicates)** — eliminate nodes that *cannot* work:
   insufficient CPU/memory, a `nodeSelector` that does not match, a taint with
   no matching toleration, a required affinity rule unmet, a host port already
   taken, a volume that cannot attach in that zone.
2. **Scoring (priorities)** — rank the survivors: spread pods of the same
   Service across nodes, prefer nodes with the image already cached, honour
   preferred affinity, balance resource usage. Highest score wins.

If filtering leaves **zero** nodes, the pod stays `Pending` and
`kubectl describe pod` names exactly which predicate rejected each node:

```
0/3 nodes are available: 1 node(s) had untolerated taint
{node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu.
```

Read that line carefully every time. It counts nodes per reason, which localises
the problem immediately.

### 18.2 The tools, from blunt to subtle

| Tool | Direction | Force |
|---|---|---|
| `nodeName` | pod to node | absolute; bypasses the scheduler entirely |
| `nodeSelector` | pod to node | hard requirement, exact label match |
| **node affinity** | pod to node | hard **or soft**, expressive operators |
| **pod affinity/anti-affinity** | pod to *other pods* | co-locate or spread |
| **taints and tolerations** | node **repels** pods | the node's choice, not the pod's |
| topology spread constraints | pod to even distribution | spread across zones/nodes |

The distinction interviewers probe: **affinity is the pod's preference; taints
are the node's rejection.** Affinity says "I want to be there"; a taint says
"you may not come here unless you tolerate this". They are complementary and you
often need both.

### 18.3 nodeSelector, the simple one

```yaml
spec:
  nodeSelector:
    disktype: ssd
```

Schedule only on nodes labelled `disktype=ssd`. All or nothing: if no node
matches, the pod stays `Pending` forever. Your kind cluster already carries
these labels — see `cluster/kind-config.yaml`.

### 18.4 Node affinity, nodeSelector with grammar

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:      # HARD
      nodeSelectorTerms:
        - matchExpressions:
            - key: disktype
              operator: In              # In, NotIn, Exists, DoesNotExist, Gt, Lt
              values: [ssd, nvme]
    preferredDuringSchedulingIgnoredDuringExecution:     # SOFT
      - weight: 80
        preference:
          matchExpressions:
            - key: tier
              operator: In
              values: [general]
```

Those long field names are self-documenting once you see the pattern:

- **`requiredDuringScheduling`** — a hard filter; unmet means `Pending`.
- **`preferredDuringScheduling`** — a scoring hint; unmet only lowers the score.
- **`IgnoredDuringExecution`** — once a pod is running, changing node labels does
  **not** evict it. A `RequiredDuringExecution` variant has been proposed for
  years and still does not exist.

Within `nodeSelectorTerms`, multiple terms are **OR**; multiple
`matchExpressions` inside one term are **AND**.

### 18.5 Pod affinity and anti-affinity

Schedule relative to *other pods* rather than node labels:

```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app: backend
      topologyKey: kubernetes.io/hostname     # "together" == same node
```

"Never place two `app: backend` pods on the same node." That is the standard
high-availability pattern: one node failing must not take out every replica.

`topologyKey` defines what "together" means:

| topologyKey | Means |
|---|---|
| `kubernetes.io/hostname` | the same node |
| `topology.kubernetes.io/zone` | the same availability zone |
| `topology.kubernetes.io/region` | the same region |

**Use `preferred` anti-affinity, not `required`, unless you are certain.** With
`required` anti-affinity on hostname you can never have more replicas than
nodes — scale to 4 on a 3-node cluster and the fourth pod is `Pending` forever.
That is Break It B.

**Topology spread constraints** are the modern, better-behaved alternative:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway        # or DoNotSchedule
    labelSelector:
      matchLabels:
        app: backend
```

"Keep the difference between the busiest and emptiest node at most 1, but
schedule anyway if you cannot." Even spreading without the brittleness.

### 18.6 Taints and tolerations

A **taint** sits on a **node** and repels pods. A **toleration** sits on a
**pod** and lets it ignore a specific taint.

```bash
kubectl taint nodes devops-worker dedicated=database:NoSchedule
```

Format: `key=value:Effect`. Three effects:

| Effect | Meaning |
|---|---|
| `NoSchedule` | do not place new pods here unless they tolerate it |
| `PreferNoSchedule` | a soft version — avoid if possible |
| `NoExecute` | as above, **and evict pods already running here** that do not tolerate it |

```yaml
tolerations:
  - key: dedicated
    operator: Equal          # or Exists, which matches any value
    value: database
    effect: NoSchedule
```

> **A toleration only grants permission; it does not attract.** A pod tolerating
> the database taint may *also* be scheduled on any untainted node. To force it
> onto the tainted node you need **taint + toleration + affinity or
> nodeSelector** together.
>
> This is the most commonly misunderstood point about taints, and a frequent
> interview question.

### 18.7 The control-plane question

> **Why do API server, scheduler and controller-manager pods run on the control
> plane, while your application pods do not?**

The complete answer, in four parts:

1. Control-plane nodes are automatically tainted at bootstrap with
   `node-role.kubernetes.io/control-plane:NoSchedule`.
2. Ordinary application pods carry **no matching toleration**, so the scheduler
   filters those nodes out during the filtering phase.
3. The control-plane components themselves are **static pods** — the kubelet
   reads them from `/etc/kubernetes/manifests` on local disk and starts them
   **without the scheduler being involved at all**, so the taint never applies
   to them.
4. Cluster-wide DaemonSets such as `kube-proxy` and the CNI *do* declare
   tolerations, which is why they run everywhere, control plane included.

You verify all four in Step 1.

The purpose is resilience: an application consuming all the CPU on a
control-plane node would take down the API server, and with it your ability to
fix anything.

### 18.8 Taints Kubernetes applies on its own

The node controller adds these automatically. Recognising them saves debugging
time:

| Taint | When |
|---|---|
| `node.kubernetes.io/not-ready` | node is NotReady |
| `node.kubernetes.io/unreachable` | the node controller lost contact |
| `node.kubernetes.io/memory-pressure` | node is low on memory |
| `node.kubernetes.io/disk-pressure` | node is low on disk |
| `node.kubernetes.io/unschedulable` | you ran `kubectl cordon` |

`kubectl cordon` simply adds the last one. `kubectl drain` cordons **and**
evicts. That pair is the standard node-maintenance sequence.

### 18.9 DaemonSets

A **DaemonSet** runs exactly one pod on every node, or every node matching a
selector. There is no `replicas` field — the node count *is* the replica count.
Add a node and a pod appears on it automatically.

Used for anything node-scoped:

- log collection (Fluent Bit, Filebeat) reading `/var/log`
- metrics (node-exporter) reading `/proc` and `/sys`
- networking: the CNI plugin, `kube-proxy`
- storage plugins and security agents

You have been running several since Day 01:

```bash
kubectl get daemonsets -n kube-system
```

DaemonSets almost always declare broad tolerations, because a monitoring agent
must run on *every* node — including tainted and control-plane ones.

---

## Part 2 - Hands-on lab

### Step 1: Answer the control-plane question with evidence

```bash
# 1. the taint exists
kubectl describe node devops-control-plane | grep -A3 Taints
# Taints: node-role.kubernetes.io/control-plane:NoSchedule

# 2. your app pods have no matching toleration
kubectl get pods -n devboard -o wide            # all on workers
kubectl get pod -n devboard -l app=backend \
  -o jsonpath='{.items[0].spec.tolerations}' | tr ',' '\n'
# only the default not-ready / unreachable tolerations

# 3. the control-plane components are STATIC pods, not scheduled
kubectl get pod kube-apiserver-devops-control-plane -n kube-system \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
# Node   <- owned by the NODE, not a ReplicaSet. It was never scheduled.
docker exec devops-control-plane ls /etc/kubernetes/manifests/

# 4. DaemonSets DO tolerate it, which is why they run there
kubectl get pods -n kube-system -o wide | grep control-plane
kubectl get daemonset kube-proxy -n kube-system \
  -o jsonpath='{.spec.template.spec.tolerations}' | tr ',' '\n'
```

Four commands, four parts of the answer. Say it out loud once.

### Step 2: nodeSelector

```bash
kubectl get nodes --show-labels | tr ',' '\n' | grep -E "disktype|tier"
```

Your kind config labelled `devops-worker` with `disktype=ssd` and
`devops-worker2` with `disktype=hdd`.

```bash
kubectl apply -f solution/01-nodeselector.yaml
kubectl get pods -n devboard -l demo=nodeselector -o wide
```

All three replicas land on `devops-worker`. Now ask for a label nothing has:

```bash
kubectl patch deployment ssd-only -n devboard -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"disktype":"nvme"}}}}}'

kubectl get pods -n devboard -l demo=nodeselector
kubectl describe pod -n devboard -l demo=nodeselector | grep -A3 Events
# 0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector
```

`Pending` forever. There is no "close enough" — nodeSelector is absolute.

```bash
kubectl delete -f solution/01-nodeselector.yaml
```

### Step 3: Node affinity, hard and soft

```bash
kubectl apply -f solution/02-node-affinity.yaml
kubectl get pods -n devboard -l demo=affinity -o wide
```

The manifest requires `disktype in (ssd, hdd)` — both workers qualify — and
*prefers* `tier=general` with weight 80. Compare the behaviour when a preference
cannot be met:

```bash
kubectl patch deployment affinity-demo -n devboard --type=json -p \
'[{"op":"replace","path":"/spec/template/spec/affinity/nodeAffinity/preferredDuringSchedulingIgnoredDuringExecution/0/preference/matchExpressions/0/values","value":["nonexistent"]}]'

kubectl rollout status deployment/affinity-demo -n devboard
kubectl get pods -n devboard -l demo=affinity -o wide
```

Still scheduled. **`preferred` never blocks** — it only influences scoring. That
contrast with Step 2 is the point of this step.

```bash
kubectl delete -f solution/02-node-affinity.yaml
```

### Step 4: Anti-affinity for high availability

```bash
kubectl apply -f solution/03-pod-anti-affinity.yaml
kubectl get pods -n devboard -l demo=antiaffinity -o wide
```

Two replicas, two different nodes — guaranteed, not luck. Prove it by scaling
past the node count:

```bash
kubectl scale deployment spread-demo --replicas=4 -n devboard
kubectl get pods -n devboard -l demo=antiaffinity -o wide
kubectl describe pod -n devboard -l demo=antiaffinity | grep -A3 "FailedScheduling"
# didn't match pod anti-affinity rules
```

Two Running, two Pending. **`required` anti-affinity caps your replicas at the
node count.** This is a real production incident pattern: an HPA scales up, and
the new pods can never schedule.

```bash
kubectl delete -f solution/03-pod-anti-affinity.yaml
```

### Step 5: Topology spread constraints — the better tool

```bash
kubectl apply -f solution/04-topology-spread.yaml
kubectl get pods -n devboard -l demo=spread -o wide

kubectl scale deployment topology-demo --replicas=6 -n devboard
kubectl get pods -n devboard -l demo=spread -o wide | awk '{print $7}' | sort | uniq -c
```

Six pods spread evenly (2/2/2), and — crucially — with
`whenUnsatisfiable: ScheduleAnyway` they **all schedule**. Even distribution
without the brittleness of required anti-affinity. Prefer this.

```bash
kubectl delete -f solution/04-topology-spread.yaml
```

### Step 6: Taints — dedicate a node to the database

```bash
kubectl taint nodes devops-worker2 dedicated=database:NoSchedule
kubectl describe node devops-worker2 | grep -A3 Taints
```

Existing pods are unaffected — `NoSchedule` only applies to *new* placements:

```bash
kubectl get pods -n devboard -o wide | grep worker2
```

New pods now avoid it:

```bash
kubectl scale deployment backend --replicas=6 -n devboard
kubectl get pods -n devboard -l app=backend -o wide | awk '{print $7}' | sort | uniq -c
# nothing on devops-worker2
kubectl scale deployment backend --replicas=2 -n devboard
```

Now give Postgres a toleration **and** an affinity, and watch the difference
between them:

```bash
kubectl apply -f solution/05-postgres-tolerated.yaml
kubectl delete pod postgres-0 -n devboard
kubectl wait --for=condition=Ready pod/postgres-0 -n devboard --timeout=180s
kubectl get pod postgres-0 -n devboard -o wide
```

`postgres-0` is on `devops-worker2`, alone. That required **both** pieces:

- the **toleration** made it *allowed* there
- the **nodeAffinity** made it *go* there

Remove the affinity and it could land anywhere — a toleration is permission, not
attraction. Test it if you want to be sure; that single experiment settles the
concept permanently.

### Step 7: NoExecute evicts running pods

```bash
kubectl get pods -n devboard -o wide | grep worker
kubectl taint nodes devops-worker maintenance=true:NoExecute
kubectl get pods -n devboard -o wide -w         # Ctrl-C after ~30s
```

Pods on `devops-worker` are **evicted immediately** and rescheduled elsewhere.
`NoSchedule` affects the future; `NoExecute` affects the present.

```bash
kubectl taint nodes devops-worker maintenance=true:NoExecute-      # trailing dash removes
kubectl taint nodes devops-worker2 dedicated=database:NoSchedule-
```

Note the trailing `-` syntax for removing a taint.

### Step 8: cordon and drain — the real maintenance workflow

```bash
kubectl cordon devops-worker
kubectl get nodes                          # STATUS: Ready,SchedulingDisabled
kubectl describe node devops-worker | grep -A3 Taints
# node.kubernetes.io/unschedulable:NoSchedule    <- cordon is just a taint

kubectl drain devops-worker --ignore-daemonsets --delete-emptydir-data
kubectl get pods -n devboard -o wide       # nothing on devops-worker except DaemonSets
```

`--ignore-daemonsets` is required because DaemonSet pods cannot be evicted —
they would be immediately recreated. `--delete-emptydir-data` acknowledges that
`emptyDir` contents are lost.

```bash
kubectl uncordon devops-worker
kubectl get nodes
```

**cordon → drain → patch/reboot → uncordon** is the node maintenance sequence.
Being able to state it is a common interview checkpoint.

Note: a **PodDisruptionBudget** makes `drain` respect availability:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 1          # or maxUnavailable
  selector:
    matchLabels:
      app: backend
```

With a PDB, `drain` blocks rather than evicting past the threshold — which is
exactly what you want during a rolling node upgrade.

```bash
kubectl apply -f solution/06-pdb.yaml
kubectl get pdb -n devboard
```

### Step 9: A DaemonSet

```bash
kubectl apply -f solution/07-daemonset.yaml
kubectl get daemonset,pods -n devboard -l app=node-logger -o wide
```

```
NAME                     DESIRED   CURRENT   READY   NODE SELECTOR
daemonset/node-logger    3         3         3       <none>
```

**Three pods, three nodes — including the control plane**, because the manifest
tolerates its taint. There is no `replicas` field anywhere; the node count is
the replica count.

Prove it adapts automatically:

```bash
kubectl cordon devops-worker2
kubectl taint nodes devops-worker2 gone=true:NoExecute
kubectl get daemonset node-logger -n devboard      # DESIRED drops to 2

kubectl taint nodes devops-worker2 gone=true:NoExecute-
kubectl uncordon devops-worker2
kubectl get daemonset node-logger -n devboard      # back to 3
```

Look at what the DaemonSet mounts:

```bash
kubectl exec -n devboard ds/node-logger -- ls /host/var/log | head
```

A `hostPath` mount of the node's `/var/log`. That is the legitimate use of
`hostPath` from Day 14 — and also why a DaemonSet with hostPath access is a
sensitive thing to grant.

```bash
kubectl delete -f solution/07-daemonset.yaml
```

---

## Validate

```bash
# the control-plane taint exists and your pods avoid it
kubectl describe node devops-control-plane | grep -c "node-role.kubernetes.io/control-plane:NoSchedule"
kubectl get pods -n devboard -o wide | grep -c control-plane      # 0

# nodeSelector puts pods where you say
kubectl apply -f solution/01-nodeselector.yaml
kubectl rollout status deployment/ssd-only -n devboard
kubectl get pods -n devboard -l demo=nodeselector -o wide | awk 'NR>1{print $7}' | sort -u
# devops-worker only

# a DaemonSet lands one pod per node
kubectl apply -f solution/07-daemonset.yaml
kubectl rollout status daemonset/node-logger -n devboard
kubectl get daemonset node-logger -n devboard \
  -o jsonpath='{.status.desiredNumberScheduled}{"\n"}'            # 3

kubectl delete -f solution/01-nodeselector.yaml -f solution/07-daemonset.yaml
```

Ready for Day 19 when you can:

1. Give the full four-part answer to the control-plane question.
2. Explain why a toleration alone does not put a pod on a tainted node.
3. Say when `required` anti-affinity will leave pods permanently `Pending`.
4. State the cordon/drain/uncordon sequence and what `--ignore-daemonsets` is for.

---

## Break it

**A. nodeSelector for a label nothing has.**

```bash
kubectl run picky --image=nginx:alpine -n devboard \
  --overrides='{"spec":{"nodeSelector":{"gpu":"nvidia-a100"}}}'
kubectl get pod picky -n devboard                 # Pending
kubectl describe pod picky -n devboard | grep -A3 Events
kubectl delete pod picky -n devboard
```

**B. required anti-affinity beyond the node count.**

```bash
kubectl apply -f solution/03-pod-anti-affinity.yaml
kubectl scale deployment spread-demo --replicas=5 -n devboard
kubectl get pods -n devboard -l demo=antiaffinity
# 3 Running, 2 Pending -- forever
kubectl delete -f solution/03-pod-anti-affinity.yaml
```

Now imagine an HPA driving that scale-up at 2 a.m. under real traffic. The
scaling silently stops working. **Use `preferred`, or topology spread
constraints.**

**C. Taint every node.**

```bash
for n in $(kubectl get nodes -o name); do
  kubectl taint ${n#node/} everything=broken:NoSchedule --overwrite
done

kubectl run homeless --image=nginx:alpine -n devboard
kubectl describe pod homeless -n devboard | grep -A3 Events
# 0/3 nodes are available: 3 node(s) had untolerated taint

for n in $(kubectl get nodes -o name); do
  kubectl taint ${n#node/} everything=broken:NoSchedule-
done
kubectl delete pod homeless -n devboard
```

**D. Toleration without affinity.**

```bash
kubectl taint nodes devops-worker2 dedicated=database:NoSchedule
kubectl apply -f solution/08-tolerating-only.yaml
kubectl get pods -n devboard -l demo=toleration -o wide
```

Five replicas, all tolerating the taint — and they scatter across **all three
nodes**, not just the tainted one. The toleration granted permission; nothing
attracted them. Section 18.6, demonstrated.

```bash
kubectl delete -f solution/08-tolerating-only.yaml
kubectl taint nodes devops-worker2 dedicated=database:NoSchedule-
```

**E. nodeName — bypassing the scheduler entirely.**

```bash
kubectl apply -f solution/09-nodename.yaml
kubectl get pod pinned -n devboard -o wide
kubectl describe pod pinned -n devboard | grep -c "default-scheduler"     # 0
```

No scheduling event at all — the kubelet on that node simply picked it up.
`nodeName` ignores taints, resource availability and everything else. If the
node is full, the kubelet rejects the pod and it stays `OutOfcpu` forever with
no rescheduling. **Never use it outside debugging.**

```bash
kubectl delete -f solution/09-nodename.yaml
```

**F. Drain a node running your database.**

```bash
kubectl get pod postgres-0 -n devboard -o wide     # note the node
kubectl drain <that-node> --ignore-daemonsets --delete-emptydir-data --force
kubectl get pods -n devboard -o wide
```

Postgres is evicted, and its pod has to reattach a `ReadWriteOnce` volume on the
new node. Depending on your storage class, that may take a while — or, with
`local-path`, may not be possible at all, leaving `postgres-0` `Pending`.

**This is why node maintenance on stateful workloads needs planning**: a PDB, a
storage class that supports migration, and a maintenance window.

```bash
kubectl uncordon <that-node>
```

---

## Interview questions

<details>
<summary><b>1. Why do application pods not run on the control plane?</b> (very common)</summary>

Control-plane nodes carry an automatic
`node-role.kubernetes.io/control-plane:NoSchedule` taint, and ordinary
application pods have no matching toleration, so the scheduler filters those
nodes out. The control-plane components themselves are static pods started
directly by the kubelet from `/etc/kubernetes/manifests`, so the scheduler and
therefore the taint never apply to them. DaemonSets like kube-proxy and the CNI
declare tolerations explicitly, which is why they do run there. The purpose is
isolation: an application starving a control-plane node would take down the API
server and with it your ability to fix anything.
</details>

<details>
<summary><b>2. Taints and tolerations vs node affinity?</b></summary>

Taints belong to the node and repel pods - the node's decision. Affinity belongs
to the pod and expresses attraction - the pod's decision. A toleration only
grants permission to be scheduled on a tainted node; it does not make the pod go
there. Dedicating a node to one workload requires all three: taint the node,
tolerate the taint, and add affinity or a nodeSelector so the pod actually
targets it.
</details>

<details>
<summary><b>3. Difference between NoSchedule, PreferNoSchedule and NoExecute?</b></summary>

NoSchedule prevents new pods without a matching toleration from being placed but
leaves running pods alone. PreferNoSchedule is a soft version - the scheduler
avoids the node when it can. NoExecute additionally evicts pods already running
there that do not tolerate it, which is how the node controller drains a node it
considers unreachable.
</details>

<details>
<summary><b>4. requiredDuringScheduling vs preferredDuringScheduling?</b></summary>

Required is a hard filter: if no node satisfies it, the pod stays Pending
forever. Preferred contributes to node scoring with a weight, so the pod still
schedules somewhere if the preference cannot be met. IgnoredDuringExecution in
both names means changing node labels afterwards does not evict running pods -
there is no RequiredDuringExecution variant.
</details>

<details>
<summary><b>5. How do you guarantee replicas land on different nodes?</b></summary>

Pod anti-affinity with `topologyKey: kubernetes.io/hostname`, or better,
topology spread constraints with `maxSkew: 1`. Prefer the soft forms:
`required` anti-affinity caps replicas at the node count, so a scale-up beyond
that leaves pods permanently Pending - a real incident pattern when an HPA is
involved. Topology spread with `whenUnsatisfiable: ScheduleAnyway` gives even
distribution without that failure mode.
</details>

<details>
<summary><b>6. What is a DaemonSet and when do you use one?</b></summary>

A controller that runs exactly one pod per node, or per node matching a
selector. There is no replicas field - the node count is the replica count, and
adding a node automatically adds a pod. It is for node-scoped agents: log
shippers, metrics exporters, CNI plugins, kube-proxy, storage drivers, security
agents. They usually declare broad tolerations so they also run on tainted and
control-plane nodes.
</details>

<details>
<summary><b>7. Walk me through node maintenance.</b></summary>

`kubectl cordon` to mark it unschedulable - which is just adding the
`node.kubernetes.io/unschedulable` taint - then `kubectl drain` with
`--ignore-daemonsets` to evict the rest, since DaemonSet pods cannot be evicted
meaningfully. Do the work, then `kubectl uncordon`. PodDisruptionBudgets make
drain respect availability by blocking evictions that would breach the budget.
Stateful workloads need extra care because their volumes must reattach on the
new node.
</details>

<details>
<summary><b>8. What is a PodDisruptionBudget?</b></summary>

A constraint on *voluntary* disruptions - drains, node upgrades, cluster
autoscaler scale-down - expressed as `minAvailable` or `maxUnavailable`. It
makes `kubectl drain` block rather than take a service below the threshold. It
does not protect against involuntary disruption such as a node crashing or an
OOM kill.
</details>

<details>
<summary><b>9. What is gang scheduling and does Kubernetes do it?</b></summary>

Gang scheduling means a group of pods is scheduled all-or-nothing - essential
for distributed training and MPI jobs where partial placement deadlocks while
holding resources. The default kube-scheduler places pods one at a time and does
not support it. You add it with a scheduler plugin or a batch scheduler:
Volcano, Apache YuniKorn, or the Kueue project. Expect this one at senior level.
</details>

<details>
<summary><b>10. A pod is Pending. What is your checklist?</b></summary>

`kubectl describe pod` and read the FailedScheduling message, which counts nodes
per rejection reason. Then work through: insufficient CPU or memory against
requests, an unmatched nodeSelector or required affinity, an untolerated taint,
an unbound PVC, a node-count limit from required anti-affinity, a ResourceQuota,
or simply no Ready nodes. The message usually names which one.
</details>

---

## Cheat card

```bash
# labels
kubectl get nodes --show-labels
kubectl label node devops-worker disktype=ssd
kubectl label node devops-worker disktype-               # remove

# taints
kubectl taint nodes devops-worker key=value:NoSchedule
kubectl taint nodes devops-worker key=value:NoSchedule-  # remove (trailing dash)
kubectl describe node devops-worker | grep -A3 Taints

# maintenance
kubectl cordon   devops-worker
kubectl drain    devops-worker --ignore-daemonsets --delete-emptydir-data
kubectl uncordon devops-worker

# where did things land?
kubectl get pods -A -o wide
kubectl get pods -n devboard -o wide | awk 'NR>1{print $7}' | sort | uniq -c

# why is it Pending?
kubectl describe pod <pod> -n devboard | grep -A5 Events

kubectl get daemonsets -A
kubectl get pdb -n devboard
```

| Want | Use |
|---|---|
| pods only on GPU nodes | `nodeSelector` or required node affinity |
| prefer a zone, do not require it | preferred node affinity |
| replicas on different nodes | topology spread (or preferred anti-affinity) |
| reserve a node for one workload | taint + toleration + affinity |
| one pod per node | DaemonSet |
| evict pods from a node now | `NoExecute` taint, or `drain` |
| protect availability during drain | PodDisruptionBudget |

---

**Next: [Day 19 - RBAC](../day-19-rbac/)**
