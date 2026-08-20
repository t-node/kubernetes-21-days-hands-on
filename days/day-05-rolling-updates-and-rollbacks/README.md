# Day 05 — Rolling Updates, Rollbacks & Deployment Strategies

**Time:** 60-75 minutes
**Prerequisites:** Day 04 (`devboard-frontend` Deployment exists)

Yesterday you learned that a Deployment creates a new ReplicaSet when the pod
template changes. Today you control *how* that transition happens, and how to
undo it in one command when the new version is broken.

---

## Part 1 - Concepts

### 5.1 The problem

You have v1 running with 5 replicas. You want v2. The naive approaches both
fail:

- **Delete all, then create all** - your app is down for however long the new
  pods take to start. Unacceptable.
- **Create all, then delete all** - you need double the capacity for a while,
  and both versions serve traffic simultaneously with no control.

Kubernetes' default answer is the **rolling update**: replace pods a few at a
time, never dropping below a floor of available pods, never exceeding a ceiling
of total pods.

### 5.2 RollingUpdate, controlled by two numbers

```yaml
spec:
  replicas: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1      # never fewer than 5-1 = 4 pods available
      maxSurge: 1            # never more than 5+1 = 6 pods total
```

Both accept an absolute number or a percentage (`25%` is the default for each).

With `maxUnavailable: 1, maxSurge: 1` on 5 replicas:

```
start:   [v1 v1 v1 v1 v1]                     5 available
step 1:  [v1 v1 v1 v1 v1] + v2(starting)      6 total, 5 available
step 2:  [v1 v1 v1 v1] [v2]                   old one removed once v2 is Ready
step 3:  [v1 v1 v1 v1] [v2] + v2(starting)
...
end:     [v2 v2 v2 v2 v2]
```

The critical detail: **a new pod must become *Ready* before an old one is
removed.** "Ready" means its **readiness probe** passes (Day 13). Without a
readiness probe, Kubernetes considers a pod ready the moment the container
process starts — which for a Java app that takes 40 seconds to warm up means you
happily delete healthy old pods and route traffic to ones that cannot serve it.

> **A rolling update without a readiness probe is not a zero-downtime deploy.**
> It just looks like one in a demo. Remember this on Day 13.

Tuning the two numbers:

| Setting | Effect | Use when |
|---|---|---|
| `maxUnavailable: 0`, `maxSurge: 1` | never lose capacity; slowest | strict SLOs, spare capacity available |
| `maxUnavailable: 1`, `maxSurge: 1` | balanced (near the default) | most workloads |
| `maxUnavailable: 25%`, `maxSurge: 25%` | the default | general purpose |
| `maxUnavailable: 50%`, `maxSurge: 0` | fast, no extra capacity | tight clusters, tolerant apps |

`maxUnavailable: 0` **and** `maxSurge: 0` together is invalid — nothing could
ever change.

### 5.3 Recreate: the other built-in strategy

```yaml
spec:
  strategy:
    type: Recreate
```

Kill everything, then start the new version. There *is* downtime, deliberately.
Use it when:

- two versions must never run simultaneously (an incompatible DB schema change)
- the app takes a `ReadWriteOnce` volume that only one pod can mount
- it is a batch worker where a gap is harmless

### 5.4 The strategies Kubernetes does NOT give you natively

Interviewers love this distinction. Only `RollingUpdate` and `Recreate` are
built into a Deployment. Everything else is a pattern built on top:

| Strategy | What it is | How you actually do it |
|---|---|---|
| **Blue/Green** | two full environments; flip all traffic at once | two Deployments, switch the Service `selector` from `version: blue` to `version: green` |
| **Canary** | send a small share of traffic to the new version | two Deployments behind one Service with replica ratios (crude), or an ingress/service mesh with weighted routing (proper) |
| **A/B testing** | route by header, cookie or user attribute | ingress controller or service mesh rules |
| **Shadow / mirror** | copy real traffic to the new version, discard responses | service mesh |

You can build a rough canary with nothing but labels:

