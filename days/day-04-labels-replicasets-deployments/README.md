# Day 04 — Labels, ReplicaSets & Deployments

**Time:** 75-90 minutes
**Prerequisites:** Days 02-03

This is the most important day in week 1. Labels and selectors are the mechanism
that connects *every* object in Kubernetes to every other object. Once you see
it, Services, Deployments, NetworkPolicies and affinity rules all become the
same idea wearing different hats.

---

## Part 1 - Concepts

### 4.1 Labels: arbitrary tags with a real job

A **label** is a key/value pair in `metadata.labels`:

```yaml
metadata:
  labels:
    app: devboard-frontend
    tier: web
    environment: production
    version: "2.1"
```

They are not decoration. **Nothing in Kubernetes references another object by
name.** A Service does not list the pods it serves; a Deployment does not list
the pods it owns. They all use a **label selector** and ask "give me everything
carrying these labels". This is called *loose coupling*, and it is why you can
add a pod and have a Service pick it up with no configuration change anywhere.

```
        Service (selector: app=frontend)
                     |
        "who has app=frontend?"
          /          |          \
     [Pod A]     [Pod B]     [Pod C]        <- all labelled app=frontend
   app=frontend  app=frontend  app=frontend
```

Add Pod D with `app=frontend` and the Service starts sending traffic to it
immediately. Remove the label from Pod A and traffic stops. No restarts, no
config reload.

**Labels vs annotations:** labels are for *selection* and must be short and
valid (63 chars, alphanumeric plus `-_.`). Annotations are for arbitrary
metadata a human or tool reads - build IDs, git SHAs, change-cause, contact
email. You cannot select on annotations.

**Recommended label set** (the community convention - use it, tooling expects it):

```yaml
labels:
  app.kubernetes.io/name: devboard
  app.kubernetes.io/component: frontend
  app.kubernetes.io/instance: devboard-prod
  app.kubernetes.io/version: "2.1"
  app.kubernetes.io/managed-by: kubectl
```

For a learning repo, short labels like `app: devboard-frontend` are fine and
this course uses them for readability.

### 4.2 Selectors: two flavours

**Equality-based** (what Services use):

```yaml
selector:
  app: frontend
  tier: web              # AND, not OR: both must match
```

**Set-based** (what Deployments, ReplicaSets and DaemonSets use, via
`matchLabels` / `matchExpressions`):

```yaml
selector:
  matchLabels:
    app: frontend
  matchExpressions:
    - key: environment
      operator: In            # In, NotIn, Exists, DoesNotExist
      values: [production, staging]
```

On the command line:

```bash
kubectl get pods -l app=frontend
kubectl get pods -l 'app in (frontend,backend)'
kubectl get pods -l app=frontend,tier=web       # AND
kubectl get pods -l '!tier'                     # pods with NO tier label
kubectl get pods -l app!=frontend
kubectl get pods --show-labels
```

### 4.3 The ownership chain

```
   Deployment  "I want 3 replicas of image v2, rolled out gradually"
       |  owns (and creates a new one per version)
       v
   ReplicaSet  "I make sure exactly 3 pods matching my selector exist"
       |  owns
       v
   Pod  Pod  Pod
```

- A **ReplicaSet** does exactly one thing: keep N pods matching its selector
  alive. It has no concept of versions or rollouts.
- A **Deployment** manages ReplicaSets. When you change the pod template, it
  creates a *new* ReplicaSet and gradually shifts replicas from old to new -
  that is a rolling update (Day 05). It keeps the old ReplicaSets around at zero
  replicas so you can roll back.

**You never create a ReplicaSet directly.** Always a Deployment. The only reason
to know ReplicaSets exist is to read `kubectl get rs` output while debugging a
rollout, and to answer the interview question.

How does a controller know which pods are "its own"? Two mechanisms:

1. The **selector** finds candidate pods.
2. Each pod carries an **ownerReference** in its metadata pointing at the
   ReplicaSet UID. This is what makes cascading delete work.

