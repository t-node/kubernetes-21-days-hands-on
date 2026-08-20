# Day 01 — Kubernetes Architecture & Your First Cluster

**Time:** 60-75 minutes
**Prerequisites:** [SETUP.md](../../SETUP.md) complete (Docker, kind, kubectl installed)

By the end of today you will have a real 3-node Kubernetes cluster running on
your laptop, and you will be able to name every component inside it and say what
it does, without looking it up.

---

## Part 1 - Concepts

### 1.1 The problem Kubernetes actually solves

You already know Docker. You can run a container. You can even run three of them
with `docker compose`: a frontend, a backend, a database.

Now put that on a real server and answer these:

- The backend container crashes at 3 a.m. **Who restarts it?**
- Traffic goes 10x during a sale. **Who starts more containers?**
- Traffic drops back down. **Who stops them so you stop paying?**
- One server is full. **Who decides which server the next container goes on?**
- You deploy v2 and it is broken. **Who rolls back?**
- A whole server dies. **Who moves its containers somewhere else?**

With Docker alone, the answer to every one of those is *you*, manually, at
3 a.m. Kubernetes is the system that answers all six automatically.

**Definition to memorise:**

> Kubernetes is a **container orchestration platform**: it schedules containers
> onto a pool of machines, keeps them running in the state you declared, and
> handles scaling, networking, storage and rollouts for you.

Note the word **container**, not **Docker**. This is an interview trap:

> **Q: Which container runtime does Kubernetes use?**
> Most people say "Docker". That has been wrong since Kubernetes 1.24, when the
> dockershim was removed. Kubernetes talks to any runtime implementing the
> **CRI** (Container Runtime Interface): **containerd** (the default, and what
> kind uses), **CRI-O**, and others. Docker Engine itself now sits on top of
> containerd. Kubernetes orchestrates *containers*, not *Docker*.

### 1.2 Declarative, not imperative

This is the mental shift that makes everything else make sense.

| Imperative (Docker) | Declarative (Kubernetes) |
|---|---|
| "Run this container" | "I want 3 replicas of this to exist" |
| You describe the **steps** | You describe the **desired state** |
| If one dies, it stays dead | A controller notices and fixes it |

Kubernetes runs a permanent **reconciliation loop**:

```
loop forever:
    actual  = what is running right now
    desired = what the YAML says should be running
    if actual != desired:
        take action to close the gap
```

That is why `kubectl apply` is safe to run a hundred times, and why deleting a
Pod that belongs to a Deployment just makes a new one appear. You are not giving
orders; you are editing a target that a controller is chasing.

### 1.3 Cluster = control plane + data plane

A **cluster** is a group of machines. The machines are called **nodes**
(also seen as servers, instances, workers, minions - all synonyms).

Nodes split into two roles:

```
+========================== KUBERNETES CLUSTER ===========================+
|                                                                         |
|  CONTROL PLANE   (the brain - decides)                                  |
|  +-------------------------------------------------------------------+  |
|  |   kube-apiserver      the ONLY door into the cluster (HTTPS 6443)  |  |
|  |        |                                                          |  |
|  |        +-- etcd       key-value store: the memory of the cluster   |  |
|  |        +-- scheduler  picks WHICH node an unscheduled Pod runs on  |  |
|  |        +-- controller-manager   runs the reconciliation loops      |  |
|  |        +-- cloud-controller-manager   (cloud clusters only)        |  |
|  +-------------------------------------------------------------------+  |
|                                  |                                      |
|  DATA PLANE   (the muscle - does)|                                      |
|  +-------------------------------v-----------------------------------+  |
|  |  worker node 1        worker node 2        worker node 3          |  |
|  |  +------------+       +------------+       +------------+         |  |
|  |  | kubelet    |       | kubelet    |       | kubelet    |         |  |
|  |  | kube-proxy |       | kube-proxy |       | kube-proxy |         |  |
|  |  | containerd |       | containerd |       | containerd |         |  |
|  |  |            |       |            |       |            |         |  |
|  |  | [Pod][Pod] |       | [Pod][Pod] |       | [Pod]      |         |  |
|  |  +------------+       +------------+       +------------+         |  |
|  +-------------------------------------------------------------------+  |
+=========================================================================+
```

