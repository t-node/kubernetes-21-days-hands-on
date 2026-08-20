# CKA 03 — Commands and Arguments

**Time:** 60-75 minutes
**Prerequisites:** [Day 02](../../days/day-02-kubectl-and-your-first-pod/), [CKA 01](../02-container-runtimes-and-crictl/)

Two fields, `command` and `args`, that map onto two Dockerfile instructions,
`ENTRYPOINT` and `CMD` — **not in the order most people assume**. Getting this
wrong produces a container that starts and immediately exits, with a log that
says nothing useful.

The main track never covered this. It should have.

---

## Part 1 - Concepts

### 3.1 Why containers exit

Start here, because everything else follows from it.

```bash
docker run ubuntu
docker ps                # nothing
docker ps -a             # Exited (0) 2 seconds ago
```

**A container lives exactly as long as the process inside it.** Unlike a VM, it
is not hosting an operating system — it is running one task. When that task
finishes, the container is done.

`ubuntu`'s Dockerfile ends with `CMD ["bash"]`. Bash is a shell: it reads from a
terminal, and Docker attaches no terminal by default, so bash finds no input and
exits immediately. The container exits with it.

This is the mechanism behind a large share of `CrashLoopBackOff` incidents:
**the container did not crash — it succeeded and finished.** A `Completed`
status on something you expected to be a server is this.

### 3.2 ENTRYPOINT and CMD

Both name what runs at startup. They differ in how command-line input is
treated:

| | `ENTRYPOINT` | `CMD` |
|---|---|---|
| Role | the **executable** | the **default arguments** |
| Runtime input | **appended** to it | **replaces** it entirely |

```dockerfile
FROM ubuntu
ENTRYPOINT ["sleep"]
CMD ["5"]
```

| You run | Actually executed |
|---|---|
| `docker run ubuntu-sleeper` | `sleep 5` |
| `docker run ubuntu-sleeper 10` | `sleep 10` — appended to ENTRYPOINT, replacing CMD |
| `docker run --entrypoint sleep2 ubuntu-sleeper 10` | `sleep2 10` |

With **only** `CMD ["sleep", "5"]` and no ENTRYPOINT, `docker run img 10` would
try to execute a program literally called `10`, because CMD is replaced wholesale
rather than appended to.

**Two array rules that bite:**

```dockerfile
CMD ["sleep", "5"]        # correct: executable, then each argument separately
CMD ["sleep 5"]           # WRONG: looks for a binary named "sleep 5"
CMD sleep 5               # shell form -- runs via /bin/sh -c
```

The shell form wraps your command in `/bin/sh -c`, which means **PID 1 becomes
the shell, not your process**, and signals go to the shell instead of your
application. That is why a container ignores `SIGTERM` and takes the full
30-second grace period to die on every rollout. **Use the exec (JSON array) form
in anything you deploy.**

### 3.3 The mapping — the whole point of this day

```
Dockerfile ENTRYPOINT   <--- overridden by --->   pod spec  command
Dockerfile CMD          <--- overridden by --->   pod spec  args
```

> **Read that again.** It is *not* `command` overriding `CMD`, despite the
> name looking like it should. `command` maps to `ENTRYPOINT`. `args` maps to
> `CMD`. The naming is genuinely unhelpful and it is the single most common
> mistake with these fields.

The complete truth table for an image with `ENTRYPOINT ["sleep"]` and
`CMD ["5"]`:

| Pod spec | Runs | Why |
|---|---|---|
| *(neither)* | `sleep 5` | both image defaults used |
| `args: ["10"]` | `sleep 10` | args replaces CMD; ENTRYPOINT kept |
| `command: ["sleep2"]` | `sleep2` | **CMD is DISCARDED** — see below |
| `command: ["sleep2"]`<br>`args: ["10"]` | `sleep2 10` | both replaced |

**Row three is the trap.** Supplying `command` without `args` throws away the
image's `CMD` entirely — Kubernetes does not merge your entrypoint with the
image's default arguments. A container that ran fine suddenly starts with no
arguments and exits with "operand missing" or similar.

If you override `command`, you almost always need to supply `args` too.

### 3.4 Everything under command and args must be a string

```yaml
command: ["sleep"]
args: ["5000"]        # quoted
```

Unquoted, YAML parses `5000` as an integer and the API server rejects it:

```
cannot unmarshal number into Go struct field Container.spec.containers.command
of type string
```