```bash
kubectl get pod <name> -o jsonpath='{.metadata.ownerReferences}' | jq
```

### 4.4 The Deployment manifest, field by field

```yaml
apiVersion: apps/v1        # NOT v1 - Deployment lives in the apps group
kind: Deployment
metadata:
  name: devboard-frontend
  namespace: devboard
  labels:
    app: devboard-frontend      # labels ON the Deployment object itself
spec:
  replicas: 3                   # desired pod count
  selector:
    matchLabels:
      app: devboard-frontend    # which pods this Deployment owns
  template:                     # <- everything below is a Pod template
    metadata:
      labels:
        app: devboard-frontend  # labels PUT ON each created pod
    spec:
      containers:
        - name: frontend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
```

**The rule that trips up everyone:**
`spec.selector.matchLabels` **must match** `spec.template.metadata.labels`.
If they do not, the API server rejects the Deployment:

```
selector does not match template labels
```

Think about why: the ReplicaSet would create pods it does not recognise as its
own, then create more, forever. Kubernetes refuses.

Second rule: **`spec.selector` is immutable after creation.** You can change
replicas, image, resources, probes - but not the selector. To change it you
delete and recreate the Deployment.

Note the three separate places labels appear, and that they are different
things:
- `metadata.labels` - labels on the Deployment object (for *you* to select
  Deployments)
- `spec.selector.matchLabels` - which pods this Deployment owns
- `spec.template.metadata.labels` - labels stamped onto every created pod

---

## Part 2 - Hands-on lab

```bash
mkdir -p scratch/day04 && cd scratch/day04
export NS=devboard          # PowerShell: $env:NS="devboard"
```

### Step 1: Prove why bare pods are not enough

```bash
kubectl run lonely --image=nginx:1.27-alpine -n devboard
kubectl get pods -n devboard
kubectl delete pod lonely -n devboard
kubectl get pods -n devboard          # gone, and it stays gone
```

Nothing brings it back. A bare Pod has no controller watching it. That is the
entire argument for Deployments.

### Step 2: Labels on their own

```bash
kubectl run p1 --image=nginx:alpine -n devboard -l app=web,tier=frontend
kubectl run p2 --image=nginx:alpine -n devboard -l app=web,tier=backend
kubectl run p3 --image=nginx:alpine -n devboard -l app=db,tier=backend

kubectl get pods -n devboard --show-labels

kubectl get pods -n devboard -l app=web
kubectl get pods -n devboard -l tier=backend
kubectl get pods -n devboard -l app=web,tier=backend       # AND -> just p2
kubectl get pods -n devboard -l 'tier in (frontend,backend)'
kubectl get pods -n devboard -l '!version'                 # none have `version`
```

Add and remove labels on a live object:

```bash
kubectl label pod p1 version=v1 -n devboard
kubectl get pods -n devboard --show-labels

kubectl label pod p1 version=v2 -n devboard --overwrite
kubectl label pod p1 version- -n devboard          # trailing dash = remove
```

Clean up:

```bash
kubectl delete pod p1 p2 p3 -n devboard
```

### Step 3: A ReplicaSet, once, so you know what it does

Create `replicaset.yaml`:

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: demo-rs
  namespace: devboard
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-rs
  template:
    metadata:
      labels:
        app: demo-rs
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
```

```bash
kubectl apply -f replicaset.yaml
kubectl get rs -n devboard
kubectl get pods -n devboard
```

Pod names are `demo-rs-<random>`. Now the self-healing demo:

```bash
kubectl delete pod -n devboard -l app=demo-rs --wait=false
kubectl get pods -n devboard -w        # replacements appear immediately. Ctrl-C
```

Now do the thing that makes ownership click. Take a pod *away* from its
ReplicaSet by changing its label:

```bash
POD=$(kubectl get pods -n devboard -l app=demo-rs -o name | head -1)
kubectl label $POD app=orphan -n devboard --overwrite

