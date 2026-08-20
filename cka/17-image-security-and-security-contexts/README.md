# CKA 17 — Image Security and Security Contexts

**Time:** 90-110 minutes
**Prerequisites:** [Day 08](../../days/day-08-build-and-load-app-images/), [Day 10](../../days/day-10-secrets/), [CKA 07](../07-admission-controllers/), [CKA 16](../16-service-accounts/)
**Source lectures:** 170, 172, 173, 174, 176

Two questions this assignment answers: **where does this image come from, and
who is allowed to pull it** — and **what is the process inside it allowed to
do**.

---

## Part 1 - Concepts

### 17.1 An image name has four parts, three of which you usually omit

```
nginx
```

is shorthand. Written out:

```
docker.io / library / nginx : latest
--------   -------   -----   ------
registry   account   repo    tag
```

| Part | Default when omitted |
|---|---|
| **registry** | `docker.io` |
| **account** | `library` — where Docker's own official images live |
| **repository** | (required) |
| **tag** | `latest` |

So `nginx`, `library/nginx` and `docker.io/library/nginx:latest` are the same
image. Change the account and the shorthand stops working: `bitnami/nginx` is
`docker.io/bitnami/nginx:latest`, and there is no `library` involved.

**A registry other than Docker Hub must be spelled out in full:**

| Registry | Host |
|---|---|
| Docker Hub | `docker.io` |
| Google | `gcr.io` |
| **Kubernetes' own** | **`registry.k8s.io`** |
| Red Hat / Quay | `quay.io` |
| GitHub | `ghcr.io` |
| your own | `registry.internal.example:5000/team/app:1.4` |

> **`registry.k8s.io` is where control-plane images come from** — you saw it in
> [CKA 06](../06-priority-schedulers-profiles/) (`registry.k8s.io/pause`,
> `registry.k8s.io/kube-scheduler`). It is not on Docker Hub.

### 17.2 `:latest` is not a version

`latest` is a tag like any other — it means "whatever was pushed last", and it
moves. Two pods created a week apart from `myapp:latest` can be running
different code, and neither manifest records which.

This interacts with `imagePullPolicy`:

| Policy | Behaviour |
|---|---|
| `IfNotPresent` | use the node's cached copy if there is one |
| `Always` | ask the registry every time (it still reuses cached layers) |
| `Never` | only use a cached copy; **fail if absent** |

**The default is version-dependent, and this is an exam question:**

- tag is `latest` **or omitted** → `Always`
- any other tag → `IfNotPresent`

`Never` is what [Day 08](../../days/day-08-build-and-load-app-images/) relies on
after `kind load docker-image` — the image exists only on the node and asking a
registry for it would fail.

The real fix for reproducibility is a **digest**:

```yaml
image: nginx@sha256:9c1b8f4d3e...      # immutable, always the same bytes
```

A digest cannot move. It is also unreadable, which is why most people pin a real
version tag and enforce "no `:latest`" with a policy
([CKA 07](../07-admission-controllers/) built exactly that rule in CEL).

### 17.3 Private registries

Pulling from a private repository needs credentials **on the node**, because the
kubelet does the pulling — not you, and not the API server.

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.internal.example:5000 \
  --docker-username=deploy \
  --docker-password='...' \
  --docker-email=deploy@example.com
```

`docker-registry` is a **built-in Secret type** (`kubernetes.io/dockerconfigjson`)
whose single key is `.dockerconfigjson` — the same structure as
`~/.docker/config.json`.

Two ways to use it:

```yaml
# (a) on the pod -- explicit, per workload
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: app
      image: registry.internal.example:5000/team/app:1.4
```

```yaml
# (b) on the ServiceAccount -- automatic for every pod that uses it
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
imagePullSecrets:
  - name: regcred