Same family as Day 09's `cannot convert int64 to string` for ConfigMaps, a
different message. **Quote every numeric value in YAML** and you never meet
either.

### 3.5 Pods are almost entirely immutable

Try to change a running pod's `command` and the API server refuses:

```
Pod "x" is invalid: spec: Forbidden: pod updates may not change fields other
than `spec.containers[*].image`, `spec.initContainers[*].image`,
`spec.activeDeadlineSeconds`, `spec.tolerations` (only additions to existing
tolerations), `spec.terminationGracePeriodSeconds`
```

**That error message is a complete list of what you may change on a live pod.**
Everything else — command, args, env, resources, volumes, probes — requires
replacing the pod.

Three ways out, worst to best:

```bash
# 1. edit, let it fail, then force-replace from the temp file it saved
kubectl edit pod mypod
#    -> "edits saved to /tmp/kubectl-edit-xxxxx.yaml"
kubectl replace --force -f /tmp/kubectl-edit-xxxxx.yaml

# 2. dump, edit, replace
kubectl get pod mypod -o yaml > pod.yaml
vi pod.yaml
kubectl replace --force -f pod.yaml

# 3. edit YOUR manifest in git and re-apply  <-- do this
vi pod.yaml && kubectl apply -f pod.yaml
```

`kubectl replace --force` **deletes and recreates** the object. New pod, new UID,
new IP, and a gap in service. Fine for a bare pod; for anything real you change
the Deployment and let a rolling update handle it.

> Option 1 is worth knowing specifically for the exam, where you are often given
> a running pod and told to change it, with no manifest to hand. Recognise the
> "edits saved to /tmp/..." line — that file is your fix.

---

## Part 2 - Hands-on lab

### Step 1: See a container exit because it finished

```bash
kubectl run exits-immediately --image=ubuntu -n default
sleep 8
kubectl get pod exits-immediately
kubectl describe pod exits-immediately | grep -A4 "Last State"
```

`Completed`, then `CrashLoopBackOff` — because `restartPolicy: Always` restarts
anything that exits, even successfully.

**Exit Code: 0.** Nothing crashed. Bash found no terminal and finished, so the
container finished. Recognising exit code 0 on a `CrashLoopBackOff` saves you
from hunting a bug that does not exist.

```bash
kubectl delete pod exits-immediately
```

### Step 2: Build the demonstration image

```bash
bash solution/build.sh
```

That builds and `kind load`s an image whose Dockerfile is exactly section 3.2:

```dockerfile
FROM ubuntu:22.04
ENTRYPOINT ["sleep"]
CMD ["5"]
```

Confirm the Docker behaviour before touching Kubernetes:

```bash
time docker run --rm ubuntu-sleeper:1.0            # ~5s   -> sleep 5
time docker run --rm ubuntu-sleeper:1.0 10         # ~10s  -> sleep 10
docker run --rm --entrypoint echo ubuntu-sleeper:1.0 hello
```

### Step 3: Prove the truth table

```bash
kubectl apply -f solution/01-four-combinations.yaml
sleep 5
kubectl get pods -l demo=cmdargs
```

Four pods, one per row of the table in 3.3. Read what each actually runs:

```bash
for p in sleeper-defaults sleeper-args sleeper-command sleeper-both; do
  printf "%-20s command=%-22s args=%s\n" "$p" \
    "$(kubectl get pod $p -o jsonpath='{.spec.containers[0].command}')" \
    "$(kubectl get pod $p -o jsonpath='{.spec.containers[0].args}')"
done
```

Then the effective process, from inside each:

```bash
for p in sleeper-defaults sleeper-args sleeper-command sleeper-both; do
  printf "%-20s -> %s\n" "$p" "$(kubectl exec $p -- cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')"
done
```

| Pod | `/proc/1/cmdline` |
|---|---|
| `sleeper-defaults` | `sleep 5` |
| `sleeper-args` | `sleep 10` |
| `sleeper-command` | `sleep` — **no argument** |
| `sleeper-both` | `sleep 60` |

`sleeper-command` is section 3.3's row three, live: overriding `command` alone
discarded the image's `CMD`. Watch it fail for that exact reason:

```bash
kubectl get pod sleeper-command
kubectl logs sleeper-command
# sleep: missing operand
```

**The image was fine. The pod spec removed its arguments.** That failure mode —
"it worked in Docker, it fails in Kubernetes" — is almost always this.

```bash
kubectl delete -f solution/01-four-combinations.yaml
```