kubectl get pods -n devboard --show-labels
kubectl get rs -n devboard
```

You now have **four** pods: three owned by the ReplicaSet plus one orphan. The
ReplicaSet counted its pods, found two matching its selector, and created a
third. It never "knew" it lost one - it only ever counts label matches.

That orphan is also a real debugging technique: relabel a misbehaving pod to
pull it out of a Service and out of its controller, keep it alive for
inspection, and let a healthy replacement take its place.

```bash
kubectl delete pod -n devboard -l app=orphan
kubectl delete -f replicaset.yaml
```

### Step 4: Now the Deployment

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: devboard-frontend
  namespace: devboard
  labels:
    app: devboard-frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: devboard-frontend
  template:
    metadata:
      labels:
        app: devboard-frontend
        tier: web
    spec:
      containers:
        - name: frontend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              name: http
```

```bash
kubectl apply -f deployment.yaml
kubectl get deploy,rs,pods -n devboard
```

```
NAME                                READY   UP-TO-DATE   AVAILABLE
deployment.apps/devboard-frontend   3/3     3            3

NAME                                          DESIRED   CURRENT   READY
replicaset.apps/devboard-frontend-7d9f8c4b5   3         3         3

NAME                                    READY   STATUS
pod/devboard-frontend-7d9f8c4b5-2xk9p   1/1     Running
pod/devboard-frontend-7d9f8c4b5-8mn4t   1/1     Running
pod/devboard-frontend-7d9f8c4b5-q7wzl   1/1     Running
```

Read the names: `devboard-frontend` (Deployment) → `-7d9f8c4b5` (ReplicaSet, the
hash is of the pod template) → `-2xk9p` (Pod, random suffix). The whole
ownership chain is visible in the names.

The Deployment columns mean:

| Column | Meaning |
|---|---|
| `READY` | ready pods / desired pods |
| `UP-TO-DATE` | pods running the *current* template |
| `AVAILABLE` | ready for at least `minReadySeconds` |

### Step 5: Self-healing, for real

```bash
kubectl get pods -n devboard -w      # in one terminal
```

In a second terminal:

```bash
kubectl delete pod -n devboard -l app=devboard-frontend --wait=false
```

Watch the first terminal: three pods Terminating, three new ones Pending →
ContainerCreating → Running, within a couple of seconds. You never asked for
this. The ReplicaSet controller noticed `actual != desired` and closed the gap.

Now simulate a node failure:

```bash
kubectl get pods -n devboard -o wide      # note which node each pod is on
docker stop devops-worker2
kubectl get pods -n devboard -o wide -w   # after ~5 min, pods on that node
                                          # are evicted and rescheduled
docker start devops-worker2
```

The five-minute delay is `--pod-eviction-timeout`. Kubernetes waits before
declaring a node truly dead, because a brief network blip should not cause mass
rescheduling.

### Step 6: Scaling

Three ways, from worst to best practice:

```bash
# 1. imperative - fast, but nothing is recorded anywhere
kubectl scale deployment devboard-frontend --replicas=5 -n devboard
kubectl get pods -n devboard

# 2. patch - scriptable
kubectl patch deployment devboard-frontend -n devboard \
  -p '{"spec":{"replicas":2}}'

# 3. declarative - edit replicas in deployment.yaml, then:
kubectl apply -f deployment.yaml
```

Scaling to zero is legal and useful (stop a workload without deleting it):

```bash
kubectl scale deployment devboard-frontend --replicas=0 -n devboard
kubectl get deploy,pods -n devboard
kubectl scale deployment devboard-frontend --replicas=3 -n devboard
```

### Step 7: See the reconciliation loop from the API side

```bash
kubectl get events -n devboard --sort-by=.lastTimestamp | tail -20
```