```

**(b) is the one worth knowing.** Attach the secret to the `default`
ServiceAccount in a namespace and every pod there gets it without a single line
of workload YAML — the `ServiceAccount` admission controller merges it in, the
same mechanism that mounted a token in [CKA 16](../16-service-accounts/).

**A Secret is namespaced.** `regcred` in `prod` does nothing for a pod in `dev`;
you copy it into each namespace that needs it.

### 17.4 What a container can do: namespaces and capabilities

A container is **not** a virtual machine. It shares the host's kernel and is
separated by **namespaces** — PID, network, mount, user, IPC, UTS. Inside its PID
namespace the container's process is PID 1; on the host it is an ordinary process
with an ordinary PID. **Same process, two numbers.**

The second mechanism is **capabilities**. Historically root could do everything;
Linux split "everything" into ~40 discrete privileges:

| Capability | Permits |
|---|---|
| `CHOWN` | change file ownership |
| `NET_BIND_SERVICE` | bind ports below 1024 |
| `SYS_TIME` | **set the system clock** |
| `SYS_ADMIN` | an enormous grab-bag; effectively root |
| `NET_ADMIN` | configure interfaces, routes, iptables |
| `KILL` | signal any process |

**A container runtime drops most of them by default.** That is why `root` inside
a container cannot reboot the host: it is root without the capabilities that
would make root dangerous.

> **`privileged: true` gives all capabilities back**, plus access to host
> devices, and effectively removes the boundary. It is occasionally necessary —
> a CNI plugin, a storage driver — and is otherwise the thing a security review
> exists to find.

### 17.5 `securityContext` at two levels

```yaml
spec:
  securityContext:            # POD level -- applies to every container
    runAsUser: 1001
    fsGroup: 2000
  containers:
    - name: web
      securityContext:        # CONTAINER level -- wins for this container
        runAsUser: 1002
        capabilities:
          add: ["NET_BIND_SERVICE"]
          drop: ["ALL"]
```

**The container-level setting overrides the pod-level one**, field by field. A
field set only at the pod level still applies; a field set at both takes the
container's value. In the example above `web` runs as `1002` and every other
container in the pod runs as `1001`.

**Not every field exists at both levels**, and knowing which is which saves you
a failed `apply`:

| Field | Pod | Container | Effect |
|---|---|---|---|
| `runAsUser` / `runAsGroup` | yes | yes | UID / GID of the process |
| `runAsNonRoot` | yes | yes | **refuse to start** if the image would run as UID 0 |
| `fsGroup` | **yes** | no | GID applied to mounted volumes |
| `supplementalGroups` | **yes** | no | extra GIDs |
| `sysctls` | **yes** | no | kernel parameters |
| `capabilities` | no | **yes** | add / drop Linux capabilities |
| `allowPrivilegeEscalation` | no | **yes** | can a child gain more privilege than its parent |
| `readOnlyRootFilesystem` | no | **yes** | mount `/` read-only |
| `privileged` | no | **yes** | remove the boundary |
| `seccompProfile` | yes | yes | syscall filter |

Three of these deserve more than a table row:

**`runAsNonRoot: true`** does not *choose* a user — it **refuses to run** a
container whose effective UID is 0. If the image has no `USER` instruction, the
pod fails with `CreateContainerConfigError` before the process ever starts. That
is the desired behaviour: a policy that fails closed.

**`allowPrivilegeEscalation: false`** sets the kernel's `no_new_privs` bit. A
setuid binary inside the container can no longer gain privilege — which
neutralises a whole class of container escape, and costs nothing for almost every
application.

**`readOnlyRootFilesystem: true`** is the highest-value single field here.
Malware that cannot write to disk is dramatically less useful. Applications that
need scratch space get an `emptyDir` mounted at `/tmp`, which is a two-line
change and leaves the rest of the filesystem immutable.

The hardened baseline, worth memorising as a block:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

### 17.6 Pod Security Admission

`securityContext` is what a workload *declares*. **Pod Security Admission** is
what the cluster *enforces* — built in since 1.25, replacing the removed
PodSecurityPolicy.

It is configured with **labels on a namespace**, and nothing else:

```bash
kubectl label namespace prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31
```

Three levels:

| Level | Allows |
|---|---|
| `privileged` | everything — no restrictions |
| `baseline` | blocks the well-known escapes: `privileged`, host namespaces, hostPath, most added capabilities |
| `restricted` | baseline **plus** requires `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, and a seccomp profile |

and three modes, which can be set independently:

| Mode | Effect |
|---|---|
| `enforce` | reject the pod |
| `audit` | allow, record in the audit log |
| `warn` | allow, print a warning to the user's terminal |

**`warn` first, `enforce` later** is the rollout path — the same argument as
`ValidatingAdmissionPolicy`'s `Warn` binding in
[CKA 07](../07-admission-controllers/).

