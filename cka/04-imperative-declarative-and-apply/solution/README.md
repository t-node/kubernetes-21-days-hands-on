# CKA 04 solution

## Exam-style task answers

### 1. Pod with a port, one command (30 s)

```bash
kubectl run nginx --image=nginx:alpine --port=80
```

`--port` sets `containerPort`. It publishes nothing — that is a Service's job
(Day 06) — but it documents intent and can be referenced by name.

### 2. Deployment plus Service (1 min)

```bash
kubectl create deployment redis --image=redis:alpine --replicas=4
kubectl expose deployment redis --port=6379
```

`expose` reads the Deployment's labels and builds the selector, so endpoints
populate immediately. `--target-port` defaults to `--port`, which is correct
here since redis listens on 6379.

Verify:

```bash
kubectl get endpoints redis
```

### 3. Generate without creating (1 min)

```bash
kubectl run sleeper --image=busybox --restart=Never \
  --dry-run=client -o yaml -- sleep 3600 > /tmp/sleeper.yaml
cat /tmp/sleeper.yaml
```

Three things to get right: `--restart=Never` (a Pod, not a Deployment), the
`--` separator before the command (CKA 08), and `--dry-run=client` so nothing is
created.

### 4. ConfigMap into a Deployment's environment (2 min)

```bash
kubectl create configmap api-config --from-literal=LOG_LEVEL=debug --from-literal=MODE=prod
kubectl set env deployment/api --from=configmap/api-config
kubectl set env deployment/api --list
```

`--from=configmap/NAME` generates the `envFrom` block for you. For a single key
instead:

```bash
kubectl set env deployment/api --from=configmap/api-config --keys=LOG_LEVEL
```

### 5. Strategy values, using only explain (1 min)

```bash
kubectl explain deployment.spec.strategy.type
```

> Type of deployment. Can be "Recreate" or "RollingUpdate". Default is
> RollingUpdate.

`explain` reads your cluster's own OpenAPI schema, so it is always right for the
version in front of you — faster and safer than the website.

### 6. Make a `create`d Deployment safe for `apply` (2 min)

The problem: `create` writes no `last-applied-configuration`, so the first
`apply` has nothing to diff against and cannot detect deletions.

**Option A — let apply repair it (what actually happens):**

```bash
kubectl apply -f web.yaml
# Warning: ... is missing the kubectl.kubernetes.io/last-applied-configuration
# annotation ... will be patched automatically
```

It warns, then writes the annotation. Fine going forward, but any field you had
removed *before* this moment is still on the live object.

**Option B — set it explicitly, no warning:**

```bash
kubectl apply set-last-applied -f web.yaml --create-annotation=true
kubectl get deployment web \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | head -c 60
```

**Option C — the clean answer, if a moment of downtime is acceptable:**

```bash
kubectl delete -f web.yaml && kubectl apply -f web.yaml
```

Say which you would choose and why. Option B is the right answer when the object
is serving traffic.

---

## The five answers

1. `kubectl create deployment web --image=nginx --replicas=3 --dry-run=client -o yaml`

2. **The local file**, **the live object** in etcd, and the
   **last-applied-configuration annotation** stored on that live object.

3. Because it was never in your last-applied. `apply` treats a field that is
   absent from both your file and last-applied, but present live, as **someone
   else's** — an HPA, a webhook, a LimitRange — and leaves it. Only a field that
   *was* in last-applied and is now gone from your file gets removed.

4. They do not write the **last-applied annotation**. Mixing them with `apply`
   means the first apply cannot detect deletions, so removed fields silently
   persist on the live object.

5. `kubectl expose deployment NAME --port=80 --target-port=8080 --type=NodePort`

---

## Carry this to the exam

**Never type a manifest from scratch.** Every object has a generator:

```bash
export do="--dry-run=client -o yaml"
kubectl create deployment x --image=y $do > x.yaml
```

Then edit only the fields the generator cannot produce — probes, volumes,
affinity — and `apply`.

**And one rule that prevents a whole class of silent corruption:** pick
imperative *or* declarative per object and stay with it. If you `apply` it, only
ever `apply` it.