```
Normal  ScalingReplicaSet  deployment-controller  Scaled up replica set devboard-frontend-7d9f8c4b5 to 3
Normal  SuccessfulCreate   replicaset-controller  Created pod: devboard-frontend-7d9f8c4b5-2xk9p
Normal  Scheduled          default-scheduler      Successfully assigned devboard/... to devops-worker
Normal  Pulled             kubelet                Container image already present on machine
Normal  Started            kubelet                Started container frontend
```

Deployment controller → ReplicaSet controller → scheduler → kubelet. Day 01's
architecture, printed by your own cluster.

### Step 8: Deployment vs ReplicaSet, demonstrated

Change the image in `deployment.yaml` to `nginx:1.26-alpine` and apply:

```bash
kubectl apply -f deployment.yaml
kubectl get rs -n devboard
```

```
NAME                          DESIRED   CURRENT   READY
devboard-frontend-6c8b9d7f4   3         3         3      <- new template
devboard-frontend-7d9f8c4b5   0         0         0      <- old, kept at zero
```

**Two ReplicaSets.** The old one is retained at zero replicas so a rollback is
instant. This is precisely what a ReplicaSet cannot do on its own, and precisely
why you always use a Deployment. Day 05 is all about this.

---

## Validate

```bash
kubectl apply -f solution/deployment.yaml
kubectl rollout status deployment/devboard-frontend -n devboard --timeout=90s

kubectl get deploy devboard-frontend -n devboard \
  -o jsonpath='{.status.readyReplicas}{"\n"}'            # 3

kubectl delete pod -n devboard -l app=devboard-frontend --wait=false
sleep 15
kubectl get pods -n devboard -l app=devboard-frontend --no-headers | wc -l   # 3
```

Ready for Day 05 when you can:

1. Explain in one sentence how a Service finds its pods.
2. Say what happens if `selector.matchLabels` and `template.metadata.labels`
   differ.
3. Explain why changing a pod's label can make its ReplicaSet create another pod.
4. Say why old ReplicaSets are kept at zero replicas.

---

## Break it

**A. Mismatched selector and template labels.**

In `deployment.yaml`, change `template.metadata.labels.app` to `oops` and apply:

```
The Deployment "devboard-frontend" is invalid:
spec.template.metadata.labels: Invalid value: map[string]string{"app":"oops"}:
`selector` does not match template `labels`
```

**B. Try to change the selector of a live Deployment.**

```
field is immutable
```

The fix is to delete and recreate. In production that means downtime, which is
why selectors are worth getting right the first time. Use stable labels
(`app: frontend`), not volatile ones (`version: 2.1`), in selectors.

**C. Two Deployments fighting over the same pods.**

```bash
sed 's/devboard-frontend/rival/' solution/deployment.yaml \
  | sed 's/app: rival/app: devboard-frontend/' \
  | kubectl apply -f -

kubectl get pods -n devboard -l app=devboard-frontend
kubectl get rs -n devboard
```

Two controllers now select the same label set. They each count pods and fight
over the total. This is a real production incident pattern - always give each
workload a genuinely unique selector.

```bash
kubectl delete deployment rival -n devboard
```

**D. Orphan a pod and watch a replacement appear.**

Already done in Step 3 - do it again with the Deployment and confirm the
behaviour is identical. The Deployment does not track pods by name either.

---

## Interview questions

<details>
<summary><b>1. Deployment vs ReplicaSet vs Pod?</b></summary>

A Pod is the smallest schedulable unit and has no self-healing on its own. A
ReplicaSet keeps exactly N pods matching its selector alive, but knows nothing
about versions. A Deployment manages ReplicaSets: changing the pod template
creates a new ReplicaSet and shifts replicas across gradually, which gives you
rolling updates, rollback history and pause/resume. You create Deployments;
ReplicaSets are an implementation detail.
</details>

<details>
<summary><b>2. How does a Service know which pods to send traffic to?</b></summary>