> **PSA enforces at pod creation only.** Labelling a namespace `restricted` does
> not evict the pods already running there; it stops the *next* one. Check what
> would break with `--dry-run=server` before you enforce.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka17
kubectl config set-context --current --namespace=cka17
```

### Step 1: Image names resolve to the same thing

```bash
kubectl apply -f solution/01-image-name-forms.yaml
kubectl wait --for=condition=Ready pod --all -n cka17 --timeout=120s
kubectl get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

The spec keeps whatever you typed. The **node** does not:

```bash
kubectl get pods -o custom-columns=NAME:.metadata.name,IMAGE_ID:.status.containerStatuses[0].imageID
```

```
name-short             docker.io/library/nginx@sha256:...
name-with-account      docker.io/library/nginx@sha256:...
name-fully-qualified   docker.io/library/nginx@sha256:...
name-other-registry    registry.k8s.io/pause@sha256:...
```

**Three different strings, one identical digest.** The fourth is a genuinely
different image from a different registry — and note that it *had* to be written
in full, because there is no shorthand for anything outside Docker Hub.

Confirm on the node itself:

```bash
docker exec devops-worker crictl images | grep -E "nginx|pause"
```

### Step 2: A pull that fails, and why

```bash
kubectl apply -f solution/02-private-image-BAD.yaml
sleep 20
kubectl get pod needs-credentials
kubectl describe pod needs-credentials | grep -A8 Events
```

```
Failed to pull image "registry.internal.example:5000/team/app:1.4":
  failed to resolve reference: ... no such host
Warning  Failed  ErrImagePull
Normal   BackOff  Back-off pulling image
```

Two states to distinguish, because they mean different things:

| Status | Meaning |
|---|---|
| `ErrImagePull` | **the most recent attempt failed** — read the message |
| `ImagePullBackOff` | it has failed repeatedly and the kubelet is now waiting between retries |

`ImagePullBackOff` is not a separate fault; it is `ErrImagePull` plus patience.
**Always read the `Failed` event, not the status column** — the status is the
same whether the registry is unreachable, the tag does not exist, or the
credentials are wrong.

### Step 3: Create and inspect a pull secret

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.internal.example:5000 \
  --docker-username=deploy \
  --docker-password='s3cr3t' \
  --docker-email=deploy@example.com

kubectl get secret regcred -o jsonpath='{.type}{"\n"}'
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

```json
{"auths":{"registry.internal.example:5000":{"username":"deploy","password":"s3cr3t",
 "email":"deploy@example.com","auth":"ZGVwbG95OnMzY3IzdA=="}}}
```

**The password is right there, base64 and nothing more** — `auth` is just
`username:password` encoded ([Day 10](../../days/day-10-secrets/) made this point
about Secrets generally; here it is a registry credential). This is one of the
Secrets that most deserves encryption at rest
([CKA 09](../09-encryption-at-rest/)).

Now use it and watch the error change:

```bash
kubectl apply -f solution/03-imagepullsecret-pod.yaml
sleep 20
kubectl describe pod has-credentials | grep -A6 Events
```

The registry is still imaginary so it still fails — but **the kubelet now tries
to authenticate**, which you can see in the message. That difference is how you
tell "no credentials" from "wrong credentials" in a real incident.

### Step 4: Attach the secret to the ServiceAccount

The form worth memorising:

```bash
kubectl apply -f solution/04-serviceaccount-pullsecret.yaml
kubectl get sa default -o jsonpath='{.imagePullSecrets}{"\n"}'

kubectl run inherits --image=registry.internal.example:5000/team/app:1.4 --restart=Never
sleep 5
kubectl get pod inherits -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
```

```
[{"name":"regcred"}]
```

**You never wrote that.** The pod named no pull secret; the `ServiceAccount`
admission controller merged it in — exactly as it injected `serviceAccountName`
and the token volume in [CKA 16](../16-service-accounts/).

Equivalent one-liner for the exam:

