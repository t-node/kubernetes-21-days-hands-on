# Day 09 — ConfigMaps

**Time:** 75-90 minutes
**Prerequisites:** Day 08

Yesterday the backend had its database URL hardcoded in the Deployment. Today
you pull configuration out into ConfigMaps — and use one to solve a real problem
the DevBoard image creates: the backend Service name being baked into the
frontend.

---

## Part 1 - Concepts

### 9.1 Why externalise configuration

The [Twelve-Factor](https://12factor.net/config) rule: **config lives in the
environment, not in code**. The same image should run in dev, staging and
production with only its environment differing.

Bake config into an image and you get a rebuild per config change, one image per
environment, and secrets in image layers forever.

| Object | For | Stored |
|---|---|---|
| **ConfigMap** | non-sensitive config | plain text in etcd |
| **Secret** | passwords, tokens, keys | base64 in etcd (Day 10) |

Nearly identical APIs. The split is about *intent*, which then lets RBAC,
encryption-at-rest and audit policy treat them differently.

**The dividing line:** would you paste it into a public Slack channel? Yes →
ConfigMap. No → Secret.

### 9.2 What a ConfigMap looks like

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: devboard-config
  namespace: devboard
data:
  # scalars -> good as env vars
  PORT: "8080"
  POSTGRES_HOST: "postgres"
  POSTGRES_DB: "devboard"

  # a whole file -> good as a volume mount
  vite.config.js: |
    export default { preview: { proxy: { ... } } }
```

**The rule that catches everyone:** every value under `data` must be a
**string**:

```yaml
data:
  PORT: 8080          # WRONG - YAML parses this as an integer
```

```
cannot convert int64 to string
```

Quote it: `PORT: "8080"`. Same for `true`, `false`, `yes`, `no`, `on`, `off` and
anything resembling a version number.

### 9.3 The two ways to consume one — and they are NOT equivalent

The most important table in today's material.

| | **As environment variables** | **As a mounted volume** |
|---|---|---|
| How | `configMapKeyRef` or `envFrom` | `volumes.configMap` + `volumeMounts` |
| Result | `PORT=8080` in the process env | files in a directory, one per key |
| Live updates? | **Never.** Env is fixed at `execve()` | **Yes**, within ~60 s |
| Suits | small scalar settings | config files, certificates |
| Missing key | pod fails to start | same |

**"Env vars never update" is the single most-asked ConfigMap question.** A Linux
process's environment is set when it is exec'd and cannot be changed from
outside. Update the ConfigMap and running pods keep the old values forever.

The fix is `kubectl rollout restart`. Better, make it automatic by hashing the
ConfigMap into a pod-template annotation, so any change produces a new revision:

```yaml
spec:
  template:
    metadata:
      annotations:
        checksum/config: "a3f9c2..."
```

**Volume mounts DO update**, with caveats:
- the kubelet syncs on its own period (~60 s), so it is not instant
- your **application must notice** — watch the file, or expose a reload signal
- **`subPath` mounts never update.** Ever. This one costs people hours.

### 9.4 envFrom: import every key at once

```yaml
envFrom:
  - configMapRef:
      name: devboard-config
```

Every key becomes an env var of the same name. Concise, and adding a key needs
no Deployment change. The costs: keys that are not valid env var names are
**silently skipped**, and the Deployment no longer documents its own inputs.
`prefix:` can namespace them.

**Careful with this app:** if you put both scalars and a whole `vite.config.js`
file in one ConfigMap and `envFrom` it, you get an environment variable
containing an entire JavaScript file. Harmless, but it is why this course keeps
file-shaped keys in a **separate ConfigMap** from scalar keys.

### 9.5 Precedence

`envFrom` entries apply in list order, then `env` entries override them. Both
override anything from the image's `ENV`. The useful pattern: `envFrom` a shared
ConfigMap for defaults, then `env` to override one value.

### 9.6 The DevBoard problem ConfigMaps solve today

From Day 08: `http://backend:8080` is compiled into the frontend image, so the
backend Service must be named `backend`. What if you cannot use that name —
because another team owns it, or your convention demands `devboard-backend`?

You **mount a replacement `/app/vite.config.js` from a ConfigMap.** The image
keeps its baked-in file on disk; your mount shadows it. No rebuild, no fork.

That is the general pattern, and it is worth naming: **when an image hardcodes
something you need to change, mount over it.** It is how you configure nginx,
Prometheus, Fluent Bit, Envoy and almost every off-the-shelf image in
Kubernetes.

### 9.7 Limits

- **1 MiB per ConfigMap** (an etcd limit).
- **Namespaced** — a pod can only reference one in its own namespace.
- **Not secret.** Anyone with `get configmap` reads everything.
- Deleting one in use does not kill running pods, but any pod that restarts
  afterwards fails with `CreateContainerConfigError`.

---

## Part 2 - Hands-on lab

### Step 1: Create a ConfigMap four ways

```bash
mkdir -p scratch/day09 && cd scratch/day09
```

**a) From literals:**