```
Service selector: app=frontend         (matches BOTH deployments)

Deployment frontend-stable  replicas=9  labels: app=frontend, version=v1
Deployment frontend-canary  replicas=1  labels: app=frontend, version=v2
```

10% of pods run v2, so roughly 10% of requests hit it. Crude but real, and it
requires no extra tooling. You do this in Step 7.

### 5.5 Revision history and rollback

Every pod-template change creates a new ReplicaSet and a new **revision**. Old
ReplicaSets stay at zero replicas, which makes rollback a scale-up rather than a
re-deploy — near instant.

```yaml
spec:
  revisionHistoryLimit: 10     # default; how many old ReplicaSets to keep
```

Set it to 0 and you cannot roll back at all. Set it very high and you accumulate
clutter. 5-10 is sensible.

**Important:** only changes to `spec.template` create a revision. Changing
`replicas` does not — scaling is not a new version.

### 5.6 `kubectl rollout`

```bash
kubectl rollout status     deployment/x    # block until the rollout finishes
kubectl rollout history    deployment/x    # list revisions
kubectl rollout history    deployment/x --revision=3
kubectl rollout undo       deployment/x    # back one revision
kubectl rollout undo       deployment/x --to-revision=2
kubectl rollout pause      deployment/x    # stop mid-rollout (canary by hand)
kubectl rollout resume     deployment/x
kubectl rollout restart    deployment/x    # restart all pods, same image
```

`kubectl rollout restart` deserves a mention: it adds a timestamp annotation to
the pod template, which changes the template, which triggers a normal rolling
update with the *same* image. It is how you pick up a changed ConfigMap or
Secret (Day 09), or clear a stuck cache, without any downtime.

---

## Part 2 - Hands-on lab

We use `nginx` version tags as stand-ins for app versions, so the lab works
before you build the DevBoard images on Day 08.

### Step 1: A Deployment with an explicit strategy

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: devboard-frontend
  namespace: devboard
  annotations:
    kubernetes.io/change-cause: "initial deploy nginx 1.25"
spec:
  replicas: 5
  revisionHistoryLimit: 5
  minReadySeconds: 5              # a new pod must stay Ready this long to count
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: devboard-frontend
  template:
    metadata:
      labels:
        app: devboard-frontend
        version: "1.25"
    spec:
      containers:
        - name: frontend
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          readinessProbe:          # this is what makes the rollout safe
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
```

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/devboard-frontend -n devboard
```

`minReadySeconds: 5` is quietly valuable: without it, a pod that becomes Ready
and then immediately crashes still counts as a successful step, and a broken
rollout marches all the way through. With it, the pod must *stay* Ready.

### Step 2: Watch a rolling update happen

Terminal 1 — watch:

```bash
kubectl get pods -n devboard -l app=devboard-frontend -w
```

Terminal 2 — trigger the update:

```bash
kubectl set image deployment/devboard-frontend \
  frontend=nginx:1.26-alpine -n devboard

kubectl annotate deployment/devboard-frontend -n devboard \
  kubernetes.io/change-cause="upgrade to nginx 1.26" --overwrite
```

Terminal 1 shows the dance: one new pod created, one old pod terminated, repeat.
Count the rows — you should never see fewer than 4 Running pods, nor more than
6 total, exactly as `maxUnavailable: 1` / `maxSurge: 1` promised.

Terminal 3 — watch it from the Deployment's perspective:

```bash
kubectl rollout status deployment/devboard-frontend -n devboard
kubectl get rs -n devboard
```

```
NAME                          DESIRED   CURRENT   READY
devboard-frontend-6c8b9d7f4   5         5         5     <- new (1.26)
devboard-frontend-7d9f8c4b5   0         0         0     <- old (1.25), kept
```

`kubectl set image` is convenient for a demo, but in real work you edit the
manifest and `kubectl apply` so git stays the source of truth.

### Step 2b: Watch the rollout happen, request by request

Counting pods tells you the mechanism. Watching *traffic* tells you whether it
actually worked — and it is far more convincing.

Build a v2 image first if you have not (Day 08):

```bash
bash app/build-images.sh 2.0
```

Terminal 1:

```bash
bash days/day-05-rolling-updates-and-rollbacks/solution/rollout-watch.sh
```

It polls the app continuously and prints one character per request:
`1` served by v1.0, `2` served by v2.0, `X` failed.

Terminal 2:

```bash
kubectl set image deployment/frontend frontend=devboard-frontend:2.0 -n devboard
```

Terminal 1 shows the transition:

```
1111111111111111 1112111121112211 2222122222222222 2222222222222222
```

Old and new **serving simultaneously**, gradually shifting, and — the part that
matters — **not a single `X`**. That is what zero-downtime means, measured
rather than asserted.

> The mixed middle section is worth pausing on. During a rolling update, two
> versions of your application serve real users at the same time. Any change
> that cannot tolerate that — an incompatible database schema, a changed API
> contract — will break here and nowhere else. It is why Day 05's interview
> question on migrations has the answer "expand, migrate, contract".

Now do the same with the Recreate strategy and watch it fail:

```bash
kubectl patch deployment frontend -n devboard -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'

kubectl set image deployment/frontend frontend=devboard-frontend:1.0 -n devboard
```

```
2222222222 XXXXXXXXXXXXXXXXXXXXXXXX 1111111111
            ^^^^^^^^^^^^^^^^^^^^^^^
            every pod gone -- this is the outage
```

A visible block of failures, exactly as long as it takes new pods to start.
Ctrl-C prints the totals. Put it back:

```bash
kubectl patch deployment frontend -n devboard -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1,"maxSurge":1}}}}'
```

**Keep this script.** It is the fastest way to answer "did that deploy actually
cause an outage?" and you will reuse it on Day 13 for graceful shutdown.

### Step 3: The change-cause annotation

```bash
kubectl rollout history deployment/devboard-frontend -n devboard
```

```
REVISION  CHANGE-CAUSE
1         initial deploy nginx 1.25
2         upgrade to nginx 1.26
```

`CHANGE-CAUSE` comes purely from the `kubernetes.io/change-cause` annotation.
If you never set it, the column reads `<none>` and rollout history is useless
for deciding *which* revision to go back to. Set it on every change — a ticket
number or git SHA is ideal.

Inspect a specific revision:

```bash
kubectl rollout history deployment/devboard-frontend -n devboard --revision=1
```

### Step 4: Break production, then roll back

Deploy an image that does not exist:

```bash
kubectl set image deployment/devboard-frontend \
  frontend=nginx:9.9.9-does-not-exist -n devboard

kubectl annotate deployment/devboard-frontend -n devboard \
  kubernetes.io/change-cause="BAD: typo in image tag" --overwrite

kubectl get pods -n devboard -l app=devboard-frontend
```

```
NAME                                 READY   STATUS             RESTARTS
devboard-frontend-6c8b9d7f4-...      1/1     Running                   0
devboard-frontend-6c8b9d7f4-...      1/1     Running                   0
devboard-frontend-6c8b9d7f4-...      1/1     Running                   0
devboard-frontend-6c8b9d7f4-...      1/1     Running                   0
devboard-frontend-84d5f9c66-...      0/1     ImagePullBackOff          0
```

**Look at that carefully — this is the good news.** Four healthy v1.26 pods are
still serving traffic. The rollout stopped dead because the new pod never became
Ready, and `maxUnavailable: 1` forbade removing any more old pods.

This is Kubernetes protecting you. A broken image is a stalled rollout, not an
outage.

```bash
kubectl rollout status deployment/devboard-frontend -n devboard --timeout=30s
# error: timed out waiting for the condition
```

Now undo:

```bash
kubectl rollout undo deployment/devboard-frontend -n devboard
kubectl rollout status deployment/devboard-frontend -n devboard
kubectl get pods -n devboard -l app=devboard-frontend
```

Back to 5/5 in seconds, because the old ReplicaSet was still sitting there at
zero — rollback is a scale-up, not a redeploy.

Roll back to a specific revision instead:

```bash
kubectl rollout history deployment/devboard-frontend -n devboard
kubectl rollout undo deployment/devboard-frontend -n devboard --to-revision=1
kubectl rollout status deployment/devboard-frontend -n devboard
```