```bash
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

```bash
kubectl delete pod inherits needs-credentials has-credentials --ignore-not-found
```

### Step 5: `imagePullPolicy: Never`

```bash
kubectl apply -f solution/05-pullpolicy.yaml
sleep 10
kubectl get pod never-pull
```

```
NAME         READY   STATUS               RESTARTS   AGE
never-pull   0/1     ErrImageNeverPull    0          10s
```

**A distinct status**, and a fast one — no registry was contacted at all. This is
what a typo in an image name looks like after
`kind load docker-image` ([Day 08](../../days/day-08-build-and-load-app-images/)).

Check the defaults, which nobody writes down:

```bash
kubectl run t1 --image=nginx:1.27-alpine --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
kubectl run t2 --image=nginx --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
```

`IfNotPresent` for the pinned tag, **`Always`** for the unpinned one (17.2). The
API server filled that in — you can see the defaulting happen with
`--dry-run=server` and not with `--dry-run=client`.

```bash
kubectl delete pod never-pull --ignore-not-found
```

### Step 6: Who am I inside the container?

```bash
kubectl run ubuntu-sleeper --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/ubuntu-sleeper --timeout=60s
kubectl exec ubuntu-sleeper -- id
```

```
uid=0(root) gid=0(root) groups=0(root),...
```

**Root by default**, because the image declares no `USER`. Now look at the same
process from the node:

```bash
NODE=$(kubectl get pod ubuntu-sleeper -o jsonpath='{.spec.nodeName}')
docker exec $NODE sh -c "ps aux | grep '[s]leep 3600'"
```

Same process, **different PID** — the PID namespace from 17.4, visible in two
commands. It also shows as `root` on the host, which is precisely why
capabilities exist: this is root *without* the capabilities that make root
dangerous.

```bash
kubectl delete pod ubuntu-sleeper --force --grace-period=0 2>/dev/null
```

### Step 7: Pod level versus container level

```bash
kubectl apply -f solution/06-securitycontext-levels.yaml
kubectl wait --for=condition=Ready pod/multi-context --timeout=60s

kubectl exec multi-context -c web     -- id
kubectl exec multi-context -c sidecar -- id
```

```
uid=1002 gid=3000 groups=2000,3000        <- web: container override
uid=1001 gid=3000 groups=2000,3000        <- sidecar: inherited from the pod
```

Three things in two lines of output:

- **`runAsUser` differs** — the container-level value won for `web` only.
- **`runAsGroup` is 3000 for both** — set only at the pod level, so both inherit.
- **`2000` appears in `groups` for both** — that is `fsGroup`, which exists
  *only* at the pod level (17.5) and cannot be overridden per container.

And what `fsGroup` is actually for:

```bash
kubectl exec multi-context -c web -- ls -ld /data
```

```
drwxrwsrwx  2 root 2000 ... /data
```

**The volume is group-owned by 2000** and carries the setgid bit, so a process
running as 1001 or 1002 can write to it without being root. That is the entire
purpose of the field — and the reason
[CKA 10](../10-multi-container-and-init/)'s "init container that `chown`s the
volume" is usually the wrong answer when `fsGroup` will do.

### Step 8: `runAsNonRoot` fails closed

```bash
kubectl apply -f solution/07-runasnonroot-BAD.yaml
sleep 10
kubectl get pod nonroot-fails
kubectl describe pod nonroot-fails | grep -A4 "State\|Message"
```

```
STATUS: CreateContainerConfigError
Error: container has runAsNonRoot and image will run as root
```

**The container never started.** Not a crash, not an exit code — the kubelet
inspected the image, saw it would run as UID 0, and refused. A policy that fails
closed, and a status worth recognising on sight: `CreateContainerConfigError`
means the kubelet rejected the *configuration*, which also covers a missing
ConfigMap or Secret reference.

```bash
kubectl apply -f solution/08-runasnonroot-fixed.yaml
kubectl wait --for=condition=Ready pod/nonroot-works --timeout=60s
kubectl logs nonroot-works
```

```
uid=1000 gid=0(root) groups=0(root)
```

### Step 9: Capabilities

```bash
kubectl apply -f solution/09-capabilities.yaml
kubectl wait --for=condition=Ready pod/capabilities-demo --timeout=60s
```

All three containers run as root. Ask each to do something only a capability
allows — `date -s` needs `SYS_TIME`:

```bash
kubectl exec capabilities-demo -c default-caps -- date -s "12:00:00" 2>&1 | tail -1
kubectl exec capabilities-demo -c added-caps   -- date -s "12:00:00" 2>&1 | tail -1
kubectl exec capabilities-demo -c no-caps      -- date -s "12:00:00" 2>&1 | tail -1
```

```
date: can't set date: Operation not permitted     <- root, but no SYS_TIME
Thu Aug 20 12:00:00 UTC 2026                      <- SYS_TIME added: it worked
date: can't set date: Operation not permitted     <- dropped ALL
```

**The middle container changed the clock.** All three are `uid=0`; the
difference is entirely capabilities (17.4). This is the clearest available
demonstration that "root in a container" is not one thing.

Read the actual capability sets from the node:

```bash
NODE=$(kubectl get pod capabilities-demo -o jsonpath='{.spec.nodeName}')
docker exec $NODE sh -c 'for p in $(pgrep sleep); do echo "PID $p:"; grep CapEff /proc/$p/status; done'
```

Different `CapEff` bitmasks for the same image and the same UID.

### Step 10: A read-only root filesystem

```bash
kubectl apply -f solution/10-readonly-rootfs.yaml
kubectl wait --for=condition=Ready pod/readonly-root --timeout=60s

