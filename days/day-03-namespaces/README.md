# Day 03 — Namespaces

**Time:** 45-60 minutes
**Prerequisites:** Day 02

Short day, high payoff. Namespaces are simple, and forgetting them is the single
most common source of "where did my pod go?" for the rest of your career.

Today you also create `devboard`, the namespace every remaining day uses.

---

## Part 1 - Concepts

### 3.1 What a namespace is

A **namespace** is a virtual cluster inside your cluster: a scope for names.

The WhatsApp-group analogy holds up well. One phone, many groups. The same
message in different groups goes to different people. Two groups can both have a
member called "Rahul" and nobody is confused.

In Kubernetes: one cluster, many namespaces. A Deployment called `frontend` can
exist in `dev`, `staging` and `prod` simultaneously without collision.

```
+========================= CLUSTER =========================+
|                                                            |
|  namespace: dev          namespace: prod                   |
|  +-------------------+   +-------------------+             |
|  | deploy/frontend   |   | deploy/frontend   |  <- same    |
|  | svc/backend       |   | svc/backend       |     names,  |
|  | secret/db-creds   |   | secret/db-creds   |     no      |
|  +-------------------+   +-------------------+     clash   |
|                                                            |
|  namespace: kube-system      namespace: default            |
|  +----------------------+    +-------------------+         |
|  | coredns, kube-proxy  |    | (where things land |         |
|  | metrics-server       |    |  when you forget)  |         |
|  +----------------------+    +-------------------+         |
+============================================================+
```

### 3.2 What namespaces give you

1. **Name scoping** - the same object name in different namespaces.
2. **RBAC boundary** - "the intern can read `dev`, nothing in `prod`" is a
   natural namespace-scoped Role (Day 19).
3. **Resource quotas** - cap total CPU, memory or object counts per namespace.
4. **A blast radius for cleanup** - `kubectl delete namespace dev` removes
   everything in it, in one command.
5. **DNS scoping** - a Service is reachable as `<svc>` inside its own namespace,
   and `<svc>.<namespace>.svc.cluster.local` from anywhere (Day 06).

### 3.3 What namespaces are NOT

Be precise about this; interviewers probe it.

- **Not a security boundary by default.** Pods in `dev` can reach pods in `prod`
  over the network unless you add a NetworkPolicy. Namespaces scope the *API*,
  not the *network*.
- **Not resource isolation by default.** A pod in `dev` with no limits can eat
  the whole node and starve `prod`. You need ResourceQuota and LimitRange.
- **Not a cluster.** Nodes, storage and the control plane are shared.

For hard multi-tenancy you want separate clusters, or namespaces plus
NetworkPolicies plus quotas plus RBAC plus PodSecurity admission.

### 3.4 The four namespaces every cluster is born with

```bash
kubectl get namespaces
```

| Namespace | Purpose |
|---|---|
| `default` | Where objects go when you do not specify one. Do not use it for real work. |
| `kube-system` | Control-plane and add-on components. Do not put your apps here. |
| `kube-public` | World-readable, even unauthenticated. Holds cluster info. Rarely used. |
| `kube-node-lease` | One Lease object per node for fast heartbeats. Never touch it. |

### 3.5 Namespaced vs cluster-scoped objects

This distinction matters and is easy to get wrong.

**Namespaced** (live inside a namespace): Pod, Deployment, ReplicaSet,
StatefulSet, DaemonSet, Service, ConfigMap, Secret, PersistentVolumeClaim,
ServiceAccount, Role, RoleBinding, Ingress, Job, HPA.

**Cluster-scoped** (exist once, globally): Node, Namespace itself,
PersistentVolume, StorageClass, ClusterRole, ClusterRoleBinding,
CustomResourceDefinition, IngressClass.

Two that catch people out constantly:

- **PersistentVolume is cluster-scoped, PersistentVolumeClaim is namespaced.**
  A PV is a piece of storage in the cluster; a claim on it belongs to a
  namespace. Writing `namespace:` on a PV is a silent no-op. (Day 14.)
- **Role is namespaced, ClusterRole is not.** (Day 19.)

Ask the cluster rather than memorising:

```bash
kubectl api-resources --namespaced=true  | head -25
kubectl api-resources --namespaced=false
```

---

## Part 2 - Hands-on lab

### Step 1: See what exists

```bash
kubectl get namespaces
kubectl get ns                      # short name

kubectl get pods                    # default ns: probably empty
kubectl get pods -n kube-system     # the control plane
kubectl get pods -A                 # every namespace at once
kubectl get all -A | head -30
```

`-A` (or `--all-namespaces`) is worth building a habit around when hunting for
something you cannot find.

### Step 2: Create the course namespace

Two ways. The imperative one:

```bash
kubectl create namespace scratch-demo
```

And the declarative one, which is what you commit. Create `namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: devboard
  labels:
    project: devboard
    environment: learning
```