### Step 5: progressDeadlineSeconds — fail loudly instead of hanging

By default a Deployment gives a rollout 600 seconds to make progress before
marking itself `Progressing=False` with reason `ProgressDeadlineExceeded`. Your
CI pipeline should watch for that rather than waiting forever.

```bash
kubectl patch deployment devboard-frontend -n devboard \
  -p '{"spec":{"progressDeadlineSeconds":60}}'

kubectl set image deployment/devboard-frontend \
  frontend=nginx:9.9.9-nope -n devboard

kubectl rollout status deployment/devboard-frontend -n devboard
# after ~60s: error: deployment "devboard-frontend" exceeded its progress deadline

kubectl get deploy devboard-frontend -n devboard -o jsonpath='{.status.conditions}' 
kubectl rollout undo deployment/devboard-frontend -n devboard
```

Note: Kubernetes does **not** auto-rollback. It stops and reports. Automatic
rollback is your pipeline's job (`kubectl rollout status || kubectl rollout undo`)
or a progressive-delivery tool like Argo Rollouts or Flagger.

### Step 6: Recreate strategy, for contrast

```bash
kubectl patch deployment devboard-frontend -n devboard \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'

kubectl get pods -n devboard -w      # terminal 1
```

```bash
kubectl set image deployment/devboard-frontend \
  frontend=nginx:1.27-alpine -n devboard
```

Every pod terminates first. Only then do new ones start. There is a real gap
with zero pods running — that is the point of the strategy, not a bug.

Put it back:

```bash
kubectl patch deployment devboard-frontend -n devboard \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1,"maxSurge":1}}}}'
```

### Step 7: A canary with nothing but labels

Two Deployments, one shared label that a Service will select on. Apply
`solution/canary-stable.yaml` and `solution/canary-canary.yaml`:

```bash
kubectl apply -f solution/canary-stable.yaml
kubectl apply -f solution/canary-canary.yaml
kubectl get pods -n devboard -l app=canary-demo --show-labels
```

```
canary-demo-stable-...   version=v1     (x9)
canary-demo-canary-...   version=v2     (x1)
```

A Service with `selector: {app: canary-demo}` matches **all ten**, so roughly
10% of requests reach v2. Shift the split by changing replica counts:

```bash
kubectl scale deployment canary-demo-canary --replicas=3 -n devboard
kubectl scale deployment canary-demo-stable --replicas=7 -n devboard
```

"Promote the canary" means setting stable to v2 and scaling the canary to zero.

Limitations to be honest about: the granularity is 1/N, traffic is only
approximately split (it depends on connection distribution), and there is no
automatic analysis. Real canary deployments use weighted routing in an ingress
controller or service mesh, plus automated metric checks. But the label
mechanism underneath is exactly this.

```bash
kubectl delete deployment canary-demo-stable canary-demo-canary -n devboard
```

### Step 8: Blue/green with a Service selector flip

Preview: on Day 06 you will build the Service. The mechanism is one line.

```bash
# all traffic to blue
kubectl patch service devboard-frontend -n devboard \
  -p '{"spec":{"selector":{"app":"devboard-frontend","version":"blue"}}}'

# ...test green out of band, then flip everything at once
kubectl patch service devboard-frontend -n devboard \
  -p '{"spec":{"selector":{"app":"devboard-frontend","version":"green"}}}'
```

Instant cutover, instant rollback, at the cost of running two full environments.

### Step 9: rollout restart

```bash
kubectl rollout restart deployment/devboard-frontend -n devboard
kubectl rollout status  deployment/devboard-frontend -n devboard
kubectl get pods -n devboard -l app=devboard-frontend
```

Same image, brand new pods, zero downtime. Look at what changed:

```bash
kubectl get deploy devboard-frontend -n devboard \
  -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
# kubectl.kubernetes.io/restartedAt: 2026-...
```

A single annotation on the pod template. That changes the template hash, which
creates a new ReplicaSet, which triggers a rolling update. Elegant.

