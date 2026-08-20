# CKA 17 solution

## Challenge answers

### C1 - Harden a workload

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  volumes:
    - name: cache
      emptyDir: {}
  containers:
    - name: api
      image: mycorp/api:1.7.2            # pinned -- not :latest
      ports:
        - containerPort: 8080            # NOT 80
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: cache
          mountPath: /var/cache/api
```

**The port.** The obvious answer is to add `NET_BIND_SERVICE` so a non-root
process can bind port 80. **That is wrong under `restricted`** — the level
permits exactly one added capability, `NET_BIND_SERVICE`, so it would technically
pass, but it is still the wrong call: you have re-granted a privilege to solve a
problem that does not need it.

**Change the application to listen on 8080 and let the Service map 80 to it.**
`port: 80, targetPort: 8080` costs nothing, works everywhere, and means the
container needs no capabilities at all. Ports below 1024 are privileged for
historical reasons that stopped applying the moment a load balancer sat in front.

**The cache directory.** `readOnlyRootFilesystem: true` makes `/var/cache/api`
unwritable, so mount an `emptyDir` there. Two things follow: the cache is
**per-pod and lost on restart** — which is correct for a cache and would be
wrong for anything else — and if the application needs it to survive, it is not a
cache and needs a PVC ([Day 14](../../../days/day-14-volumes-pv-pvc/)).

Also note the change nobody asks for and every reviewer should: **`:latest`
became a pinned version** (17.2). A hardened pod running an image you cannot
identify is not hardened.

### C2 - Diagnose four pull failures

**1. `pull access denied, repository does not exist or may require authorization`**

**Missing or wrong credentials.** The registry answered — that is the tell,
compared with case 2 — and declined. Confirm:

```bash
kubectl get pod POD -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
kubectl get sa default -o jsonpath='{.imagePullSecrets}{"\n"}'
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Check that the `--docker-server` in the Secret **exactly matches** the registry
host in the image reference. `registry.example.com` and
`https://registry.example.com/v1/` are different keys in `auths`, and a mismatch
means the credential is simply never offered.

Note the message is deliberately ambiguous between "does not exist" and
"requires auth" — registries refuse to confirm which, so a typo in the repository
name produces the same error.

**2. `no such host`**

**DNS.** The node cannot resolve the registry hostname. Nothing to do with
credentials or Kubernetes.

```bash
kubectl get pod POD -o wide          # which node?
docker exec <node> nslookup registry.internal.example
docker exec <node> cat /etc/resolv.conf
```

On a real cluster this is usually a private registry reachable only through
internal DNS that the nodes do not use, or a proxy variable missing from the
container runtime's environment.

**3. `ErrImageNeverPull`**

**`imagePullPolicy: Never` and the image is not on that node.** No registry was
contacted at all.

```bash
kubectl get pod POD -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
docker exec <node> crictl images | grep <image>
```

The usual cause is `kind load docker-image` onto a cluster with several nodes
where the pod landed on one that did not get it, or a tag typo — the string in
the manifest must match `crictl images` **exactly**, tag included.

**4. Works in `dev`, `ImagePullBackOff` in `prod`**

**The pull Secret exists in `dev` and not in `prod`.** Secrets are namespaced
(17.3), and so is the ServiceAccount that may be carrying it.

```bash
kubectl get secret -n dev  --field-selector type=kubernetes.io/dockerconfigjson
kubectl get secret -n prod --field-selector type=kubernetes.io/dockerconfigjson
kubectl get sa default -n dev  -o jsonpath='{.imagePullSecrets}{"\n"}'
kubectl get sa default -n prod -o jsonpath='{.imagePullSecrets}{"\n"}'
```

**"Same cluster, different namespace" is the signature of a namespaced object
that was never copied.** The fix is to create the Secret in `prod` and attach it
to that namespace's `default` ServiceAccount — and then to ask why namespace
creation does not do this automatically, because it should.

### C3 - Root, but not really

**The two-command demonstration:**

```bash
kubectl exec capabilities-demo -c default-caps -- id
# uid=0(root) gid=0(root)

kubectl exec capabilities-demo -c default-caps -- date -s "12:00:00"
# date: can't set date: Operation not permitted
```

Root, and it cannot set the clock. Contrast with the container that was granted
`SYS_TIME`, where the identical command succeeds.

