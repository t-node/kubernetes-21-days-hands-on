# CKA 04 — Imperative vs Declarative, and how `kubectl apply` really works

**Time:** 60-75 minutes
**Prerequisites:** [Day 02](../../days/day-02-kubectl-and-your-first-pod/)
**Source lectures:** 41, 43, 45, 46, 48

Two things live here, and both are exam-critical for opposite reasons.

**Speed:** the exam gives you three hours for a lot of tasks. Typing YAML from
memory loses. This assignment builds the imperative command vocabulary that
makes you fast.

**Correctness:** `kubectl apply` does a **three-way merge** that `create` and
`replace` do not, and mixing the two approaches silently corrupts objects. Most
people use `apply` for a year without knowing what the third way is.

---

## Part 1 - Concepts

### 4.1 The two approaches

**Imperative** — say *what to do and how*:

```bash
kubectl run nginx --image=nginx
kubectl create deployment web --image=nginx --replicas=3
kubectl edit deployment web
kubectl scale deployment web --replicas=5
```

**Declarative** — say *what the end state is*, let the system work out the steps:

```bash
kubectl apply -f manifest.yaml
```

The taxi analogy is the clearest one: imperative is giving turn-by-turn
directions; declarative is naming the destination and letting the driver route.

| | Imperative | Declarative |
|---|---|---|
| Speed to type | **fast** | slow |
| Repeatable | no | **yes** |
| Reviewable in a PR | no | **yes** |
| Handles "already exists" | errors | **fine** |
| Records intent anywhere | no | **in git** |
| Right for | **the exam**, quick fixes, generating YAML | **everything real** |

> **Use both, deliberately.** Imperative to *generate*, declarative to *keep*:
>
> ```bash
> kubectl create deployment web --image=nginx --dry-run=client -o yaml > web.yaml
> vi web.yaml && kubectl apply -f web.yaml
> ```
>
> That is the workflow to internalise. You get imperative speed and a file you
> can commit.

### 4.2 Three commands, three behaviours

| Command | If it does not exist | If it does exist |
|---|---|---|
| `kubectl create -f` | creates | **error** — already exists |
| `kubectl replace -f` | **error** — not found | **replaces wholesale** |
| `kubectl apply -f` | creates | **merges** |

`replace --force` deletes and recreates (CKA 08). `apply` is the only one that is
safe to run repeatedly, which is why every GitOps tool uses it.

### 4.3 The three-way merge — what `apply` actually compares

This is the part that is worth the assignment.

When you `kubectl apply`, three versions of the object are consulted:

```
   1. LOCAL FILE                 what you have on disk right now
   2. LIVE OBJECT                what is in etcd, including status and defaults
   3. LAST-APPLIED-CONFIGURATION what you applied the PREVIOUS time
```

The third is stored **on the live object**, as an annotation:

```
kubectl.kubernetes.io/last-applied-configuration
```

Why is it needed? Because comparing local against live cannot tell you the
difference between **"I removed this field"** and **"someone else added it"**.

Consider a label:

| Local file | Last-applied | Live | Conclusion | Action |
|---|---|---|---|---|
| absent | **present** | present | *you deleted it* | **remove from live** |
| absent | absent | present | *something else set it* | **leave it alone** |
| present | either | different | *you changed it* | **update live** |

**That middle row is why the annotation exists.** Fields set by other
controllers — an HPA's `replicas`, a mutating webhook's sidecar, a
`defaultRequest` from a LimitRange — survive your `apply` untouched, because
they never appeared in your last-applied.

> ### The rule that follows
>
> **`create` and `replace` do not write the last-applied annotation.**
>
> So if you create an object with `create -f`, then later `apply -f` the same
> file, the first apply has no last-applied to compare against and cannot detect
> deletions. Fields you removed stay on the live object, sometimes for months.
>
> **Pick one approach per object and stay with it.**

### 4.4 The imperative vocabulary worth memorising

These generate correct YAML in one line. `--dry-run=client -o yaml` turns any of
them into a file.

