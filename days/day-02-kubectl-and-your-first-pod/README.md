# Day 02 — kubectl & Your First Pod

**Time:** 60-75 minutes
**Prerequisites:** Day 01 (cluster running, `kubectl get nodes` shows 3 Ready)

Today you write your first manifest by hand, run it, and learn the four commands
you will use more than all others combined: `describe`, `logs`, `exec`,
`port-forward`.

---

## Part 1 - Concepts

### 2.1 What a Pod actually is

A **Pod** is the smallest unit Kubernetes schedules. It is a wrapper around one
or more containers that:

- **share one network namespace** - one IP address for the whole Pod, and the
  containers inside can reach each other on `localhost`
- **can share volumes** - useful for sidecars writing to a shared directory
- **live and die together** - scheduled to one node, as one unit

```
+------------------- Pod (IP 10.244.1.7) -------------------+
|                                                            |
|   +------------------+       +----------------------+      |
|   | container: app   |       | container: log-agent |      |
|   | listens :8080    |<----->| reads /var/log       |      |
|   +------------------+  localhost  +-----------------+     |
|              \                       /                     |
|               \--- shared volume ---/                      |
+------------------------------------------------------------+
```

**Why not just "container"?** Because some things genuinely need to run
side-by-side sharing localhost and disk: a log shipper, a service-mesh proxy, a
config reloader. That pattern is called a **sidecar**. The Pod is the box that
makes it possible. In practice, **most pods have exactly one container** - do
not add a second one without a specific reason.

### 2.2 Pods are ephemeral. This matters more than it sounds.

> Kubernetes Pods are inherently **ephemeral**: non-permanent, short-lived
> entities that can be created, terminated and replaced at any time.

Concretely:

- A Pod that dies is **not** restarted as the same Pod. A *new* Pod is created
  with a **new name** and a **new IP**.
- Anything written to the container filesystem is gone. (Day 14 fixes this.)
- You must never hardcode a Pod IP anywhere. (Day 06 fixes this.)

This single property is why almost every other Kubernetes object exists:
Deployments (replace dead pods), Services (a stable address in front of moving
pods), PersistentVolumes (data that outlives the pod).

### 2.3 Every Kubernetes object has the same four top-level fields

Learn this shape once and every manifest in the course becomes readable:

```yaml
apiVersion: v1        # WHICH API group and version validates this object
kind: Pod             # WHAT kind of object
metadata:             # WHO it is: name, namespace, labels, annotations
  name: nginx
spec:                 # WHAT you want (the desired state) - you write this
  containers: [...]
status:               # WHAT is actually true - Kubernetes writes this, not you
```

**`apiVersion` rules you must memorise** (this is the number one beginner error):

| Kind | apiVersion |
|---|---|
| Pod, Service, ConfigMap, Secret, Namespace, PersistentVolume(Claim), ServiceAccount | `v1` |
| Deployment, ReplicaSet, StatefulSet, DaemonSet | `apps/v1` |
| Job, CronJob | `batch/v1` |
| HorizontalPodAutoscaler | `autoscaling/v2` |
| Role, RoleBinding, ClusterRole, ClusterRoleBinding | `rbac.authorization.k8s.io/v1` |
| Ingress, NetworkPolicy | `networking.k8s.io/v1` |

`v1` with no prefix is the **core group**, the original API. Everything else is
a *named group* and you must write the group name. Getting this wrong gives you
`no matches for kind "Deployment" in version "v1"`.

Never memorise blindly - the cluster will tell you:

```bash
kubectl api-resources | grep -i deployment
kubectl explain deployment          # docs for the kind
kubectl explain pod.spec.containers # docs for a specific field, recursively
```

`kubectl explain` is the most underused command in Kubernetes. It is offline
documentation for the exact version your cluster runs.

### 2.4 The anatomy of a kubectl command

```
kubectl  <verb>  <kind>  <name>  <flags>
         ------   -----   -----
         get      pods    nginx   -n devboard -o yaml
         describe pod     nginx   -n devboard
         delete   pod     nginx   -n devboard
```