### Step 4: The string trap

```bash
kubectl apply -f solution/02-unquoted-number.yaml
```

```
cannot unmarshal number into Go struct field Container.spec.containers.args
of type string
```

Quote it and it applies:

```bash
kubectl apply -f solution/03-quoted-number.yaml
kubectl get pod sleeper-quoted
kubectl delete pod sleeper-quoted
```

### Step 5: Hit pod immutability, then work around it

```bash
kubectl apply -f solution/03-quoted-number.yaml
kubectl edit pod sleeper-quoted
```

Change `args` from `"5000"` to `"2000"` and save. It refuses:

```
pod updates may not change fields other than `spec.containers[*].image` ...
```

But look at the last line of the output:

```
A copy of your changes has been stored to "/tmp/kubectl-edit-1234.yaml"
```

**That file has your edit in it.** Use it:

```bash
kubectl replace --force -f /tmp/kubectl-edit-*.yaml
kubectl get pod sleeper-quoted -o jsonpath='{.spec.containers[0].args}{"\n"}'
```

Note what `--force` did — `kubectl get pod -w` in another terminal would show
the old pod terminating and a new one being created. Different UID, different
IP. Confirm:

```bash
kubectl get pod sleeper-quoted -o jsonpath='{.metadata.uid}{"\n"}'
```

Now prove which field *is* mutable:

```bash
kubectl set image pod/sleeper-quoted sleeper=ubuntu:24.04
kubectl get pod sleeper-quoted -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

That one is allowed in place — it is on the list in the error message.

```bash
kubectl delete pod sleeper-quoted
```

### Step 6: kubectl run, and the `--` separator

`kubectl run` has its own flags, and so does the program inside the container.
`--` separates them.

```bash
# everything AFTER -- becomes args (ENTRYPOINT kept)
kubectl run r1 --image=ubuntu-sleeper:1.0 --image-pull-policy=IfNotPresent -- 30
kubectl get pod r1 -o jsonpath='{.spec.containers[0].args}{"\n"}'      # ["30"]

# --command makes it command instead (ENTRYPOINT replaced)
kubectl run r2 --image=ubuntu-sleeper:1.0 --image-pull-policy=IfNotPresent \
  --command -- sleep 45
kubectl get pod r2 -o jsonpath='{.spec.containers[0].command}{"\n"}'   # ["sleep","45"]

kubectl delete pod r1 r2
```

Read `--image-pull-policy=IfNotPresent` and `--command` as *kubectl's* flags —
they come **before** `--`. Everything after `--` goes to the container.

And the generator form you will actually use under time pressure:

```bash
kubectl run r3 --image=ubuntu-sleeper:1.0 --command -- sleep 45 \
  --dry-run=client -o yaml
```

Redirect that to a file, edit, apply. On the exam this beats typing a pod
manifest from memory every time.

---

## Validate

```bash
bash solution/build.sh
kubectl apply -f solution/01-four-combinations.yaml
sleep 6

kubectl get pod sleeper-both -o jsonpath='{.spec.containers[0].command}{" "}{.spec.containers[0].args}{"\n"}'
# ["sleep"] ["60"]

kubectl logs sleeper-command 2>&1 | grep -i "operand"     # missing operand
kubectl delete -f solution/01-four-combinations.yaml
```

You are done when you can answer, without looking:

1. Which pod field overrides `ENTRYPOINT`? Which overrides `CMD`?
2. What happens to the image's `CMD` if you set `command` but not `args`?
3. Why does `CMD ["sleep 5"]` fail while `CMD ["sleep", "5"]` works?
4. Why must `args: [5000]` be quoted?
5. Name the five pod fields you may change in place.
6. What does `kubectl replace --force` actually do to the object?

---

## Break it

**A. Shell form makes PID 1 the shell.**

```bash
kubectl apply -f solution/04-shell-form.yaml
sleep 5
kubectl exec shell-form -- cat /proc/1/cmdline | tr '\0' ' '; echo
```

PID 1 is `/bin/sh -c sleep 300`, not `sleep`. Now watch the consequence:

```bash
time kubectl delete pod shell-form
```

It takes the **full 30-second grace period**. `SIGTERM` went to the shell, which
does not forward it, so the kubelet waited and then `SIGKILL`ed. Compare:

```bash
kubectl apply -f solution/03-quoted-number.yaml
sleep 5
time kubectl delete pod sleeper-quoted        # near-instant
```

This is why Day 13's graceful shutdown work matters, and why **exec form is not
a style preference** — it is the difference between a 2-second and a 30-second
rolling update per pod.

**B. Forget the `--` separator.**

```bash
kubectl run bad --image=ubuntu-sleeper:1.0 --image-pull-policy=IfNotPresent 30
```

`kubectl` tries to parse `30` as its own argument and errors. Without `--`
there is no way for it to know the argument was meant for the container.

**C. Override `command` on a real application.**

```bash
kubectl run broken-fe --image=devboard-frontend:1.0 \
  --image-pull-policy=IfNotPresent --command -- /bin/sh