```bash
kubectl create configmap demo-literal -n devboard \
  --from-literal=POSTGRES_HOST=postgres \
  --from-literal=PORT=8080
kubectl get configmap demo-literal -n devboard -o yaml
```

Note that `PORT=8080` works here — the CLI treats everything as a string. It is
only YAML that needs the quotes.

**b) From a file** — the key becomes the filename:

```bash
cp ../../app/devboard/frontend/vite.preview.config.js ./vite.config.js
kubectl create configmap demo-file -n devboard --from-file=vite.config.js
kubectl get configmap demo-file -n devboard -o yaml | head -20
```

**c) From an env-file** — one key per line:

```bash
kubectl create configmap demo-envfile -n devboard \
  --from-env-file=../../app/devboard/.env.example
kubectl get configmap demo-envfile -n devboard -o yaml
```

That is the real `.env.example`, turned into a ConfigMap in one command.
Compare (b) and (c): `--from-file` makes **one key holding a whole file**;
`--from-env-file` makes **one key per line**. Choosing wrong gives you a single
env var containing your entire config.

**d) From a manifest** — the one you commit:

```bash
cd ../..
kubectl apply -f days/day-09-configmaps/solution/01-configmap.yaml
kubectl describe configmap devboard-config -n devboard
```

### Step 2: Wire the backend to the ConfigMap

The Go backend reads exactly two variables: `PORT` and `POSTGRES_URL`. The
second is a DSN containing a password, so today it stays hardcoded and Day 10
rebuilds it properly. Everything else comes from the ConfigMap:

```bash
kubectl apply -f days/day-09-configmaps/solution/02-backend-deployment.yaml
kubectl rollout status deployment/backend -n devboard

kubectl exec -n devboard deploy/backend -- env | sort | grep -E 'PORT|POSTGRES'
```

The pods will still CrashLoop — there is no Postgres until Day 11. Read the
config off a pod that is briefly up, or use:

```bash
kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n'
```

### Step 3: The main event — override the vite proxy target

Right now the frontend can only talk to a Service named `backend`. Change that
without touching the image.

First, prove the current state:

```bash
kubectl exec -n devboard deploy/frontend -- cat /app/vite.config.js
```

```js
preview: { proxy: { "/api": { target: "http://backend:8080", ... } } }
```

Now create a Service under a different name, and mount a config that points at
it:

```bash
kubectl apply -f days/day-09-configmaps/solution/03-backend-service-renamed.yaml
kubectl apply -f days/day-09-configmaps/solution/04-vite-config-configmap.yaml
kubectl apply -f days/day-09-configmaps/solution/05-frontend-deployment-mounted.yaml
kubectl rollout status deployment/frontend -n devboard

kubectl exec -n devboard deploy/frontend -- cat /app/vite.config.js
```