```bash
# pods
kubectl run nginx --image=nginx
kubectl run nginx --image=nginx --port=80
kubectl run nginx --image=nginx --env=KEY=value
kubectl run nginx --image=nginx --labels=app=web,tier=front
kubectl run busybox --image=busybox --restart=Never -- sleep 3600
kubectl run tmp --image=busybox --rm -it --restart=Never -- sh

# deployments
kubectl create deployment web --image=nginx --replicas=3
kubectl create deployment web --image=nginx --port=80
kubectl scale deployment web --replicas=5
kubectl set image deployment/web nginx=nginx:1.27
kubectl set env deployment/web LOG=debug
kubectl set resources deployment/web --limits=cpu=200m,memory=256Mi

# services  -- two routes, and they differ
kubectl expose deployment web --port=80 --target-port=8080
kubectl expose pod nginx --port=80 --name=nginx-svc --type=NodePort
kubectl create service clusterip redis --tcp=6379:6379

# config
kubectl create configmap app-config --from-literal=KEY=value
kubectl create configmap app-config --from-file=config.properties
kubectl create secret generic app-secret --from-literal=PASSWORD=s3cr3t

# namespaces, jobs, rbac
kubectl create namespace dev
kubectl create job hello --image=busybox -- echo hi
kubectl create cronjob hello --image=busybox --schedule="*/1 * * * *" -- echo hi
kubectl create role dev --verb=get,list --resource=pods
kubectl create rolebinding dev-rb --role=dev --user=jane
kubectl create serviceaccount ci
```

**`expose` vs `create service`** is worth knowing precisely:

- **`kubectl expose`** reads the target's labels and builds the **selector for
  you**. Almost always what you want.
- **`kubectl create service`** takes no selector from anything — you get a
  Service whose selector is `app: <name>`, which may match nothing.

`expose` is the one that will not leave you with empty endpoints.

### 4.5 `kubectl explain` — offline documentation

```bash
kubectl explain pod.spec.containers
kubectl explain deployment.spec.strategy --recursive
kubectl explain pvc.spec.accessModes
```

It reads the **OpenAPI schema of your cluster**, so it is always correct for the
version you are on. In an exam where you may browse the docs but every second
counts, this is faster than the website.

### 4.6 Exam speed setup

Do this in the first sixty seconds of the exam:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"      # k run x --image=y $do > x.yaml
export now="--force --grace-period=0"     # k delete pod x $now
source <(kubectl completion bash)
complete -o default -F __start_kubectl k

kubectl config set-context --current --namespace=<the-question's-namespace>
```

And in `~/.vimrc`, so YAML indents correctly:

```
set expandtab tabstop=2 shiftwidth=2
```

Those five lines pay for themselves several times over.

---

## Part 2 - Hands-on lab

```bash
kubectl create namespace cka04
kubectl config set-context --current --namespace=cka04
```

### Step 1: Generate rather than type

Time yourself. Write a Deployment manifest with 3 replicas, a named port and a
resource limit — **without opening an editor first**:

```bash
kubectl create deployment web --image=nginx:1.27-alpine --replicas=3 \
  --dry-run=client -o yaml > web.yaml
cat web.yaml
```

Now add what the generator cannot:

```bash
kubectl set resources -f web.yaml --local -o yaml \
  --limits=cpu=200m,memory=256Mi > web2.yaml && mv web2.yaml web.yaml
grep -A4 resources web.yaml
kubectl apply -f web.yaml
```

`--local` is the flag people miss: it edits the **file**, not the cluster. It
turns `kubectl set` into a YAML editor.

### Step 2: Watch the annotation appear

```bash
kubectl get deployment web -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | head -3
```

There it is — `kubectl.kubernetes.io/last-applied-configuration`, holding your
file as JSON. Read it:

```bash
kubectl get deployment web \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
  | python -m json.tool | head -25
```

Notice what is **not** there: no `status`, no `creationTimestamp`, no defaulted
fields. It is exactly what you sent — which is the whole point.

### Step 3: Prove the three-way merge

Add a label out-of-band, as another controller or teammate would:

```bash
kubectl label deployment web owner=platform-team
kubectl get deployment web --show-labels
```

Now re-apply your unchanged file:

```bash
kubectl apply -f web.yaml
kubectl get deployment web --show-labels
```

**`owner=platform-team` survived.** It was never in your last-applied, so `apply`
concluded it was not yours to remove. That is row two of the table in 4.3.

Now delete a label that **is** yours:

```bash
kubectl apply -f web.yaml                              # baseline
sed -i '/app: web/!b' web.yaml                         # (no-op, keeps file valid)
kubectl label deployment web tier=frontend --overwrite
python - <<'PY'
import io,re
s=io.open("web.yaml",encoding="utf-8").read()
s=s.replace("  labels:\n    app: web\n","  labels:\n    app: web\n    tier: frontend\n",1)
io.open("web.yaml","w",encoding="utf-8").write(s)
PY
kubectl apply -f web.yaml                              # now tier IS in last-applied