### 1.4 Control plane components, one by one

**kube-apiserver**
The front door. *Everything* goes through it: `kubectl`, the scheduler, the
kubelets, the controllers, the dashboard. It authenticates you, authorises you
(that is Day 19's RBAC), validates your object, and persists it to etcd. It is
the only component that talks to etcd directly. It is stateless, so you can run
several behind a load balancer. Listens on **6443**.

**etcd**
A distributed key-value store holding the *entire* state of the cluster: every
Pod, Secret, ConfigMap, node status. Lose etcd and you have lost the cluster.
That is why "back up etcd" is the first answer to any disaster-recovery
question. You do not interact with it day to day.

**kube-scheduler**
Watches for Pods with no node assigned and picks one for each. Two phases:

1. **Filtering** - discard nodes that cannot work: not enough CPU or memory,
   a taint the Pod does not tolerate, a `nodeSelector` that does not match,
   a required host port already taken.
2. **Scoring** - rank the survivors: spread pods across nodes, prefer nodes that
   already cached the image, honour affinity preferences. Highest score wins.

The scheduler does **not** start the container. It only writes the chosen node
name into the Pod object. That is a favourite interview follow-up.

**kube-controller-manager**
One binary running dozens of control loops. Each watches one kind of object and
drives actual state toward desired state:

- *Deployment controller* creates and updates ReplicaSets
- *ReplicaSet controller* creates and deletes Pods to hit the replica count
- *Node controller* notices a node went silent and evicts its pods
- plus Job, endpoints, service-account controllers, and more

The analogy that sticks: the **scheduler** is HR deciding which team a new hire
joins; the **controller-manager** is the team lead who keeps noticing "we are
supposed to have five people, we have four, hire one."

**cloud-controller-manager**
Only on managed clusters (EKS/GKE/AKS). Translates Kubernetes concepts into
cloud API calls: a `type: LoadBalancer` Service becomes a real cloud load
balancer, a PVC becomes a real EBS volume. Your kind cluster has none, which is
exactly why `type: LoadBalancer` will sit in `<pending>` forever on Day 07.

### 1.5 Node components, one by one

**kubelet**
The agent on every node, including the control plane. It is the only thing that
actually *starts containers*. It watches the API server for pods assigned to its
node, tells the container runtime to pull images and run containers, runs your
health probes, and reports status back. If the kubelet dies, that node stops
reporting and eventually goes `NotReady`.

**kube-proxy**
Implements the **Service** abstraction (Day 06) in the node's network stack.
When traffic hits a Service's virtual IP, kube-proxy's iptables or IPVS rules
rewrite it to one of the backing Pod IPs. In the default mode it does not proxy
packets itself; it programs kernel rules and gets out of the way.

**Container runtime (containerd)**
Pulls images and runs containers. Speaks CRI to the kubelet.

**CNI plugin**
Less a process than a plugin the kubelet invokes. It gives each Pod an IP and
makes pod-to-pod traffic work *across nodes*. Without a CNI, nodes stay
`NotReady` forever. kind installs `kindnetd`; real clusters use Calico, Cilium,
Flannel, or the AWS VPC CNI.

### 1.6 The Pod, one sentence early

A **Pod** is the smallest thing Kubernetes schedules: one or more containers
sharing a network namespace (same IP, can talk over `localhost`) and optionally
sharing volumes. You almost never create Pods directly - Day 04 explains why -
but everything is ultimately a Pod.

### 1.7 The end-to-end story (say this out loud until it is automatic)

You run `kubectl apply -f deployment.yaml`:

1. `kubectl` reads your kubeconfig and POSTs the object to the **API server**.
2. The API server **authenticates** you, **authorises** you (RBAC), validates
   the object, and persists it in **etcd**.
3. The **Deployment controller** sees a new Deployment and creates a **ReplicaSet**.
4. The **ReplicaSet controller** sees it needs 3 Pods and 0 exist, so it creates
   3 Pod objects. They have no node assigned yet, so their status is `Pending`.
5. The **scheduler** sees 3 unscheduled Pods, filters and scores nodes, and
   writes `nodeName` onto each.
6. The **kubelet** on each chosen node notices a Pod assigned to it, asks
   **containerd** to pull the image and start the container, and invokes the
   **CNI** to give the Pod an IP.
7. The kubelet reports `Running` back to the API server, which stores it in etcd.
8. **kube-proxy** programs rules so a Service can reach the new Pod IPs.

Eight steps. If you can narrate those, you can answer most architecture
interview questions.

### 1.8 Why kind, and what kind is

There are many ways to make a cluster:

| Tool | What it is | When to use it |
|---|---|---|
| **kind** | nodes are Docker containers | **learning, CI - this course** |
| minikube | nodes are VMs or containers | learning, single-node bias |
| k3s / k3d | lightweight distribution | edge, IoT, small servers |
| kubeadm | bootstraps a real cluster on real machines | on-prem production, CKA exam |
| EKS / GKE / AKS | managed control plane | production, costs money |
| OpenShift | Red Hat's opinionated distribution | large enterprises |

kind means **K**ubernetes **IN** **D**ocker. Each "node" is a Docker container
running systemd, kubelet and containerd - containers inside containers. It is
free, starts in a minute, and is genuinely conformant Kubernetes. Start here.
Do not jump to EKS as a beginner: you will spend your time debugging IAM
instead of learning Kubernetes.

---

## Part 2 - Hands-on lab

### Step 1: Confirm Docker is alive

```bash
docker version
docker ps
```

If `docker ps` errors, Docker Desktop is not running. Fix that first; nothing
below will work.

### Step 2: Read the cluster config before you run it

Open [`cluster/kind-config.yaml`](../../cluster/kind-config.yaml) and read it.
Do not skip this - understanding this file removes 80 percent of the confusion
people have with kind.

The important parts:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: devops                  # cluster name -> context becomes "kind-devops"

nodes:
  - role: control-plane
    image: kindest/node:v1.31.4
    extraPortMappings:        # punch holes from your laptop into the node
      - containerPort: 30080  # a NodePort we will use from Day 07 onward
        hostPort: 30080
  - role: worker
    image: kindest/node:v1.31.4
    labels:
      disktype: ssd           # used on Day 18 for nodeSelector exercises
  - role: worker
    image: kindest/node:v1.31.4
    labels:
      disktype: hdd
```

Three things worth understanding right now:

- **`nodes` is a list.** One `control-plane` entry plus two `worker` entries
  gives you three nodes. Add more `- role: worker` blocks and you get more.
- **`image` pins the Kubernetes version.** `v1.31.4` here. Version discipline
  matters: each minor release is supported for about 14 months, then it hits
  end-of-life. Always know what version your cluster runs.
- **`extraPortMappings` is the kind-specific bit.** Your nodes are Docker
  containers, so a NodePort published "on the node" is published inside Docker's
  network, not on your laptop. These mappings forward laptop port 30080 to node
  port 30080. Without them, `localhost:30080` in your browser fails and you will
  waste an hour wondering why.

### Step 3: Create the cluster

```bash
kind create cluster --config cluster/kind-config.yaml
```

Take 90 seconds and read what scrolls by - it maps exactly onto Part 1:

```
Creating cluster "devops" ...
 - Ensuring node image (kindest/node:v1.31.4)     <- pulling the node image
 - Preparing nodes                                <- creating 3 Docker containers
 - Writing configuration                          <- kubeadm config
 - Starting control-plane                         <- apiserver, etcd, scheduler, cm
 - Installing CNI                                 <- kindnetd: pod networking
 - Installing StorageClass                        <- default "standard" (Day 14)
 - Joining worker nodes                           <- workers register with apiserver
Set kubectl context to "kind-devops"
```

Low on RAM? Use `cluster/kind-config-single-node.yaml` instead.

### Step 4: Prove nodes are just containers

```bash
docker ps
```

```
CONTAINER ID   IMAGE                  ...   NAMES
a1b2c3d4e5f6   kindest/node:v1.31.4   ...   devops-control-plane
b2c3d4e5f6a1   kindest/node:v1.31.4   ...   devops-worker
c3d4e5f6a1b2   kindest/node:v1.31.4   ...   devops-worker2
```

Three containers, three nodes. That is the entire trick behind kind.

Now do the same thing from Kubernetes' point of view:

```bash
kubectl get nodes
kubectl get nodes -o wide
```

```
NAME                   STATUS   ROLES           AGE   VERSION
devops-control-plane   Ready    control-plane   85s   v1.31.4
devops-worker          Ready    <none>          70s   v1.31.4
devops-worker2         Ready    <none>          70s   v1.31.4
```

`ROLES` is `<none>` for workers because "worker" is not a real role - it is
simply the absence of the control-plane label. Prove it:

```bash
kubectl get nodes --show-labels
```

Look for `node-role.kubernetes.io/control-plane=` on the first node only.

### Step 5: Find the components you just read about

Every control-plane component runs as a Pod, in the `kube-system` namespace:

```bash
kubectl get pods -n kube-system -o wide
```

```
NAME                                           READY   STATUS    NODE
coredns-7c65d6cfc9-4x8vn                       1/1     Running   devops-control-plane
coredns-7c65d6cfc9-mbz2p                       1/1     Running   devops-control-plane
etcd-devops-control-plane                      1/1     Running   devops-control-plane
kindnet-4k2ph                                  1/1     Running   devops-worker
kindnet-8xw7q                                  1/1     Running   devops-control-plane
kindnet-r9m3d                                  1/1     Running   devops-worker2
kube-apiserver-devops-control-plane            1/1     Running   devops-control-plane
kube-controller-manager-devops-control-plane   1/1     Running   devops-control-plane
kube-proxy-7bxkl                               1/1     Running   devops-worker
kube-proxy-jjm4t                               1/1     Running   devops-control-plane
kube-proxy-tqq2r                               1/1     Running   devops-worker2
kube-scheduler-devops-control-plane            1/1     Running   devops-control-plane
```

Read that list against Part 1 and notice three patterns:

1. **`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` all
   run only on the control-plane node.** They are named with the node suffix
   because they are *static pods* - the kubelet reads their manifests from
   `/etc/kubernetes/manifests` on disk, not from the API server. Bootstrapping
   problem solved: the API server cannot schedule itself.
2. **`kube-proxy` and `kindnet` have one Pod per node.** Anything that must run
   on *every* node is a **DaemonSet** (Day 18). Confirm it:
   `kubectl get daemonsets -n kube-system`
3. **`coredns` is cluster DNS.** It is what makes `http://devboard-backend`
   resolve from inside a Pod on Day 06.

Notice `kubelet` is *not* in that list. It is not a Pod - it is a systemd
service on the node itself, because something has to exist before pods can.
Prove it:

```bash
docker exec -it devops-control-plane bash -c "systemctl status kubelet --no-pager | head -5"
```

### Step 6: Look inside a node

```bash
docker exec -it devops-control-plane bash
```

You are now inside the "node". Explore:

```bash
# processes: kubelet and containerd are real processes here
ps aux | grep -E "kubelet|containerd" | grep -v grep

# static pod manifests - this is how the control plane bootstraps
ls -la /etc/kubernetes/manifests/
cat /etc/kubernetes/manifests/kube-apiserver.yaml | head -30

# the actual containers, via containerd's CLI (there is no docker in here)
crictl ps

exit
```

That `crictl ps` is worth pausing on: there is no Docker daemon inside the node.
containerd is the runtime. This is the CRI point from section 1.1, made concrete.

### Step 7: Understand kubeconfig

```bash
kubectl config current-context     # kind-devops
kubectl config get-contexts        # every cluster kubectl knows about
kubectl config view                # the full file, secrets redacted
```

kubeconfig lives at `~/.kube/config` (`%USERPROFILE%\.kube\config` on Windows)
and has three lists that get tied together:

- **clusters** - API server URL and its CA certificate
- **users** - your client certificate or token
- **contexts** - a named pairing of (cluster + user + default namespace)

`kind create cluster` added all three and switched your current context. When
you later work with several clusters, `kubectl config use-context <name>` is how
you move between them. Running the right command against the wrong cluster is a
real and expensive mistake; check `current-context` before anything destructive.

### Step 8: Talk to the API server directly

`kubectl` is only an HTTP client. Prove it:

```bash
kubectl get --raw /healthz          # -> ok
kubectl get --raw /version          # -> JSON version info
kubectl api-resources | head -30    # every object kind this cluster knows
kubectl api-versions | sort | head -20
```

`kubectl api-resources` is a command you will come back to all course. It shows
each kind's **short name**, its **API group**, and crucially whether it is
**NAMESPACED** (Day 03). Try:

```bash
kubectl api-resources --namespaced=false
```

Those are the cluster-scoped objects: Nodes, Namespaces, PersistentVolumes,
ClusterRoles, StorageClasses. Knowing which list a kind belongs to prevents a
whole category of errors later.

Finally, watch the API server work in real time:

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

---

## Validate

Run these. All five must pass before you move to Day 02.

```bash
# 1. three nodes, all Ready
kubectl get nodes

# 2. the four control-plane components are running
kubectl get pods -n kube-system | grep -E "etcd|apiserver|scheduler|controller-manager"

# 3. one kube-proxy per node
kubectl get pods -n kube-system -l k8s-app=kube-proxy

# 4. the API server answers
kubectl get --raw /healthz          # expect: ok

# 5. your context is the course cluster
kubectl config current-context      # expect: kind-devops
```

**Self-check without looking anything up.** Write your answers down, then check
them against Part 1:

1. Which component decides *where* a Pod runs? Which one *starts* it?
2. Which component is the only one that writes to etcd?
3. If the scheduler is down, can existing pods still serve traffic?
4. Why does `kubelet` not appear in `kubectl get pods -n kube-system`?
5. What does the CNI plugin do, and what breaks without one?

---

## Break it (do these, they are the point)

**A. Kill a node and watch Kubernetes notice.**

```bash
docker stop devops-worker2
kubectl get nodes -w        # Ctrl-C after about 60s
```

The node goes `NotReady` after roughly 40 seconds. That delay is the node
controller grace period, not a bug. Bring it back:

```bash
docker start devops-worker2
kubectl get nodes -w
```

**B. Kill the scheduler and see what still works.**

```bash
docker exec devops-control-plane mv \
  /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/

kubectl get pods -n kube-system | grep scheduler   # gone within ~30s
kubectl get nodes                                  # still works
kubectl run test --image=nginx:alpine              # object is created, but...
kubectl get pods                                   # ...stuck Pending forever
kubectl describe pod test | tail -5                # no scheduling events at all
```

The lesson: **an unhealthy control plane does not take down running workloads.**
Already-scheduled pods keep serving traffic. You just cannot make *changes*.
Restore it:

```bash
docker exec devops-control-plane mv \
  /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 20
kubectl get pods            # the test pod now gets scheduled
kubectl delete pod test
```

**C. Point kubectl at nothing and read the error.**

```bash
kubectl --server=https://localhost:9999 get nodes
```

Learn to tell apart `connection refused` on the API server, a `Forbidden`
(RBAC, Day 19), and a `NotFound` (wrong namespace, Day 03). Those three errors
mean completely different things and you will meet all of them.

---

## Interview questions

<details>
<summary><b>1. Explain the Kubernetes architecture.</b> (asked at every level)</summary>

Two planes. The **control plane** decides: `kube-apiserver` is the single entry
point and the only component that talks to `etcd`, which stores all cluster
state; `kube-scheduler` assigns pods to nodes; `kube-controller-manager` runs
the reconciliation loops that drive actual state toward desired state. The
**data plane** executes: on every node, `kubelet` starts and supervises
containers through a CRI runtime such as containerd, `kube-proxy` programs the
network rules that implement Services, and a CNI plugin provides pod networking.
</details>

<details>
<summary><b>2. Which container runtime does Kubernetes use?</b></summary>

Any runtime implementing the CRI. containerd is the common default; CRI-O is
also widely used. Docker support via dockershim was removed in Kubernetes 1.24.
Images built by Docker still run fine, because they are OCI images.
</details>

<details>
<summary><b>3. What happens when you run kubectl apply -f pod.yaml?</b></summary>

kubectl resolves the kubeconfig context and POSTs to the API server. The API
server authenticates, authorises via RBAC, runs admission controllers, validates
the schema, and persists to etcd. The scheduler sees an unscheduled pod, filters
and scores nodes, and binds it to one. The kubelet on that node pulls the image
via containerd, calls the CNI to attach networking, starts the container, and
reports status back to the API server.
</details>

<details>
<summary><b>4. Is the API server stateful?</b></summary>

No. It is stateless and horizontally scalable; you run several behind a load
balancer. All state lives in etcd. This is a common trick question.
</details>

<details>
<summary><b>5. If etcd is lost, what happens?</b></summary>

You lose the entire cluster state: every object definition. Running pods keep
running for a while because kubelets hold local state, but you cannot query or
change anything and reconciliation stops. This is why etcd backup
(`etcdctl snapshot save`) is the number one control-plane operational task.
</details>

<details>
<summary><b>6. Difference between the scheduler and the controller manager?</b></summary>

The scheduler makes a one-time placement decision for each unscheduled pod. The
controller manager runs continuous loops that create, delete and update objects
to maintain declared state. The scheduler decides *where*; controllers decide
*how many* and *what should exist*.
</details>

<details>
<summary><b>7. Why are the control-plane components static pods?</b></summary>

Chicken and egg: the API server cannot be scheduled by a scheduler that needs
the API server. The kubelet reads manifests from `/etc/kubernetes/manifests` on
local disk and starts those pods with no API server involvement. Once they are
up, the kubelet publishes mirror pods so they show in `kubectl get pods`.
</details>

<details>
<summary><b>8. What is the default API server port?</b></summary>

6443 over HTTPS. The old insecure port 8080 is long gone.
</details>

<details>
<summary><b>9. What breaks without a CNI plugin?</b></summary>

Pods get no IPs and cannot talk across nodes. Nodes report `NotReady` with
`network plugin is not ready`. Nothing schedules. CNI is mandatory.
</details>

<details>
<summary><b>10. When is Kubernetes the wrong choice?</b></summary>

A single small app with steady traffic, a team with no operational capacity, or
anything a single VM and a process manager would handle. Kubernetes has real
running costs: a cluster to patch, RBAC to design, monitoring to operate. It
pays off with many services, real scale requirements, or many teams sharing
infrastructure.
</details>

---

## Cheat card

```bash
kind create cluster --config cluster/kind-config.yaml   # create
kind get clusters                                       # list
kind delete cluster --name devops                       # destroy

kubectl cluster-info                       # where is the API server
kubectl get nodes -o wide                  # the machines
kubectl get pods -n kube-system            # the components
kubectl api-resources                      # every kind this cluster knows
kubectl api-resources --namespaced=false   # cluster-scoped kinds
kubectl get --raw /healthz                 # is the API server alive
kubectl config current-context             # which cluster am I on
```

| Component | Runs on | Job |
|---|---|---|
| kube-apiserver | control plane | the only door in; validates and persists |
| etcd | control plane | stores all cluster state |
| kube-scheduler | control plane | picks a node for each new Pod |
| kube-controller-manager | control plane | reconciliation loops |
| kubelet | every node | starts containers, runs probes, reports status |
| kube-proxy | every node | implements Services in the network stack |
| containerd | every node | pulls images, runs containers |
| CNI (kindnet) | every node | pod IPs and cross-node networking |
| CoreDNS | control plane | in-cluster DNS |

---

**Next: [Day 02 - kubectl and your first Pod](../day-02-kubectl-and-your-first-pod/)**