```js
preview: { proxy: { "/api": { target: "http://devboard-backend:8080", ... } } }
```

**The image is unchanged. The file it reads is not.** This is the single most
useful trick for running third-party images in Kubernetes.

Look at how it is mounted:

```yaml
volumeMounts:
  - name: vite-config
    mountPath: /app/vite.config.js
    subPath: vite.config.js        # <- REQUIRED here, and it has consequences
```

`subPath` is necessary because mounting the *directory* `/app` would replace the
whole thing, hiding `dist/` and `node_modules/` and breaking the container
entirely. The cost, from section 9.3: **this file will never live-update.**
Changing the ConfigMap requires a `rollout restart`. That is an acceptable
trade here, and knowing *why* it is a trade is the point.

### Step 4: Prove env vars do NOT live-update

The exercise that makes the concept permanent.

```bash
kubectl apply -f days/day-09-configmaps/solution/06-demo-envtest.yaml
kubectl wait --for=condition=Ready pod/envtest -n devboard --timeout=60s

kubectl exec -n devboard envtest -- env | grep DEMO_SETTING
# DEMO_SETTING=original

kubectl patch configmap devboard-config -n devboard \
  -p '{"data":{"DEMO_SETTING":"changed"}}'

kubectl get configmap devboard-config -n devboard \
  -o jsonpath='{.data.DEMO_SETTING}{"\n"}'        # changed

sleep 75
kubectl exec -n devboard envtest -- env | grep DEMO_SETTING
# DEMO_SETTING=original    <- the POD never changed
```

Meanwhile the same key mounted as a **file** in that same pod did change:

```bash
kubectl exec -n devboard envtest -- cat /config/DEMO_SETTING; echo
# changed
```

One pod, one ConfigMap, two consumption styles, two completely different
behaviours. That contrast is the whole lesson.

```bash
kubectl delete pod envtest -n devboard
```

### Step 5: Look at how a mounted ConfigMap is laid out

```bash
kubectl apply -f solution/06-demo-envtest.yaml
kubectl exec -n devboard envtest -- ls -la /config
```

```
lrwxrwxrwx  ... DEMO_SETTING -> ..data/DEMO_SETTING
drwxr-xr-x  ... ..2026_08_20_11_04_31.123456789
lrwxrwxrwx  ... ..data -> ..2026_08_20_11_04_31.123456789
```

Your files are **symlinks** into a timestamped directory. That is how updates
are atomic: the kubelet writes a whole new directory and swaps the `..data`
symlink in one operation, so your app never reads a half-written config set.

It is also exactly why **`subPath` mounts never update** — `subPath`
bind-mounts the single file and bypasses the symlink entirely.

```bash
kubectl delete pod envtest -n devboard
```

### Step 6: The automatic-restart pattern

```bash
HASH=$(kubectl get configmap devboard-config -n devboard -o yaml | sha256sum | cut -c1-16)

kubectl patch deployment backend -n devboard -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$HASH\"}}}}}"
```

Change the ConfigMap, recompute, patch — the annotation changes, the pod
template changes, a rolling update happens. Helm writes this with `sha256sum`;
Kustomize does it better with `configMapGenerator`, which appends a content hash
to the ConfigMap **name**:

```yaml
configMapGenerator:
  - name: devboard-config
    literals:
      - POSTGRES_HOST=postgres
```

produces `devboard-config-7t2k9bd5hf`, so changing content changes the name,
which changes the Deployment's reference, which triggers a rollout — and keeps
the old ConfigMap around for rollback.

### Step 7: Restore the standard naming

Later days assume the Service is called `backend`, so put it back:

```bash
kubectl delete -f solution/03-backend-service-renamed.yaml --ignore-not-found
kubectl apply  -f ../day-08-build-and-load-app-images/solution/02-backend-service.yaml
kubectl apply  -f ../day-08-build-and-load-app-images/solution/03-frontend-deployment.yaml
kubectl rollout status deployment/frontend -n devboard
```

