# CKA 03 solution

```bash
bash build.sh
kubectl apply -f 01-four-combinations.yaml
```

| File | Demonstrates |
|---|---|
| `ubuntu-sleeper/Dockerfile` | `ENTRYPOINT ["sleep"]` + `CMD ["5"]` |
| `01-four-combinations.yaml` | the full truth table, one pod per row |
| `02-unquoted-number.yaml` | rejected: `args: [5000]` must be `["5000"]` |
| `03-quoted-number.yaml` | the fix, and the immutability exercise pod |
| `04-shell-form.yaml` | shell form makes `sh` PID 1 and breaks SIGTERM |

## Exam-style task answers

### 1. `timer` sleeping 1200s using args only (2 min)

```bash
kubectl run timer --image=ubuntu-sleeper:1.0 \
  --image-pull-policy=IfNotPresent -- 1200
```

Everything after `--` becomes `args`, so the image's `ENTRYPOINT ["sleep"]` is
kept and only `CMD` is replaced. Verify:

```bash
kubectl get pod timer -o jsonpath='{.spec.containers[0].args}{"\n"}'   # ["1200"]
```

### 2. `echoer` running `echo hello-cka` (2 min)

```bash
kubectl run echoer --image=ubuntu-sleeper:1.0 \
  --image-pull-policy=IfNotPresent --command -- echo hello-cka
```

`--command` is required. Without it those words become *args* and you would run
`sleep echo hello-cka`, which fails.

```bash
kubectl logs echoer          # hello-cka
```

### 3. Change a running pod from 1200s to 60s, no manifest (3 min)

`args` is not editable in place, so:

```bash
kubectl edit pod timer
#   change "1200" to "60", save
#   -> Forbidden, but: "A copy of your changes has been stored to
#      /tmp/kubectl-edit-1234.yaml"

kubectl replace --force -f /tmp/kubectl-edit-*.yaml
kubectl get pod timer -o jsonpath='{.spec.containers[0].args}{"\n"}'   # ["60"]
```

Or without the failed edit at all:

```bash
kubectl get pod timer -o yaml > /tmp/timer.yaml
sed -i 's/"1200"/"60"/' /tmp/timer.yaml
kubectl replace --force -f /tmp/timer.yaml
```

**The trick worth remembering:** `kubectl edit` saves your edits to `/tmp` even
when the update is rejected. That file is the fix.

### 4. Truth table, no cluster (2 min)

Image: `ENTRYPOINT ["python", "app.py"]`, `CMD ["--color", "red"]`.

**Pod sets `args: ["--color","blue"]`** → args replaces CMD, ENTRYPOINT kept:

```
python app.py --color blue
```

**Pod sets `command: ["python","app2.py"]` instead** → command replaces
ENTRYPOINT, and because no `args` is given the image's CMD is **discarded**:

```
python app2.py
```

Not `python app2.py --color red`. That is the row-three trap: the colour
argument silently disappears.

### 5. CrashLoopBackOff, exit 0, no logs (1 min)

Exit **0** means it succeeded, so nothing crashed:

1. **The container's process finished by design** — a one-shot command, or an
   interactive shell such as `bash` with no TTY attached. If it is genuinely
   meant to run once, it belongs in a **Job**, not a Deployment, or needs
   `restartPolicy: OnFailure`/`Never`.
2. **`command` was overridden and the image's `CMD` was discarded**, so the
   entrypoint ran with no arguments and exited immediately.

Both are pod-spec problems, not application bugs. `kubectl get pod -o yaml` and
compare `command`/`args` against the image's defaults:

```bash
docker inspect <image> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'
```

---

## The six answers

1. **`command` overrides `ENTRYPOINT`; `args` overrides `CMD`.** The names
   suggest the opposite pairing, which is why this is the most common mistake.

2. **Setting `command` without `args` discards the image's `CMD` entirely.**
   Kubernetes does not merge your entrypoint with the image's default
   arguments. If you override `command`, supply `args` too.

3. **`CMD ["sleep 5"]`** is a one-element array, so the runtime looks for an
   executable literally named `sleep 5`. Each element must be a separate string:
   the executable first, then one argument per element.

4. **YAML parses unquoted `5000` as an integer**, and `command`/`args` are
   string arrays, so the API server rejects it with "cannot unmarshal number
   into Go struct field ... of type string".

5. **The five mutable pod fields:** `spec.containers[*].image`,
   `spec.initContainers[*].image`, `spec.activeDeadlineSeconds`,
   `spec.tolerations` (additions only), and
   `spec.terminationGracePeriodSeconds`. The error message lists them, so you
   never need to memorise it — just read it.

6. **`kubectl replace --force` deletes and recreates the object.** New UID, new
   IP, and a service gap. Acceptable for a bare pod. For anything managed, edit
   the controller and let a rolling update do it safely.

---

## Carry this to the exam

**Two habits.**

When a container exits and the logs are empty, compare the pod spec's
`command`/`args` against the image's `ENTRYPOINT`/`CMD` before anything else:

```bash
kubectl get pod X -o jsonpath='{.spec.containers[0].command}{" "}{.spec.containers[0].args}{"\n"}'
docker inspect <image> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'
```

And when told to change a running pod, remember the `/tmp` file:

```bash
kubectl edit pod X                                   # fails, but saves
kubectl replace --force -f /tmp/kubectl-edit-*.yaml  # applies your edit
```