```bash
kubectl apply -f namespace.yaml
kubectl get ns devboard
kubectl describe ns devboard
```

Note there is no `spec` worth writing - a namespace is essentially just a name
plus labels. That is the whole object.

### Step 3: Put something in it, and prove the scoping

```bash
kubectl apply -f ../day-02-kubectl-and-your-first-pod/solution/pod.yaml -n devboard

kubectl get pods                    # nothing - you are looking at `default`
kubectl get pods -n devboard        # there it is
kubectl get pods -A | grep nginx    # found, with its namespace shown
```

**This is the lesson of the day.** The pod was never missing. You were looking
in the wrong namespace. When a resource "disappears", check the namespace before
anything else.

Now create the *same name* in another namespace to prove names are scoped:

```bash
kubectl apply -f ../day-02-kubectl-and-your-first-pod/solution/pod.yaml -n scratch-demo
kubectl get pods -A | grep nginx      # two pods, both called nginx
```

### Step 4: Put the namespace in the manifest

Better than remembering `-n` every time. Create `pod-with-ns.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-explicit
  namespace: devboard        # <- lives here regardless of your current context
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
```

```bash
kubectl apply -f pod-with-ns.yaml       # no -n flag needed
kubectl get pods -n devboard
```

**Trade-off, and it is a real one.** Hardcoding `namespace:` makes the manifest
unambiguous but stops you deploying the same file to `dev` and `prod`. Common
practice: leave `namespace` out of application manifests and let the deployment
tooling (Kustomize, Helm, or `-n`) set it. For this course we mostly use `-n`.

If they conflict, the file wins:

```bash
kubectl apply -f pod-with-ns.yaml -n default
# Error: the namespace from the provided object "devboard" does not match
# the namespace "default"
```

### Step 5: Stop typing -n devboard

```bash
kubectl config set-context --current --namespace=devboard
kubectl config view --minify | grep namespace
kubectl get pods                        # now defaults to devboard
```

Switch back when you need to:

```bash
kubectl config set-context --current --namespace=default
```

The course keeps writing `-n devboard` explicitly so every command works no
matter what your default is. In real work, being explicit before a destructive
command is a habit worth having.

### Step 6: ResourceQuota - cap a namespace

Without a quota, one namespace can consume the whole cluster. Create
`resource-quota.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: devboard-quota
  namespace: devboard
spec:
  hard:
    requests.cpu: "2"           # sum of all container CPU requests
    requests.memory: 2Gi        # sum of all container memory requests
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"                  # object count caps work too
    services: "10"
    persistentvolumeclaims: "5"
    count/deployments.apps: "10"
```

```bash
kubectl apply -f resource-quota.yaml
kubectl describe resourcequota devboard-quota -n devboard
```

```
Name:                   devboard-quota
Resource                Used   Hard
--------                ----   ----
limits.cpu              0      4
pods                    2      20
requests.memory         0      2Gi
```

**The catch that surprises everyone:** once a quota sets `requests.cpu` or
`requests.memory`, every new pod in that namespace **must** declare those
requests, or it is rejected outright:

```
Error from server (Forbidden): failed quota: devboard-quota:
must specify limits.cpu for: nginx; requests.cpu for: nginx
```

Day 16 covers requests and limits properly. For now, delete the quota so it does
not block the next few days:

```bash
kubectl delete -f resource-quota.yaml
```

(If you want to keep it, add a **LimitRange** that supplies defaults - see
`solution/limit-range.yaml`.)

### Step 7: Clean up

```bash
kubectl delete namespace scratch-demo     # deletes EVERYTHING inside it
kubectl delete pod nginx nginx-explicit -n devboard
kubectl get ns
```

Deleting a namespace is recursive and irreversible. In production this is one of
the most dangerous commands there is; the terminating phase can also hang for a
long time if any object in it has a finalizer.

Keep `devboard` - every remaining day uses it.

---

## Validate

```bash
kubectl apply -f solution/namespace.yaml
kubectl get ns devboard -o jsonpath='{.status.phase}{"\n"}'   # Active
kubectl api-resources --namespaced=false | grep -i persistentvolume
# PersistentVolume appears (cluster-scoped); PersistentVolumeClaim does not
```

You are ready for Day 04 when you can answer:

1. Name three cluster-scoped kinds without looking.
2. Why is a PersistentVolume not namespaced, but a PVC is?
3. Are namespaces a security boundary? Justify the answer.
4. What breaks when you add a ResourceQuota with `requests.cpu` to a namespace
   whose pods have no resource requests?

---

## Break it

**A. The classic disappearing pod.**

```bash
kubectl run findme --image=nginx:alpine -n devboard
kubectl get pods                 # if your default is `default`: nothing
kubectl get pods -A | grep findme
kubectl delete pod findme -n devboard
```

**B. Delete a namespace with work in it.**