Keep `solution/04-vite-config-configmap.yaml` in mind — Day 20 revisits it,
because once an Ingress does the `/api` routing, the vite proxy stops mattering
at all.

---

## Validate

```bash
kubectl apply -f solution/01-configmap.yaml
kubectl apply -f solution/02-backend-deployment.yaml

kubectl get configmap devboard-config -n devboard \
  -o jsonpath='{.data.POSTGRES_HOST}{"\n"}'                 # postgres

kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}{"\n"}'

# the override still works when applied
kubectl apply -f solution/04-vite-config-configmap.yaml
kubectl apply -f solution/05-frontend-deployment-mounted.yaml
kubectl apply -f solution/03-backend-service-renamed.yaml
kubectl rollout status deployment/frontend -n devboard --timeout=90s
kubectl exec -n devboard deploy/frontend -- grep -o 'http://[a-z-]*:8080' /app/vite.config.js
# http://devboard-backend:8080
```

Ready for Day 10 when you can:

1. State the two consumption styles and the behavioural difference.
2. Explain why env vars cannot update in a running process.
3. Explain why `subPath` was required here and what it costs.
4. Say what `data: PORT: 8080` does, unquoted.

---

## Break it

**A. An unquoted number.**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bad-types
  namespace: devboard
data:
  PORT: 8080
EOF
# error: cannot convert int64 to string
```

**B. Mount the directory instead of using subPath.**

```bash
kubectl patch deployment frontend -n devboard --type=json -p \
'[{"op":"replace","path":"/spec/template/spec/containers/0/volumeMounts/0","value":{"name":"vite-config","mountPath":"/app"}}]'

kubectl get pods -n devboard -l app=frontend
kubectl logs -n devboard -l app=frontend --tail=10
```

The container dies immediately: mounting at `/app` replaced the directory, so
`node_modules/.bin/vite` no longer exists. Read the error — it is a plain
"command not found" style failure, and recognising that a *volume mount* caused
it is the skill.

```bash
kubectl apply -f solution/05-frontend-deployment-mounted.yaml
```

**C. Reference a key that does not exist.**

```bash
kubectl patch deployment backend -n devboard --type=json -p \
'[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"MISSING","valueFrom":{"configMapKeyRef":{"name":"devboard-config","key":"NOPE"}}}}]'

kubectl get pods -n devboard -l app=backend        # CreateContainerConfigError
kubectl describe pod -n devboard -l app=backend | grep -i "couldn't find key"
kubectl rollout undo deployment/backend -n devboard
```

**D. Delete a ConfigMap that is in use.**

```bash
kubectl delete configmap devboard-config -n devboard
kubectl get pods -n devboard -l app=frontend        # still Running!