Verbs you will use constantly: `get`, `describe`, `apply`, `delete`, `logs`,
`exec`, `edit`, `scale`, `rollout`, `port-forward`, `top`, `explain`.

Flags worth learning today:

| Flag | Does |
|---|---|
| `-n <ns>` | target a namespace (Day 03) |
| `-A` | all namespaces |
| `-o wide` | extra columns: node, pod IP |
| `-o yaml` / `-o json` | the full object as stored in etcd |
| `-w` | watch: keep printing changes as they happen |
| `-l app=frontend` | filter by label (Day 04) |
| `--dry-run=client -o yaml` | generate a manifest without creating anything |

### 2.5 Pod lifecycle: the phases you will see

| Phase | Meaning |
|---|---|
| `Pending` | Accepted, but not running yet: waiting for scheduling or image pull |
| `Running` | Bound to a node, at least one container is running |
| `Succeeded` | All containers exited 0 (normal for Jobs, not for servers) |
| `Failed` | All containers terminated, at least one non-zero exit |
| `Unknown` | The node stopped reporting |

And the states you will see in the `STATUS` column that are *not* phases but
container-level reasons - these are the ones that actually matter in practice:

| STATUS | What went wrong |
|---|---|
| `ContainerCreating` | Normal, briefly. Stuck here means image pull or volume mount |
| `ImagePullBackOff` / `ErrImagePull` | Image name wrong, tag wrong, or private registry with no credentials |
| `CrashLoopBackOff` | Container starts then exits, repeatedly. Read the logs |
| `OOMKilled` | Container exceeded its memory limit (Day 16) |
| `Completed` | Exited 0. Fine for a Job, a bug for a server |
| `Terminating` | Being deleted; stuck here usually means a finalizer or a long grace period |

`CrashLoopBackOff` deserves a note: the "BackOff" means Kubernetes is
deliberately waiting longer between each restart (10s, 20s, 40s... capped at
5 minutes). It is not stuck. It is being polite.

---

## Part 2 - Hands-on lab

Work in a scratch directory so you can throw it away:

```bash
mkdir -p scratch/day02 && cd scratch/day02
```

### Step 1: The imperative way (and why you will stop using it)

```bash
kubectl run nginx --image=nginx:1.27-alpine
kubectl get pods
kubectl get pods -o wide
```

That worked, and it is a fine way to get a debug pod in a hurry. But there is no
file, nothing to commit, nothing to review, and nobody else can reproduce it.

Delete it and do it properly:

```bash
kubectl delete pod nginx
```

### Step 2: Generate a manifest instead of writing from memory

This is the trick that makes the imperative commands genuinely useful:

```bash
kubectl run nginx --image=nginx:1.27-alpine \
  --dry-run=client -o yaml > generated.yaml

cat generated.yaml
```

`--dry-run=client` means "build the object locally and show it, do not send it
to the API server". You now have a skeleton to edit. Use this whenever you
cannot remember a field layout.

### Step 3: Write your own Pod manifest

Create `pod.yaml`. **Type it, do not paste it** - the muscle memory is the point.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
    tier: web
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
```

Field by field:

- **`metadata.name`** - unique within the namespace, DNS-safe (lowercase,
  digits, `-`). No underscores, no capitals.
- **`metadata.labels`** - arbitrary key/value pairs. They look useless today.
  From Day 04 onward they are the glue that connects every object to every
  other object.
- **`spec.containers`** - a **list** (note the `-`). Each needs `name` and
  `image`.
- **`image: nginx:1.27-alpine`** - always pin a tag. `nginx` alone means
  `nginx:latest`, which means "whatever was pushed most recently" and is how you
  get a different version on every node.
- **`ports.containerPort`** - purely informational. It does *not* open or
  publish anything; the container already listens wherever it listens. It exists
  to document intent and to be referenced by name later.

Apply it:

```bash
kubectl apply -f pod.yaml
kubectl get pods -w        # watch: ContainerCreating -> Running. Ctrl-C
```

### Step 4: `describe` - the command that answers most questions

```bash
kubectl describe pod nginx
```

Read the whole output once. Then note the sections that matter:

```
Name:         nginx
Namespace:    default
Node:         devops-worker/172.18.0.3     <- the scheduler picked this
Labels:       app=nginx
              tier=web