By label selector, not by name. The endpoints controller continuously lists pods
matching the Service selector in the same namespace, filters to those that are
Ready, and writes their IPs into an EndpointSlice. Adding a pod with matching
labels adds it to the pool automatically.
</details>

<details>
<summary><b>3. What happens if selector and template labels do not match?</b></summary>

The API server rejects the object at creation with "selector does not match
template labels". Logically it would create pods it could not recognise as its
own and loop forever creating more.
</details>

<details>
<summary><b>4. Can you change a Deployment selector after creation?</b></summary>

No, it is immutable. You must delete and recreate the Deployment, which means
planning for downtime or running a parallel Deployment and shifting a Service
across. This is why selectors should use stable identity labels, never version
or environment labels that change.
</details>

<details>
<summary><b>5. Labels vs annotations?</b></summary>

Labels are for identification and selection: short, validated, indexed,
queryable with selectors. Annotations are arbitrary non-identifying metadata for
humans and tools - git SHA, change-cause, ingress controller configuration - can
hold large values, and cannot be selected on.
</details>

<details>
<summary><b>6. A pod belonging to a ReplicaSet gets its label changed. What happens?</b></summary>

The ReplicaSet no longer selects it, so its count drops below desired and it
creates a replacement. The relabelled pod is orphaned - it keeps running, keeps
its ownerReference, but nothing manages it and no Service selects it. This is
deliberately used to quarantine a bad pod for debugging while a healthy one
takes over.
</details>

<details>
<summary><b>7. Why does a Deployment keep old ReplicaSets around?</b></summary>

For rollback. Each old ReplicaSet is scaled to zero but retains its pod
template, so `kubectl rollout undo` simply scales the previous one back up.
`spec.revisionHistoryLimit` controls how many are kept; the default is 10.
</details>

<details>
<summary><b>8. How do you scale a Deployment, and which way is best?</b></summary>

`kubectl scale`, `kubectl patch`, editing the manifest and re-applying, or an
HPA. In a GitOps setup, edit the manifest - imperative scaling drifts from git
and gets reverted on the next sync. If an HPA manages the Deployment, do not set
replicas in the manifest at all, or the two fight.
</details>

<details>
<summary><b>9. What is an ownerReference and why does it matter?</b></summary>

A metadata field pointing at the parent object's kind, name and UID. It drives
garbage collection: deleting a Deployment cascades to its ReplicaSets and then
to their pods. `kubectl delete deployment x --cascade=orphan` deletes the
Deployment but leaves pods running - occasionally useful during a migration.
</details>

<details>
<summary><b>10. Pods are stuck Pending after you scale to 50 replicas. Why?</b></summary>

Almost certainly insufficient cluster capacity: the sum of requests exceeds
allocatable CPU or memory on every node. `kubectl describe pod` shows
"0/3 nodes are available: 3 Insufficient cpu". Other candidates are a
ResourceQuota being hit, a nodeSelector or affinity nothing satisfies, or taints
with no matching toleration. Fix by adding nodes, lowering requests, or enabling
the cluster autoscaler.
</details>

---

## Cheat card

```bash
# labels
kubectl get pods --show-labels
kubectl get pods -l app=frontend
kubectl get pods -l 'env in (dev,staging)'
kubectl get pods -l '!version'
kubectl label pod x tier=web
kubectl label pod x tier=api --overwrite
kubectl label pod x tier-                 # remove

# deployments
kubectl apply -f deployment.yaml
kubectl get deploy,rs,pods
kubectl scale deployment web --replicas=5
kubectl describe deployment web
kubectl get deploy web -o yaml

# see the chain
kubectl get pod <pod> -o jsonpath='{.metadata.ownerReferences[0].name}'
kubectl get rs -n devboard
kubectl get events -n devboard --sort-by=.lastTimestamp
```

**The one rule to carry forward:** in Kubernetes, objects find each other by
**labels**, never by name.

---

**Next: [Day 05 - Rolling updates and rollbacks](../day-05-rolling-updates-and-rollbacks/)**