python - <<'PY'
import io
s=io.open("web.yaml",encoding="utf-8").read().replace("    tier: frontend\n","",1)
io.open("web.yaml","w",encoding="utf-8").write(s)
PY
kubectl apply -f web.yaml
kubectl get deployment web --show-labels
```

**`tier=frontend` is gone, `owner=platform-team` remains.** One removed, one
preserved, from the same `apply`. The annotation is what told them apart.

### Step 4: Break it by mixing approaches

```bash
kubectl delete deployment web
kubectl create -f web.yaml                             # CREATE, not apply
kubectl get deployment web -o jsonpath='{.metadata.annotations}' | tr ',' '\n'
```

**No last-applied annotation.** Now add a label to the file and apply:

```bash
python - <<'PY'
import io
s=io.open("web.yaml",encoding="utf-8").read()
s=s.replace("  labels:\n    app: web\n","  labels:\n    app: web\n    added: yes\n",1)
io.open("web.yaml","w",encoding="utf-8").write(s)
PY
kubectl apply -f web.yaml
```

```
Warning: resource deployments/web is missing the
kubectl.kubernetes.io/last-applied-configuration annotation which is required by
kubectl apply. kubectl apply should only be used on resources created
declaratively... will be patched automatically.
```

**Kubernetes warns you explicitly.** It recovers here, but the first apply had
nothing to diff against, so any field you had *removed* before this point stayed
on the live object silently.

### Step 5: `replace` is not `apply`

```bash
kubectl get deployment web -o yaml > live.yaml
python - <<'PY'
import io
s=io.open("live.yaml",encoding="utf-8").read().replace("replicas: 3","replicas: 1",1)
io.open("live.yaml","w",encoding="utf-8").write(s)
PY
kubectl replace -f live.yaml
kubectl get deployment web
```

`replace` overwrites the whole object with what you sent. If your file were
stale — missing a field another controller added — that field is **gone**, with
no merge and no warning. `apply` would have preserved it.

### Step 6: Build the whole app imperatively, then capture it

The exam-shaped drill. No editor, four commands:

```bash
kubectl create deployment api --image=nginx:1.27-alpine --replicas=2
kubectl expose deployment api --port=80 --target-port=80 --name=api-svc
kubectl create configmap api-config --from-literal=LOG_LEVEL=debug
kubectl set env deployment/api --from=configmap/api-config

kubectl get deploy,svc,cm
kubectl get endpoints api-svc          # populated -- expose built the selector
```

Now convert it all to files you could commit:

```bash
mkdir -p captured
for r in deployment/api service/api-svc configmap/api-config; do
  kubectl get $r -o yaml > captured/$(echo $r | tr '/' '-').yaml
done
ls captured/
```

Those dumps carry `status`, `uid`, `resourceVersion` and cluster defaults — they
are a **snapshot, not a manifest**. For real use, regenerate cleanly:

```bash
kubectl create deployment api --image=nginx:1.27-alpine --replicas=2 \
  --dry-run=client -o yaml > captured/clean-deployment.yaml
```

### Step 7: `explain` instead of the browser

```bash
kubectl explain deployment.spec.strategy
kubectl explain pod.spec.containers.livenessProbe
kubectl explain pod.spec.securityContext --recursive | head -20
kubectl explain pvc.spec.accessModes
```

Answer these using only `explain`:

- What are the valid values of `deployment.spec.strategy.type`?
- What is the default `terminationGracePeriodSeconds`?
- Which field sets a container's working directory?

---

## Validate

```bash
kubectl config set-context --current --namespace=cka04

# the annotation exists on applied objects
kubectl apply -f solution/deployment.yaml
kubectl get deployment web \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
  | head -c 60; echo

# out-of-band labels survive apply
kubectl label deployment web probe=survives --overwrite
kubectl apply -f solution/deployment.yaml
kubectl get deployment web -o jsonpath='{.metadata.labels.probe}{"\n"}'   # survives