Status:       Running
IP:           10.244.1.5                   <- pod IP, from the CNI
Containers:
  nginx:
    Image:          nginx:1.27-alpine
    State:          Running
    Ready:          True
    Restart Count:  0                      <- non-zero means it has crashed
Events:                                    <- ALWAYS READ THIS SECTION
  Type    Reason     Age   From               Message
  Normal  Scheduled  30s   default-scheduler  Successfully assigned default/nginx to devops-worker
  Normal  Pulling    29s   kubelet            Pulling image "nginx:1.27-alpine"
  Normal  Pulled     27s   kubelet            Successfully pulled image
  Normal  Created    27s   kubelet            Created container nginx
  Normal  Started    27s   kubelet            Started container nginx
```

Those five events are the whole Day 01 story, printed by your cluster:
scheduler assigns, kubelet pulls, kubelet creates, kubelet starts.

**Rule for the rest of your career: when something is wrong, `describe` it and
read `Events` from the bottom up.** Around 90 percent of failures name their own
cause there.

Note: events expire after about an hour by default. If `Events: <none>` on an
old pod, that is normal, not a clue.

### Step 5: `logs` - what the container printed

```bash
kubectl logs nginx
kubectl logs nginx -f              # follow, like tail -f. Ctrl-C to stop
kubectl logs nginx --tail=20
kubectl logs nginx --since=5m
kubectl logs nginx --previous      # logs of the PREVIOUS crashed container
```

`--previous` is the one that saves you: when a pod is in `CrashLoopBackOff`, the
current container has not started, so plain `logs` shows nothing useful. The
crash reason is in the *previous* container's logs.

With multiple containers in a Pod you must say which:
`kubectl logs <pod> -c <container>`.

### Step 6: `exec` - get a shell inside

```bash
kubectl exec -it nginx -- sh
```

The `--` separates kubectl's flags from the command you want to run. Inside:

```sh
hostname            # equals the pod name
cat /etc/hostname
ls /usr/share/nginx/html
wget -qO- localhost:80 | head -5    # the app, from inside the pod
env | sort
exit
```

One-liners without a shell session:

```bash
kubectl exec nginx -- nginx -v
kubectl exec nginx -- ls /etc/nginx
```

If a container has no shell (distroless, scratch), `exec` fails. Use
`kubectl debug` with an ephemeral container instead:

```bash
kubectl debug -it nginx --image=busybox:1.36 --target=nginx
```

### Step 7: `port-forward` - reach it from your browser

The Pod has an IP like `10.244.1.5`, which only exists inside the cluster
network. Your laptop cannot route to it. `port-forward` tunnels through the API
server:

```bash
kubectl port-forward pod/nginx 8081:80
```

Leave that running and open <http://localhost:8081> - the nginx welcome page.
`8081` is your laptop, `80` is the container. Ctrl-C to stop.

`port-forward` is a **debugging tool**, not a way to expose an app. It is one
process, on one machine, tunnelling to one pod. Days 06 and 07 do it properly
with Services.

### Step 8: A multi-container Pod (the sidecar pattern)

Create `sidecar-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-with-sidecar
  labels:
    app: demo
spec:
  volumes:
    - name: shared-logs
      emptyDir: {}              # a scratch dir that lives as long as the Pod

  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - while true; do echo "$(date) hello from writer" >> /data/app.log; sleep 3; done
      volumeMounts:
        - name: shared-logs
          mountPath: /data

    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "tail -f /data/app.log"]
      volumeMounts:
        - name: shared-logs
          mountPath: /data