You will use this constantly from Day 09 onward, because pods do **not**
automatically restart when a ConfigMap or Secret they read as env vars changes.

---

## Validate

```bash
kubectl apply -f solution/deployment.yaml
kubectl rollout status deployment/devboard-frontend -n devboard --timeout=120s

# roll forward
kubectl set image deployment/devboard-frontend frontend=nginx:1.26-alpine -n devboard
kubectl rollout status deployment/devboard-frontend -n devboard --timeout=120s

# there should now be at least 2 revisions
kubectl rollout history deployment/devboard-frontend -n devboard

# roll back and confirm the image reverted
kubectl rollout undo deployment/devboard-frontend -n devboard
kubectl rollout status deployment/devboard-frontend -n devboard --timeout=120s
kubectl get deploy devboard-frontend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # nginx:1.25-alpine
```

Ready for Day 06 when you can:

1. Compute the min and max pod counts from `replicas`, `maxUnavailable`, `maxSurge`.
2. Explain why a rolling update without a readiness probe is not zero-downtime.
3. Explain why a broken image stalls a rollout instead of causing an outage.
4. Name the two built-in strategies, and say how blue/green and canary are done.

---

## Break it

**A. maxUnavailable: 0 with no spare capacity.**

Set `maxUnavailable: 0`, `maxSurge: 1`, scale to a replica count your cluster
cannot exceed by one, and trigger an update. The rollout hangs: it cannot remove
an old pod until a new one is Ready, and the new one cannot schedule. Diagnose
with `kubectl describe pod` → `Insufficient cpu`.

**B. No readiness probe, slow app.**

```bash
kubectl patch deployment devboard-frontend -n devboard --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]'

kubectl set image deployment/devboard-frontend \
  frontend=nginx:1.27-alpine -n devboard
kubectl rollout status deployment/devboard-frontend -n devboard
```

The rollout completes almost instantly, because every pod is "Ready" the moment
its process starts. For nginx that is nearly true. For a JVM app with a 45-second
startup, you have just deleted all your healthy pods and pointed a Service at
containers that return connection-refused. Day 13.

**C. revisionHistoryLimit: 0.**

```bash
kubectl patch deployment devboard-frontend -n devboard \
  -p '{"spec":{"revisionHistoryLimit":0}}'
kubectl set image deployment/devboard-frontend frontend=nginx:1.26-alpine -n devboard
kubectl rollout status deployment/devboard-frontend -n devboard
kubectl rollout undo deployment/devboard-frontend -n devboard
# error: no rollout history found
```

Restore it: `kubectl patch deployment devboard-frontend -n devboard -p '{"spec":{"revisionHistoryLimit":5}}'`

**D. `latest` tag makes rollouts meaningless.**

Set the image to `nginx:latest` and apply twice. The second apply changes
nothing (the template is identical), so no rollout happens — even if the
registry now has different bits behind that tag. Meanwhile different nodes may
have pulled different content at different times. **Always pin a tag or a
digest.**

---

## Interview questions

<details>
<summary><b>1. Explain a rolling update.</b></summary>

The Deployment creates a new ReplicaSet for the new pod template and gradually
scales it up while scaling the old one down, bounded by `maxSurge` (how many
pods above the desired count may exist) and `maxUnavailable` (how many below the
desired count may be unavailable). A new pod must pass its readiness probe
before an old pod is removed, so capacity is preserved throughout.
</details>

<details>
<summary><b>2. maxSurge and maxUnavailable with replicas=10, both 25%?</b></summary>

maxSurge 25% of 10 rounds up to 3, so at most 13 pods exist at any moment.
maxUnavailable 25% of 10 rounds down to 2, so at least 8 pods are available.
Surge rounds up, unavailable rounds down — Kubernetes errs toward more capacity.
</details>

<details>
<summary><b>3. Which deployment strategies does Kubernetes support natively?</b></summary>

Only two on a Deployment: RollingUpdate (default) and Recreate. Blue/green,
canary, A/B and shadow are patterns you build with multiple Deployments plus
Service selector changes, or with an ingress controller or service mesh doing
weighted routing. Argo Rollouts and Flagger automate them.
</details>