# generate a manifest without an editor
kubectl create deployment gen --image=nginx --dry-run=client -o yaml | head -5
```

You are done when you can, without looking anything up:

1. Generate a Deployment manifest with 3 replicas in one command.
2. Explain what the three inputs to `kubectl apply` are.
3. Say why a field you removed from your file might survive on the live object.
4. Say what `create` and `replace` do **not** write, and why it matters.
5. Expose a Deployment as a NodePort in one command.

---

## Break it

**A. Apply a file that was created with `create`.**

Done in Step 4. The warning is the lesson — note that it names the annotation
explicitly.

**B. `create` twice.**

```bash
kubectl create -f solution/deployment.yaml
kubectl create -f solution/deployment.yaml
# Error: deployments.apps "web" already exists
kubectl apply -f solution/deployment.yaml
kubectl apply -f solution/deployment.yaml       # fine, twice, forever
```

Idempotence is not a detail — it is why `apply` is the only command a CI
pipeline can safely run.

**C. `create service` where you meant `expose`.**

```bash
kubectl create deployment lonely --image=nginx:alpine
kubectl create service clusterip lonely --tcp=80:80
kubectl get endpoints lonely
```

`<none>`. `create service` set the selector to `app: lonely`, but
`create deployment` labelled its pods `app: lonely` too... check carefully:

```bash
kubectl get svc lonely -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods -l app=lonely --show-labels
```

They may match here by luck of naming. Try it with mismatched names and the
failure is immediate:

```bash
kubectl create service clusterip other --tcp=80:80
kubectl get endpoints other                      # <none>, guaranteed
kubectl delete svc other lonely; kubectl delete deploy lonely
```

**`expose` derives the selector from the object. `create service` guesses.**

**D. Apply a stale file over an HPA-managed Deployment.**

```bash
kubectl apply -f solution/deployment.yaml
kubectl autoscale deployment web --min=3 --max=6 --cpu-percent=80
sleep 20
kubectl get deployment web -o jsonpath='{.spec.replicas}{"\n"}'

kubectl apply -f solution/deployment.yaml        # file says replicas: 3
kubectl get deployment web -o jsonpath='{.spec.replicas}{"\n"}'
```

Because `replicas` **is** in your last-applied, `apply` enforces it and fights
the HPA — Day 17's warning, now with the mechanism behind it. The fix is to omit
`replicas` from the manifest entirely so it never enters last-applied.

```bash
kubectl delete hpa web
```

---

## Exam-style tasks

Speed matters here. Time yourself; the targets are tight on purpose.

1. Create a pod `nginx` with image `nginx:alpine` exposing port 80, in one
   command. *(30 s)*
2. Create a deployment `redis` with 4 replicas of `redis:alpine`, then expose it
   on port 6379. *(1 min)*
3. Generate — do not create — a manifest for a pod running `busybox` that sleeps
   3600 seconds, saved to `/tmp/sleeper.yaml`. *(1 min)*
4. Create a ConfigMap from a literal and wire every key into an existing
   deployment as environment variables. *(2 min)*
5. Using only `kubectl explain`, state the valid values of
   `deployment.spec.strategy.type`. *(1 min)*
6. A Deployment was created with `kubectl create -f`. Make it safe to manage
   with `apply` from now on. *(2 min)*

Answers in [`solution/`](solution/).

---

## Cheat card

```bash
# THE workflow: generate imperatively, keep declaratively
export do="--dry-run=client -o yaml"
kubectl create deployment web --image=nginx --replicas=3 $do > web.yaml
vi web.yaml && kubectl apply -f web.yaml

# edit a FILE, not the cluster
kubectl set resources -f web.yaml --local -o yaml --limits=cpu=200m

# generators
kubectl run NAME --image=IMG [--port=] [--env=K=V] [--labels=] [--restart=Never] [-- cmd args]
kubectl create deployment NAME --image=IMG --replicas=N
kubectl expose deployment NAME --port=80 --target-port=8080 --type=NodePort
kubectl create configmap NAME --from-literal=K=V | --from-file=F | --from-env-file=F
kubectl create secret generic NAME --from-literal=K=V
kubectl create job/cronjob/role/rolebinding/serviceaccount/namespace ...

# docs, offline and version-correct
kubectl explain deployment.spec.strategy --recursive
```

| Command | Missing | Existing | Writes last-applied |
|---|---|---|---|
| `create -f` | creates | **error** | **no** |
| `replace -f` | **error** | overwrites wholesale | **no** |
| `apply -f` | creates | **three-way merge** | **yes** |

**The three inputs to `apply`:** your **local file**, the **live object**, and
the **last-applied annotation**. The third is the only thing that can tell
"I deleted this" apart from "someone else added it".

---

**Next: [CKA 05 — Manual scheduling and static pods](../05-manual-scheduling-and-static-pods/)**