```

```bash
kubectl apply -f sidecar-pod.yaml
kubectl get pod web-with-sidecar          # READY shows 2/2
kubectl logs web-with-sidecar -c reader -f    # Ctrl-C
```

The `reader` container is tailing a file the `writer` container created. Two
containers, one Pod, one shared `emptyDir` volume. That is the sidecar pattern,
and it is exactly how log shippers and service-mesh proxies work.

Prove they share a network namespace too:

```bash
kubectl exec web-with-sidecar -c reader -- netstat -tlnp 2>/dev/null || true
kubectl get pod web-with-sidecar -o jsonpath='{.status.podIP}{"\n"}'
```

One IP for both containers.

### Step 9: See the object as Kubernetes stores it

```bash
kubectl get pod nginx -o yaml
```

Compare that to the 14-line file you wrote. Kubernetes filled in dozens of
defaults: `restartPolicy: Always`, `dnsPolicy: ClusterFirst`, a
`serviceAccountName`, tolerations, a whole `status` block. Your manifest is the
minimum; the stored object is the complete picture.

Pull out single fields with JSONPath - you will use this constantly in scripts:

```bash
kubectl get pod nginx -o jsonpath='{.status.podIP}{"\n"}'
kubectl get pod nginx -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP
```

### Step 10: Clean up

```bash
kubectl delete -f pod.yaml
kubectl delete -f sidecar-pod.yaml
kubectl get pods                 # No resources found
```

Deleting by file is better than by name: it deletes exactly what that file
created, nothing more.

---

## Validate

```bash
kubectl apply -f solution/pod.yaml
kubectl wait --for=condition=Ready pod/nginx --timeout=60s
kubectl get pod nginx -o jsonpath='{.status.phase}{"\n"}'     # Running
kubectl exec nginx -- nginx -v                                 # prints version
kubectl logs nginx --tail=3                                    # some output
kubectl delete -f solution/pod.yaml
```

You are ready for Day 03 when you can, without looking it up:

- write a Pod manifest from memory (all four top-level fields)
- say which `apiVersion` a Pod uses and which one a Deployment uses
- name the four debugging commands and when to reach for each
- explain what "pods are ephemeral" means in three concrete consequences

---

## Break it

**A. A typo in the image name.**

```bash
kubectl run broken --image=nginx:definitely-not-a-real-tag
kubectl get pods                          # ErrImagePull -> ImagePullBackOff
kubectl describe pod broken | tail -8     # "Failed to pull image ... not found"
kubectl delete pod broken
```

**B. A container that exits immediately.**

```bash
kubectl run crasher --image=busybox:1.36 -- sh -c "echo starting; sleep 2; exit 1"
kubectl get pods -w                       # Running -> Error -> CrashLoopBackOff
kubectl logs crasher                      # "starting"
kubectl logs crasher --previous           # the previous attempt
kubectl describe pod crasher | grep -A5 "Last State"
kubectl delete pod crasher
```

Notice `Exit Code: 1` and `Reason: Error` under `Last State`. Exit code 1 means
your app failed; exit code 137 means it was killed (usually OOM, Day 16); exit
code 0 with `Completed` means it finished and Kubernetes restarted it because
`restartPolicy: Always` is the default.

**C. Wrong apiVersion.**

Change `apiVersion: v1` to `apiVersion: apps/v1` in `pod.yaml` and apply:

```
error: unable to recognize "pod.yaml": no matches for kind "Pod" in version "apps/v1"
```

Memorise that error text. You will see it whenever a manifest was written for a
different Kubernetes version.

**D. YAML indentation.**

Indent `image:` one extra space so it becomes a child of `name:` instead of a
sibling. Apply it and read the error. YAML indentation bugs account for a large
share of all beginner failures; the fix is a YAML-aware editor plus
`kubectl apply --dry-run=server -f file.yaml` before you commit.

Note the difference: `--dry-run=client` validates locally, `--dry-run=server`
sends it to the API server for real validation without persisting. The server
version catches far more.

---

## Interview questions

<details>
<summary><b>1. What is a Pod and why not just run containers?</b></summary>

A Pod is the smallest schedulable unit: one or more containers sharing a network
namespace (one IP, reachable over localhost) and optionally volumes, scheduled
together on one node. The abstraction exists so tightly coupled helpers -
sidecars like log shippers or service-mesh proxies - can share networking and
disk with the main container. Most pods run exactly one container.
</details>

<details>
<summary><b>2. What does it mean that pods are ephemeral, and how do you handle it?</b></summary>

A Pod is never restarted in place; it is replaced by a new Pod with a new name
and new IP. Three consequences: filesystem writes are lost (use PersistentVolumes),
IPs change (use Services), and pods must be replaceable (use Deployments rather
than bare pods). Applications should be stateless, or push state to a database
or volume.
</details>

<details>
<summary><b>3. What is CrashLoopBackOff and how do you debug it?</b></summary>

The container starts and exits repeatedly; Kubernetes backs off exponentially
between restarts, up to five minutes. Debug it with `kubectl logs <pod>
--previous` for the failed container output, then `kubectl describe pod` for the
exit code and last state. Common causes: bad command or entrypoint, missing
config or environment variable, a dependency not reachable yet, or a liveness
probe that is too aggressive.
</details>

<details>
<summary><b>4. Difference between kubectl create and kubectl apply?</b></summary>

`create` is imperative and fails if the object exists. `apply` is declarative
and performs a three-way merge between your file, the live object, and the
last-applied annotation, so it works for both creation and update and is safe to
re-run. Use `apply` for everything you keep in git.
</details>

<details>
<summary><b>5. What does containerPort in a Pod spec actually do?</b></summary>

Almost nothing at runtime. It is documentation: it does not publish or open a
port, and the container listens wherever the process binds regardless. Its real
value is that it can be given a name that a Service `targetPort` refers to, and
that tooling reads it.
</details>

<details>
<summary><b>6. Your pod is stuck in Pending. Walk me through it.</b></summary>

Pending means accepted but not yet running - almost always a scheduling problem.
`kubectl describe pod` and read Events. Typical causes: insufficient CPU or
memory on every node, a nodeSelector or affinity rule nothing matches, a taint
with no matching toleration, an unbound PersistentVolumeClaim, or simply no
Ready nodes. If it is scheduled but still Pending, it is image pull or volume
mounting instead.
</details>

<details>
<summary><b>7. How do you debug a container with no shell?</b></summary>

`kubectl debug -it <pod> --image=busybox --target=<container>` attaches an
ephemeral container sharing the target's namespaces, giving you tools inside the
running pod without rebuilding the image. Alternatively
`kubectl debug node/<node> -it --image=busybox` for node-level debugging.
</details>

<details>
<summary><b>8. Why is kubectl port-forward not a way to expose an application?</b></summary>

It is a single tunnel from one client machine through the API server to one pod.
It has no load balancing, no high availability, dies with the terminal, and puts
production traffic through the API server. It is a debugging tool. Use a Service
plus Ingress for real exposure.
</details>

<details>
<summary><b>9. What is the default restartPolicy and what are the options?</b></summary>

`Always` is the default and is the only value permitted for pods managed by a
Deployment. `OnFailure` restarts only on non-zero exit, and `Never` does not
restart - both are used for Jobs. Note that restartPolicy applies to containers
within a pod; it never moves a pod to another node.
</details>

<details>
<summary><b>10. How would you find which node a pod is on, and its IP, in a script?</b></summary>

`kubectl get pod <name> -o jsonpath='{.spec.nodeName}'` and
`{.status.podIP}`, or `kubectl get pods -o custom-columns=...` for a table.
Avoid parsing the human-readable output of plain `kubectl get`.
</details>

---

## Cheat card

```bash
# create
kubectl apply -f pod.yaml
kubectl run tmp --image=nginx:alpine --rm -it -- sh      # throwaway debug pod
kubectl run x --image=nginx --dry-run=client -o yaml     # generate a manifest

# inspect
kubectl get pods -o wide
kubectl get pod nginx -o yaml
kubectl describe pod nginx                # READ THE EVENTS
kubectl get pod nginx -o jsonpath='{.status.podIP}'

# debug
kubectl logs nginx -f --tail=50
kubectl logs nginx --previous             # the crashed container
kubectl logs nginx -c sidecar             # a specific container
kubectl exec -it nginx -- sh
kubectl debug -it nginx --image=busybox --target=nginx
kubectl port-forward pod/nginx 8081:80

# learn
kubectl explain pod.spec.containers
kubectl api-resources | grep -i pod

# delete
kubectl delete -f pod.yaml
kubectl delete pod nginx --force --grace-period=0    # last resort only
```

---

**Next: [Day 03 - Namespaces](../day-03-namespaces/)**