kubectl exec readonly-root -- sh -c 'echo test > /evil.sh' 2>&1 | tail -1
kubectl exec readonly-root -- sh -c 'echo test > /tmp/ok && cat /tmp/ok'
```

```
sh: can't create /evil.sh: Read-only file system
test
```

**`/` is immutable, `/tmp` is writable**, and the difference is one `emptyDir`.
Combined with `drop: ["ALL"]` and `allowPrivilegeEscalation: false`, a process
that gets code execution here has very little left to work with.

### Step 11: Pod Security Admission

```bash
kubectl create namespace cka17-restricted
kubectl label namespace cka17-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31 \
  pod-security.kubernetes.io/warn=restricted
```

Try the privileged pod in the **unlabelled** namespace first:

```bash
sed 's/cka17-restricted/cka17/' solution/12-privileged-BAD.yaml | kubectl apply -f -
kubectl get pod privileged-pod -n cka17
kubectl delete pod privileged-pod -n cka17
```

It runs. Now the same pod in the labelled one:

```bash
kubectl apply -f solution/12-privileged-BAD.yaml
```

```
Error from server (Forbidden): error when creating "...": pods "privileged-pod" is
forbidden: violates PodSecurity "restricted:v1.31": privileged (container "app"
must not set securityContext.privileged=true), allowPrivilegeEscalation != false,
unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

**Identical YAML, opposite outcome — the only difference is two labels on a
namespace.** And read the message: it lists **every** violation at once, not the
first. That is deliberate, so you can fix a workload in one pass.

Now the hardened Deployment, which satisfies all of them:

```bash
kubectl apply -f solution/11-hardened.yaml
kubectl rollout status deployment/hardened -n cka17-restricted --timeout=90s
kubectl logs -n cka17-restricted -l app=hardened
```

```
uid=1000 gid=3000 groups=3000
```

Compare `solution/11-hardened.yaml` against that error message line by line —
each rejected item has a corresponding field.

**Check before you enforce**, which is the operational half of this:

```bash
kubectl label --overwrite namespace cka17 \
  pod-security.kubernetes.io/warn=restricted
kubectl apply -f solution/09-capabilities.yaml
```

```
Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false...
pod/capabilities-demo configured
```

**Warned, not blocked.** That is the rollout path from 17.6 — turn on `warn`,
collect the complaints, fix the workloads, then switch to `enforce`.

Prove the "existing pods are not evicted" point:

```bash
kubectl label --overwrite namespace cka17 pod-security.kubernetes.io/enforce=restricted
kubectl get pods -n cka17          # still Running
kubectl delete pod capabilities-demo -n cka17
kubectl apply -f solution/09-capabilities.yaml    # now rejected
```

**PSA gates admission, not runtime.** Labelling a busy namespace `enforce` is
safe until something restarts — and then it is not, which is why the check above
matters.

### Cleanup

```bash
kubectl delete namespace cka17 cka17-restricted --ignore-not-found
kubectl config set-context --current --namespace=default
```

---

## Part 3 - Challenges

### C1 - Harden a workload

Given:

```yaml
spec:
  containers:
    - name: api
      image: mycorp/api:latest
      ports: [{containerPort: 80}]
```

Rewrite it to pass `restricted` Pod Security Admission. The application listens
on port **80** and writes cache files to `/var/cache/api`. Say what you did
about each of those two facts and why the obvious answer to the port is wrong.

### C2 - Diagnose four pull failures

For each, give the single most likely cause and the command that confirms it:

1. `ErrImagePull`: `pull access denied, repository does not exist or may require authorization`
2. `ErrImagePull`: `no such host`
3. `ErrImageNeverPull`
4. The pod pulled successfully in `dev` and gets `ImagePullBackOff` in `prod`,
   same image, same tag, same cluster.

### C3 - Root, but not really