sleep 8
kubectl get pod broken-fe
kubectl delete pod broken-fe
```

The frontend image's `CMD` starts `vite preview`. Replacing `command` discarded
it, so the container runs a shell with no terminal and exits. **A perfectly good
image, broken entirely by the pod spec** — and `kubectl logs` shows nothing at
all, which is what makes it hard.

**D. Try to change something immutable on a Deployment's pod.**

```bash
kubectl edit pod -n devboard $(kubectl get pod -n devboard -l app=backend -o name | head -1 | cut -d/ -f2)
```

Change `args` and save — forbidden, same as a bare pod. But here **do not**
reach for `replace --force`: the pod belongs to a ReplicaSet, so edit the
**Deployment** and let the rolling update replace it properly.

```bash
kubectl set env deployment/backend -n devboard DEMO=1
kubectl rollout status deployment/backend -n devboard
kubectl set env deployment/backend -n devboard DEMO-
```

**Knowing which object to edit is the actual skill.** Bare pod: replace it.
Managed pod: edit its controller.

---

## Exam-style tasks

Timed. No looking things up first.

1. Create a pod `timer` from `ubuntu-sleeper:1.0` that sleeps for **1200**
   seconds, using `args` only. *(2 min)*
2. Create a pod `echoer` from the same image that runs `echo hello-cka`
   instead of sleeping. *(2 min)*
3. A running pod `timer` sleeps 1200s. Change it to 60s without deleting the
   manifest — you were not given one. *(3 min)*
4. Given a Dockerfile with `ENTRYPOINT ["python", "app.py"]` and
   `CMD ["--color", "red"]`, and a pod spec setting `args: ["--color","blue"]` —
   what runs? What if the pod spec set `command: ["python","app2.py"]` instead?
   *(2 min, no cluster needed)*
5. A pod is `CrashLoopBackOff` with exit code 0 and empty logs. Give the two
   most likely causes. *(1 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```
Dockerfile ENTRYPOINT  <-- overridden by -->  pod  command
Dockerfile CMD         <-- overridden by -->  pod  args
```

```yaml
containers:
  - name: app
    image: ubuntu-sleeper:1.0
    command: ["sleep"]      # the EXECUTABLE   (ENTRYPOINT)
    args:    ["60"]         # the ARGUMENTS    (CMD)   -- quote numbers
```

| Pod sets | Image `ENTRYPOINT ["sleep"]`, `CMD ["5"]` runs |
|---|---|
| nothing | `sleep 5` |
| `args` only | `sleep <your args>` |
| `command` only | `<your command>` — **CMD discarded** |
| both | `<your command> <your args>` |

```bash
# imperative
kubectl run p --image=img -- arg1 arg2              # sets ARGS
kubectl run p --image=img --command -- cmd arg1     # sets COMMAND
kubectl run p --image=img --command -- cmd --dry-run=client -o yaml

# editing a live pod
kubectl edit pod p                                  # fails -> saves /tmp/kubectl-edit-*.yaml
kubectl replace --force -f /tmp/kubectl-edit-*.yaml # delete + recreate
kubectl set image pod/p c=img:2                     # allowed in place

# mutable on a live pod, and ONLY these:
#   spec.containers[*].image
#   spec.initContainers[*].image
#   spec.activeDeadlineSeconds
#   spec.tolerations              (additions only)
#   spec.terminationGracePeriodSeconds
```

**Exec form, always:** `["sleep", "5"]`, never `sleep 5` or `["sleep 5"]`.
Shell form makes the shell PID 1 and your app stops receiving `SIGTERM`.

---

**Previous:** [CKA 07 — Admission Controllers, Webhooks and CEL Policies](../07-admission-controllers/)
**Next:** [CKA 09 — Encrypting Secret Data at Rest](../09-encryption-at-rest/)

**Back to the [CKA track](../) · [Main course](../../README.md)**