**The mechanism is Linux capabilities** (17.4). The kernel long ago split "root
can do anything" into about forty discrete privileges, and a container runtime
grants a small default subset — no `SYS_TIME`, no `SYS_ADMIN`, no `SYS_MODULE`,
no `SYS_BOOT`. UID 0 inside a container is root *stripped of the capabilities
that make root interesting*. Namespaces do the rest: a separate PID, mount,
network and (optionally) user namespace means there is very little of the host
left to reach even if it wanted to.

**What is correct in their claim:** the container **shares the host kernel**.
There is one kernel, and a kernel vulnerability reachable from an unprivileged
syscall is a vulnerability the container can reach. Namespaces and capabilities
are kernel features enforcing a boundary *inside* the thing that would be
compromised — so they raise the cost of escape without making it impossible.
Container escapes are rare but they are real, and they are why "containers are a
security boundary" is a statement with an asterisk.

That is also why `privileged: true` is so much worse than it looks: it does not
weaken the boundary, it **removes** it.

**If you need a real boundary**, you need a separate kernel:

- **A separate node pool**, or separate cluster, for untrusted workloads — the
  cheapest and most common answer.
- **A sandboxed runtime**: gVisor (intercepts syscalls in userspace) or Kata
  Containers (a real VM per pod), selected per workload with a `RuntimeClass`.
- **A separate VM entirely**, if the workload is genuinely hostile.

And in the meantime, the hardening in this assignment — `runAsNonRoot`,
`drop: ["ALL"]`, `allowPrivilegeEscalation: false`, `RuntimeDefault` seccomp —
shrinks the syscall surface enough that most published escapes stop working.
**Depth, not a wall.**

### C4 - Which level?

| Field | Pod | Container | If both are set |
|---|---|---|---|
| `fsGroup` | **yes** | no | n/a |
| `capabilities` | no | **yes** | n/a |
| `runAsUser` | yes | yes | **container wins** |
| `readOnlyRootFilesystem` | no | **yes** | n/a |
| `sysctls` | **yes** | no | n/a |
| `seccompProfile` | yes | yes | **container wins** |
| `privileged` | no | **yes** | n/a |
| `runAsNonRoot` | yes | yes | **container wins** |

**Why the split — and it is the same reason both times: the field's scope is the
scope of the thing it configures.**

`capabilities`, `privileged`, `readOnlyRootFilesystem` and
`allowPrivilegeEscalation` are properties of a **single process tree and its
root filesystem**. Each container has its own image, its own `/`, and its own
process. There is no such thing as "the pod's root filesystem" to make
read-only, and two containers in a pod can legitimately need different
capabilities — a CNI sidecar needing `NET_ADMIN` alongside an application that
should have none. A pod-level setting would have to mean "apply to all", which
is exactly what you do not want.

`fsGroup`, `supplementalGroups` and `sysctls` are properties of things **shared
by the whole pod**. `fsGroup` changes the group ownership of *mounted volumes*,
and volumes belong to the pod — the kubelet applies the GID once, at mount time,
before any container starts. Letting each container claim a different `fsGroup`
would be incoherent: there is one directory, and it can have one group. `sysctls`
are the same argument at the kernel level — the pod shares a network namespace,
so `net.*` sysctls are a pod-wide property by construction.

The rule that falls out of this: **if two containers could reasonably want
different values, the field is container-level. If the resource is shared, it is
pod-level.**

`runAsUser` is at both because it is a property of the process (so it belongs on
the container) but is almost always uniform (so a pod-level default saves
repetition) — hence the override rule rather than an either/or.

### C5 - Enforce without an outage

**The procedure, in order:**

**1. Find out what would break, before anything does.**

```bash
kubectl label --overwrite namespace prod \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.31 \
  pod-security.kubernetes.io/audit=restricted
```

`warn` and `audit` **change nothing**. Nothing is rejected, nothing is evicted.
But every subsequent create or update in that namespace prints its violations,
and every one is recorded in the audit log.

**2. Force the warnings out of hiding**, because `warn` only fires on admission
and your twelve Deployments are not being admitted right now:

```bash
for d in $(kubectl get deploy -n prod -o name); do
  kubectl get "$d" -n prod -o yaml | kubectl apply -f - --dry-run=server 2>&1 | grep -i "would violate" 
done
```

**`--dry-run=server` runs the full admission chain and creates nothing** — it is
the single most useful command in this whole procedure. You now have the
complete list of offending workloads and, for each, every violated rule at once.