```bash
kubectl create ns doomed
kubectl run a --image=nginx:alpine -n doomed
kubectl run b --image=nginx:alpine -n doomed
kubectl get pods -n doomed

kubectl delete ns doomed
kubectl get pods -n doomed       # gone, both of them
```

One command, everything gone, no confirmation prompt. Sit with that for a
second.

**C. Hit a quota.**

```bash
kubectl apply -f solution/resource-quota.yaml
kubectl run quota-test --image=nginx:alpine -n devboard
# Forbidden: failed quota ... must specify limits.cpu, requests.cpu
```

Now satisfy it:

```bash
kubectl run quota-test --image=nginx:alpine -n devboard \
  --overrides='{"spec":{"containers":[{"name":"quota-test","image":"nginx:alpine","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}'

kubectl describe resourcequota devboard-quota -n devboard   # Used goes up
kubectl delete pod quota-test -n devboard
kubectl delete -f solution/resource-quota.yaml
```

**D. A namespace stuck Terminating.**

You will meet this eventually. A namespace sits in `Terminating` forever because
some object in it has a **finalizer** that no controller is left to clear (very
common after uninstalling an operator whose CRDs are gone).

```bash
kubectl get ns <stuck-ns> -o jsonpath='{.spec.finalizers}'
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 kubectl get --show-kind --ignore-not-found -n <stuck-ns>
```

That second command lists every remaining object in the namespace, which is what
you actually want to know. Force-removing finalizers is possible but is a last
resort: it orphans real resources.

---

## Interview questions

<details>
<summary><b>1. What is a namespace and what problem does it solve?</b></summary>

A virtual cluster: a scope for object names within one physical cluster. It lets
teams and environments share a cluster without name collisions, gives RBAC a
natural boundary, allows per-team resource quotas, and makes bulk cleanup a
single delete.
</details>

<details>
<summary><b>2. Are namespaces a security boundary?</b></summary>

Not on their own. They scope the API, not the network: by default a pod in one
namespace can open a TCP connection to a pod in another. Making a namespace a
real boundary requires NetworkPolicies for traffic, RBAC for API access,
ResourceQuota and LimitRange for resources, and PodSecurity admission for
workload privileges. For hard multi-tenancy, separate clusters.
</details>

<details>
<summary><b>3. Name resources that are NOT namespaced.</b></summary>

Node, Namespace, PersistentVolume, StorageClass, ClusterRole,
ClusterRoleBinding, CustomResourceDefinition, IngressClass, and
ValidatingWebhookConfiguration. `kubectl api-resources --namespaced=false` is
the authoritative list for a given cluster.
</details>

<details>
<summary><b>4. In which namespace do you create a PersistentVolume?</b></summary>

None - it is cluster-scoped. Adding `metadata.namespace` to a PV is silently
ignored. The PersistentVolumeClaim that binds to it *is* namespaced, and a pod
can only use a PVC from its own namespace.
</details>

<details>
<summary><b>5. How does a pod in namespace A reach a Service in namespace B?</b></summary>

By fully qualified DNS name: `<service>.<namespace>.svc.cluster.local`, or the
shorter `<service>.<namespace>`. The bare `<service>` form only resolves within
the same namespace, because the pod's `/etc/resolv.conf` search path lists its
own namespace first.
</details>

<details>
<summary><b>6. What does deleting a namespace do?</b></summary>

Deletes every namespaced object in it, recursively and without confirmation. The
namespace enters Terminating while controllers clean up. It can hang
indefinitely if an object holds a finalizer nothing will clear.
</details>

<details>
<summary><b>7. Difference between ResourceQuota and LimitRange?</b></summary>

ResourceQuota caps the *aggregate* for a namespace: total CPU requests, total
memory, or object counts. LimitRange constrains *individual* objects: default
requests and limits when a pod does not specify them, plus min and max values.
They complement each other - a quota that requires requests is unusable in
practice without a LimitRange supplying defaults.
</details>

<details>
<summary><b>8. How would you structure namespaces for a company?</b></summary>

Common patterns are per-environment (`dev`, `staging`, `prod` - often separate
clusters for prod), per-team (`team-payments`, `team-search`), or a combination.
Whatever you choose, keep application workloads out of `default` and
`kube-system`, apply quotas per namespace, and drive RBAC from the same
structure.
</details>

---

## Cheat card

```bash
kubectl get ns
kubectl create ns dev
kubectl apply -f namespace.yaml
kubectl delete ns dev                  # deletes everything inside

kubectl get pods -n devboard
kubectl get pods -A                    # all namespaces
kubectl get all -n devboard

kubectl config set-context --current --namespace=devboard
kubectl config view --minify | grep namespace

kubectl api-resources --namespaced=true
kubectl api-resources --namespaced=false

kubectl describe resourcequota devboard-quota -n devboard
```

---

**Next: [Day 04 - Labels, ReplicaSets and Deployments](../day-04-labels-replicasets-deployments/)**