<details>
<summary><b>4. How do you roll back, and how fast is it?</b></summary>

`kubectl rollout undo deployment/x`, optionally `--to-revision=N`. It is fast
because the previous ReplicaSet still exists at zero replicas with its pod
template intact, so rollback is a scale-up rather than a fresh deploy. It obeys
the same rolling-update parameters.
</details>

<details>
<summary><b>5. Does Kubernetes automatically roll back a failed deployment?</b></summary>

No. It stalls the rollout and, after `progressDeadlineSeconds` (default 600),
sets the Progressing condition to False with ProgressDeadlineExceeded. Automatic
rollback is your pipeline's responsibility, typically
`kubectl rollout status || kubectl rollout undo`.
</details>

<details>
<summary><b>6. You deployed a bad image. What does the cluster look like?</b></summary>

The new ReplicaSet has pods in ImagePullBackOff that never become Ready. Because
maxUnavailable caps how many old pods can be removed, most old pods keep
running and serving traffic. So it is a stalled rollout with degraded capacity,
not an outage — which is why you should alert on rollout status, not only on
error rates.
</details>

<details>
<summary><b>7. How do you make pods pick up a changed ConfigMap?</b></summary>

If it is mounted as a volume, the file updates in place after a kubelet sync
(around a minute) — but only if the app watches the file. If it is consumed as
environment variables, it never updates. The general answer is
`kubectl rollout restart deployment/x`, which stamps a timestamp annotation on
the pod template and triggers a normal rolling update. A more robust pattern is
to hash the ConfigMap contents into a pod-template annotation so any change
automatically produces a new revision.
</details>

<details>
<summary><b>8. Why is `latest` a bad tag?</b></summary>

It is mutable, so different nodes can run different bits under the same name;
`kubectl apply` sees no template change so no rollout occurs; and rollback is
meaningless because the old revision points at the same moving tag. Pin a
semantic tag, and pin a digest when you need to be certain.
</details>

<details>
<summary><b>9. What is minReadySeconds for?</b></summary>

The minimum time a new pod must be Ready without any container crashing before
it counts as available and the rollout proceeds. It prevents a rollout from
marching through pods that pass readiness once and then crash a second later.
</details>

<details>
<summary><b>10. Rolling update while a database migration is needed?</b></summary>

Rolling updates mean two versions run simultaneously, so schema changes must be
backwards compatible: expand-then-contract. Add nullable columns and new tables
first, deploy code that writes both old and new shapes, backfill, deploy code
that reads only the new shape, and only then drop the old columns. If that is
impossible, use the Recreate strategy and accept a maintenance window.
</details>

---

## Cheat card

```bash
# trigger a rollout
kubectl set image deployment/web app=nginx:1.27 -n devboard
kubectl apply -f deployment.yaml            # preferred: git is the source of truth
kubectl rollout restart deployment/web -n devboard   # same image, new pods

# observe
kubectl rollout status  deployment/web -n devboard
kubectl rollout history deployment/web -n devboard
kubectl rollout history deployment/web -n devboard --revision=3
kubectl get rs -n devboard

# control
kubectl rollout pause  deployment/web -n devboard
kubectl rollout resume deployment/web -n devboard
kubectl rollout undo   deployment/web -n devboard
kubectl rollout undo   deployment/web -n devboard --to-revision=2

# record why
kubectl annotate deployment/web -n devboard \
  kubernetes.io/change-cause="JIRA-1234 upgrade nginx" --overwrite
```

| Field | Default | Meaning |
|---|---|---|
| `strategy.type` | RollingUpdate | or Recreate |
| `maxSurge` | 25% | extra pods allowed above desired |
| `maxUnavailable` | 25% | pods allowed below desired |
| `minReadySeconds` | 0 | how long a pod must stay Ready to count |
| `progressDeadlineSeconds` | 600 | before the rollout is marked failed |
| `revisionHistoryLimit` | 10 | old ReplicaSets kept for rollback |

---

**Next: [Day 06 - Services, ClusterIP and cluster DNS](../day-06-services-clusterip-and-dns/)**