**3. Fix the workloads**, one Deployment at a time, in the order the warnings
gave you. For each, the changes are almost always the same four fields (17.5) —
`runAsNonRoot`, `runAsUser`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` — plus an
`emptyDir` wherever `readOnlyRootFilesystem` breaks something. Roll each out and
confirm it is healthy before starting the next.

**4. Re-run step 2 until it is silent.** No output means no workload in the
namespace violates the policy.

**5. Only then, enforce:**

```bash
kubectl label --overwrite namespace prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31
```

**6. Keep the escape hatch in your head:**

```bash
kubectl label --overwrite namespace prod pod-security.kubernetes.io/enforce=privileged
```

That reverts instantly and unblocks admission while you fix whatever you missed.

**When a workload you failed to fix actually fails**

**Not when you apply the label.** PSA gates **admission**, and a running pod is
already admitted (17.6). Applying `enforce=restricted` to a namespace full of
violating pods does nothing at all — they keep running, `kubectl get pods` looks
perfect, and every dashboard is green.

The failure happens **the next time something creates a pod**, which is at a
moment you do not control:

- a node reboots or is drained ([CKA 12](../../12-cluster-maintenance/))
- an HPA scales out ([Day 17](../../../days/day-17-horizontal-pod-autoscaler/))
- a liveness probe restarts a pod, or the Deployment is rolled for any reason
- somebody deploys a routine change

**That is the dangerous property of this feature**: the gap between "I made a
mistake" and "the mistake is visible" can be days or weeks, and it closes at
3am during an unrelated node failure — the exact moment when the ReplicaSet
cannot replace a pod and nobody thinks to look at a namespace label.

Two consequences worth acting on:

- **Never enforce and walk away.** After step 5, deliberately delete one pod of
  each Deployment and watch it come back. That converts a latent failure into a
  controlled one.
- **Alert on `FailedCreate` on ReplicaSets**, not just on pod status. A
  ReplicaSet that cannot create a pod reports it there and nowhere else:

```bash
kubectl get events -A --field-selector reason=FailedCreate
```

---

## Files

| File | Purpose |
|---|---|
| `01-image-name-forms.yaml` | four names, three of which are one image |
| `02-private-image-BAD.yaml` | `ErrImagePull` with no credentials |
| `03-imagepullsecret-pod.yaml` | the explicit `imagePullSecrets` form |
| `04-serviceaccount-pullsecret.yaml` | the form worth knowing -- on the ServiceAccount |
| `05-pullpolicy.yaml` | `imagePullPolicy: Never` -> `ErrImageNeverPull` |
| `06-securitycontext-levels.yaml` | 1002 vs 1001 vs a shared `fsGroup` |
| `07-runasnonroot-BAD.yaml` | `CreateContainerConfigError` -- fails closed |
| `08-runasnonroot-fixed.yaml` | the same policy, satisfied |
| `09-capabilities.yaml` | three postures, one image, one UID |
| `10-readonly-rootfs.yaml` | immutable `/`, writable `/tmp` |
| `11-hardened.yaml` | the full baseline, running under `restricted` |
| `12-privileged-BAD.yaml` | accepted in one namespace, rejected in another |
| `verify.sh` | checks every claim in Part 4 |

> **Do not `kubectl apply -f solution/`.** Several files are meant to fail, and
> `11`/`12` target a different namespace. Follow the lab steps.

---

## Why there is no real private registry here

The honest answer: running one properly needs the **container runtime** to trust
it, and that configuration is different on Docker Desktop for Windows, Docker
Engine on Linux, and inside a kind node — either TLS certificates distributed to
every node, or an `insecure-registries` entry in each runtime's configuration.
It is a genuinely useful exercise and a poor fit for a lab that must work
identically everywhere.

What the lab does instead covers everything the exam tests: creating the Secret,
reading it back, attaching it to a pod and to a ServiceAccount, and telling the
four pull failures apart (C2). The part you do not get to see is a **successful**
authenticated pull.

If you want it, the shape is:

```bash
docker run -d --name registry --network kind -p 5000:5000 registry:2
docker tag busybox:1.36 localhost:5000/team/app:1.4
docker push localhost:5000/team/app:1.4
# then, on every kind node, add "registry:5000" to the containerd config as an
# insecure mirror and restart containerd
```

The last line is the one that varies, and it is why it is a footnote rather than
a step.