A colleague says "the container runs as root, so it can do anything the host's
root can do — containers are not a security boundary."

Give the two-command demonstration that they are partly wrong, name the specific
mechanism, and then say the one thing about their claim that is **correct** and
what you would use if you needed a real boundary.

### C4 - Which level?

For each field, say whether it can be set at pod level, container level, or
both — and, where it is both, what happens when they disagree:

`fsGroup`, `capabilities`, `runAsUser`, `readOnlyRootFilesystem`, `sysctls`,
`seccompProfile`, `privileged`, `runAsNonRoot`

Then explain why `capabilities` is container-only while `fsGroup` is pod-only —
there is a reason, and it is the same reason in both cases.

### C5 - Enforce without an outage

You must move a busy production namespace to `enforce=restricted`. Twelve
Deployments run there and you did not write any of them.

Give the procedure, in order, including the command that tells you what would
break **before** anything does, and identify the moment at which a workload you
failed to fix will actually fail — it is not when you apply the label.

---

## Part 4 - Verify

```bash
bash solution/verify.sh
```

Checks: the three image-name forms resolved to one digest; the `regcred` Secret
has the right type and decodes to the expected registry; the `default`
ServiceAccount carries the pull secret; `multi-context` shows 1002/1001 with a
shared fsGroup; `nonroot-fails` never started; the `added-caps` container has
`SYS_TIME` and `no-caps` has none; the hardened Deployment is Running in a
`restricted` namespace and the privileged pod does not exist there.

---

## Part 5 - Exam notes

**Fast paths**

```bash
# pull secret, and attach it to every pod in a namespace
kubectl create secret docker-registry regcred \
  --docker-server=REG --docker-username=U --docker-password=P
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'

# read a pull secret back
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

# who does this container run as, right now
kubectl exec POD -c NAME -- id
kubectl get pod POD -o jsonpath='{.spec.securityContext}{"\n"}{.spec.containers[*].securityContext}{"\n"}'

# find everything privileged in the cluster
kubectl get pods -A -o json | jq -r '.items[] |
  select(.spec.containers[]?.securityContext?.privileged==true) |
  "\(.metadata.namespace)/\(.metadata.name)"'

# Pod Security Admission
kubectl label namespace NS pod-security.kubernetes.io/enforce=restricted
kubectl label namespace NS pod-security.kubernetes.io/warn=restricted
kubectl label --overwrite namespace NS pod-security.kubernetes.io/enforce=privileged   # back out

# would this be rejected? ask without creating it
kubectl apply -f pod.yaml --dry-run=server
```

**Traps**

- **`nginx` is `docker.io/library/nginx:latest`.** Any other registry must be
  written in full; `registry.k8s.io` has no shorthand.
- **`imagePullPolicy` defaults by tag:** `Always` for `latest` or no tag,
  `IfNotPresent` otherwise.
- **`ImagePullBackOff` is not a cause**, it is `ErrImagePull` plus retries. Read
  the `Failed` event.
- **Pull secrets are namespaced.** Copy them into every namespace that needs one.
- **`imagePullSecrets` on the ServiceAccount** applies to every pod using it —
  the answer to "without editing 40 Deployments".
- **Container-level `securityContext` beats pod-level**, field by field.
- **`fsGroup`, `supplementalGroups` and `sysctls` are pod-only.**
  **`capabilities`, `privileged`, `readOnlyRootFilesystem` and
  `allowPrivilegeEscalation` are container-only.** Putting one in the wrong place
  is rejected by the API server.
- **`runAsNonRoot: true` does not pick a UID.** Without `runAsUser`, an image
  that would run as root gives `CreateContainerConfigError`.
- **Capability names have no `CAP_` prefix here** — `SYS_TIME`, not
  `CAP_SYS_TIME`.
- **`drop: ["ALL"]` then `add: [...]`** is the idiom; `add` is applied after
  `drop`.
- **PSA is three labels and three modes**, and it gates **admission only** —
  existing pods keep running.
- `restricted` requires `runAsNonRoot`, `allowPrivilegeEscalation: false`,
  `drop: ["ALL"]` **and** `seccompProfile: RuntimeDefault`. Forgetting the
  seccomp profile is the usual reason a "hardened" pod is still rejected.

---

**Previous:** [CKA 16 — Service Accounts and Tokens](../16-service-accounts/)
**Next:** [CKA 18 — Network Policies](../18-network-policies/)