kubectl delete pod -n devboard -l app=frontend --wait=false
sleep 10
kubectl get pods -n devboard -l app=frontend        # CreateContainerConfigError
kubectl apply -f solution/01-configmap.yaml
```

Running pods are unaffected — they already have the values. The damage appears
the next time a pod starts, which might be at 3 a.m. during an unrelated node
drain. A genuinely nasty class of latent failure.

---

## Interview questions

<details>
<summary><b>1. What is a ConfigMap and how do you consume one?</b></summary>

A namespaced object holding non-sensitive configuration as key/value string
pairs. Pods consume it as individual environment variables via
`configMapKeyRef`, as all keys at once via `envFrom`, or as files via a volume
mount. Command arguments can also reference it through `$(VAR)` substitution.
</details>

<details>
<summary><b>2. If you update a ConfigMap, do running pods see the change?</b></summary>

It depends entirely on how it is consumed. Environment variables never update -
a process's environment is fixed at exec time. Volume-mounted files do update
within roughly a kubelet sync period, but the application must notice the change
itself. `subPath` mounts never update. The general fix is
`kubectl rollout restart`, ideally automated with a content hash in a pod
template annotation.
</details>

<details>
<summary><b>3. Why do volume-mounted ConfigMaps use symlinks?</b></summary>

For atomicity. The kubelet writes a new timestamped directory with all keys,
then swaps the `..data` symlink in one operation, so the application never sees
a partially updated set of files. `subPath` bypasses this by bind-mounting a
single file, which is why subPath mounts do not update.
</details>

<details>
<summary><b>4. An off-the-shelf image hardcodes a hostname you cannot use. What do you do?</b></summary>

Mount over the file. Put the corrected configuration in a ConfigMap and mount it
at the exact path the image reads, using `subPath` so you replace one file
rather than an entire directory. No rebuild and no fork. If the setting is only
available as an env var, override it in the pod spec; if it is compiled into a
binary with no config file at all, you fall back to matching the name the image
expects - which is why the Service in this course is called `backend`.
</details>

<details>
<summary><b>5. Why did mounting at /app break the container, and how would you have predicted it?</b></summary>

A volume mounted at a directory path replaces that directory's contents for the
container - the image's own files at that path become invisible. `/app` held
`dist/` and `node_modules/`, so the vite binary disappeared. Predict it by
asking what else lives at the mount path; when the answer is "things the image
needs", use `subPath` to replace a single file instead.
</details>

<details>
<summary><b>6. ConfigMap size limits?</b></summary>

About 1 MiB, imposed by etcd. Larger configuration belongs in a volume, an
object store, or an init container that fetches it. Every ConfigMap a pod mounts
is also held in the kubelet's memory on that node.
</details>

<details>
<summary><b>7. How do you make a config change trigger a rollout automatically?</b></summary>

Hash the ConfigMap contents into a pod template annotation so any content change
alters the template and produces a new ReplicaSet. Helm uses a
`checksum/config` annotation; Kustomize's `configMapGenerator` appends a content
hash to the ConfigMap name, which changes the Deployment's reference and
additionally preserves the old version for rollback.
</details>

<details>
<summary><b>8. Can a pod use a ConfigMap from another namespace?</b></summary>

No. ConfigMaps are namespaced and a pod may only reference ones in its own
namespace. Sharing means duplicating - through deployment tooling, a GitOps
sync, or a mirroring controller such as Reflector.
</details>

<details>
<summary><b>9. A pod is in CreateContainerConfigError. What is wrong?</b></summary>

Almost always a referenced ConfigMap or Secret that does not exist, or a key
missing from one. `kubectl describe pod` names the exact object and key. Unlike
CrashLoopBackOff the container never started, so there are no logs to read.
</details>

---

## Cheat card

```bash
# create
kubectl create configmap cm --from-literal=K=V -n devboard
kubectl create configmap cm --from-file=vite.config.js -n devboard
kubectl create configmap cm --from-file=dir/ -n devboard          # every file in dir
kubectl create configmap cm --from-env-file=.env -n devboard
kubectl create configmap cm --from-literal=K=V --dry-run=client -o yaml

# inspect
kubectl get configmaps -n devboard
kubectl describe configmap devboard-config -n devboard
kubectl get configmap devboard-config -n devboard -o jsonpath='{.data.POSTGRES_HOST}'

# update
kubectl patch configmap devboard-config -n devboard -p '{"data":{"K":"V"}}'
kubectl create configmap cm --from-file=f --dry-run=client -o yaml | kubectl apply -f -

# make pods see it
kubectl rollout restart deployment/backend -n devboard

# verify from inside the pod
kubectl exec -n devboard deploy/backend  -- env | sort
kubectl exec -n devboard deploy/frontend -- cat /app/vite.config.js
```

| Consumption | Live update | Use for |
|---|---|---|
| `configMapKeyRef` | never | a few explicit settings |
| `envFrom` | never | many settings, terse |
| volume mount (directory) | yes, ~60 s | config files |
| volume mount + `subPath` | **never** | one file into a directory you must not replace |

---

**Next: [Day 10 - Secrets](../day-10-secrets/)**
