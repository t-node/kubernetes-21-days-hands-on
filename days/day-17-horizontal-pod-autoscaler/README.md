# Day 17 — Horizontal Pod Autoscaler

**Time:** 60-75 minutes
**Prerequisites:** Day 16 (**metrics-server must be working**)

Today you make the cluster add pods on its own. Confirm your prerequisite first:

```bash
kubectl top pods -n devboard
```

If that errors, go back to Day 16. The HPA has no input without it.

---

## Part 1 - Concepts

### 17.1 Horizontal vs vertical

| | **Horizontal (HPA)** | **Vertical (VPA)** |
|---|---|---|
| Changes | the **number of pods** | the **size of each pod** |
| From | 2 pods → 10 pods | 512Mi → 2Gi per pod |
| Disruption | none; new pods just appear | pods must be **recreated** to resize |
| Limit | node capacity across the cluster | the largest single node |
| Suits | stateless services | databases, JVM apps, anything that cannot shard |

HPA is what you reach for by default: adding replicas is non-disruptive and
scales past any single machine. VPA is for workloads that genuinely cannot be
parallelised — and even then, most teams run it in *recommendation* mode to size
requests properly rather than letting it restart pods.

They **conflict on the same metric**. VPA in auto mode adjusting CPU requests
while an HPA targets CPU utilisation creates a feedback loop. Use HPA on CPU and
VPA on memory, or VPA in recommendation mode only.

### 17.2 The algorithm — one formula

```
desiredReplicas = ceil( currentReplicas × ( currentMetricValue / desiredMetricValue ) )
```

Concretely, with `averageUtilization: 50`:

| Current pods | Average CPU | Calculation | Result |
|---|---|---|---|
| 2 | 100% | ceil(2 × 100/50) | **4** |
| 4 | 75% | ceil(4 × 75/50) | **6** |
| 6 | 50% | ceil(6 × 50/50) | **6** (stable) |
| 6 | 10% | ceil(6 × 10/50) | **2** |

**`averageUtilization` is a percentage of the CPU `request`, not of a core.**
This is the detail that trips everyone up.

A pod requesting `50m` and using `60m` is at **120% utilisation**. If the target
is 50%, the HPA more than doubles the replicas — even though 60 millicores is
almost nothing in absolute terms.

> **No CPU request means no denominator.** The HPA reports `<unknown>/50%` and
> never scales. That is the number one HPA bug, and it is why Day 16's
> `05-backend-with-resources.yaml` was a prerequisite.

A **10% tolerance** is built in: the HPA ignores ratios between 0.9 and 1.1 to
prevent constant churn around the target.

### 17.3 The manifest

```yaml
apiVersion: autoscaling/v2       # NOT apps/v1, and NOT v1 -- see below
kind: HorizontalPodAutoscaler
metadata:
  name: backend
spec:
  scaleTargetRef:                # WHAT to scale
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

`autoscaling/v2` matters. `autoscaling/v1` supports only a single CPU target;
v2 supports multiple metrics, memory, custom metrics, external metrics and
scaling behaviour. Always write v2.

`scaleTargetRef` can name any resource implementing the `scale` subresource:
Deployment, StatefulSet, ReplicaSet — but **not a DaemonSet**, which is one per
node by definition.

### 17.4 Multiple metrics

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 60 }
  - type: Resource
    resource:
      name: memory
      target: { type: Utilization, averageUtilization: 70 }
```

With several metrics the HPA computes a desired replica count for each and takes
the **highest**. It scales up if *any* metric demands it, and only scales down
when *all* of them allow it. Conservative, deliberately.

**Memory as an autoscaling metric is usually a mistake.** Most applications do
not release memory when load drops — JVM heaps, Go's allocator, connection pools
— so memory ratchets up, the HPA scales out, and never scales back in. Prefer
CPU, or a real load signal like requests-per-second or queue depth via a custom
metrics adapter.

### 17.5 Scaling behaviour — stabilisation and rate limits

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0     # react immediately
    policies:
      - type: Percent
        value: 100                    # at most double
        periodSeconds: 30
      - type: Pods
        value: 4                      # ...and at most +4 pods
        periodSeconds: 30
    selectPolicy: Max                 # take the more permissive
  scaleDown:
    stabilizationWindowSeconds: 300   # 5 min of low load before shrinking
    policies:
      - type: Percent
        value: 50
        periodSeconds: 60
```

The asymmetry is intentional and matches how you want production to behave:
**scale up fast, scale down slowly.** Scaling up late costs you an outage;
scaling down late costs you a few minutes of compute.

The default `scaleDown.stabilizationWindowSeconds` is **300**, which is why an
HPA appears "stuck" at a high replica count for five minutes after load stops.
That is not a bug — do not go looking for one.

### 17.6 What the HPA cannot do

- **It cannot add nodes.** If the cluster has no room, the new pods sit
  `Pending`. That is the **Cluster Autoscaler**'s job (or Karpenter) — a
  separate component that watches for unschedulable pods and provisions
  machines. HPA and Cluster Autoscaler are complementary, and interviewers like
  to check you know they are different things.
- **It cannot scale on anything metrics-server does not provide** without an
  adapter. Requests-per-second, queue depth, p99 latency all need
  `prometheus-adapter` or KEDA.
- **It fights a fixed `replicas:` in your manifest.** If a Deployment declares
  `replicas: 2` and GitOps re-applies it, you and the HPA will fight forever.
  **Omit `replicas` entirely from any Deployment managed by an HPA** (or exclude
  the field from your sync).

### 17.7 KEDA, briefly

For event-driven work — Kafka lag, SQS depth, cron schedules, scale-to-zero —
**KEDA** is the standard answer. It generates an HPA under the hood, adds 60+
scalers, and supports scaling to **zero**, which a plain HPA cannot (`minReplicas`
must be at least 1). Worth naming in an interview.

---

## Part 2 - Hands-on lab

### Step 1: Confirm the prerequisites

```bash
kubectl top pods -n devboard                      # must work
kubectl get deploy backend -n devboard \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
# must print something, e.g. 50m
```

If the CPU request is empty, apply Day 16's manifest first:

```bash
kubectl apply -f ../day-16-resources-requests-limits-metrics-server/solution/05-backend-with-resources.yaml
kubectl rollout status deployment/backend -n devboard
```

### Step 2: Create the HPA

```bash
kubectl apply -f solution/01-backend-hpa.yaml
kubectl get hpa -n devboard
```

```
NAME      REFERENCE            TARGETS         MINPODS  MAXPODS  REPLICAS
backend   Deployment/backend   <unknown>/50%   2        10       2
```

`<unknown>` for the first 15-60 seconds is normal — the HPA has not collected a
sample yet. Wait and re-check:

```bash
sleep 45
kubectl get hpa backend -n devboard
# TARGETS: 2%/50%
```

If it stays `<unknown>` for minutes, that is Break It A.

```bash
kubectl describe hpa backend -n devboard
```

Read the `Conditions` block — `AbleToScale`, `ScalingActive`, `ScalingLimited`.
It tells you exactly what the HPA thinks is happening, and it is the first place
to look when an HPA misbehaves.

### Step 3: Generate load

Terminal 1 — watch:

```bash
watch -n 2 'kubectl get hpa,pods -n devboard -l app=backend; echo; kubectl top pods -n devboard -l app=backend'
```

No `watch` on Windows? Use:

```bash
while true; do clear; kubectl get hpa -n devboard; kubectl get pods -n devboard -l app=backend --no-headers | wc -l; sleep 2; done
```

Terminal 2 — start the load generator:

```bash
kubectl apply -f solution/02-load-generator.yaml
kubectl get pods -n devboard -l app=load-generator
```

It runs 8 replicas, each looping `wget` against `backend:8080/tasks` — which
means every request goes through Gin **and** hits Postgres, so it burns real CPU
rather than serving a static response.

Now watch terminal 1 for 3-5 minutes:

```
TARGETS       REPLICAS
2%/50%        2
78%/50%       2        <- metrics catch up
78%/50%       4        <- scaled: ceil(2 x 78/50) = 4
120%/50%      4
120%/50%      8        <- ceil(4 x 120/50) = 10, capped by the +100%/30s policy
64%/50%       8
55%/50%       9
50%/50%       9        <- converged
```

Trace one of those numbers by hand against the formula in 17.2. That is the
moment the HPA stops being magic.

```bash
kubectl get pods -n devboard -l app=backend
kubectl describe hpa backend -n devboard | grep -A8 Events
```

```
Normal  SuccessfulRescale  horizontal-pod-autoscaler
        New size: 4; reason: cpu resource utilization (percentage of request) above target
```

Note the phrase Kubernetes itself uses: **"percentage of request"**. Section
17.2, straight from the controller.

### Step 4: Stop the load and be patient

```bash
kubectl delete -f solution/02-load-generator.yaml
kubectl top pods -n devboard -l app=backend         # drops within ~30s
kubectl get hpa backend -n devboard                 # TARGETS drops...
kubectl get pods -n devboard -l app=backend | wc -l # ...but REPLICAS does not
```

CPU falls in seconds; the replica count stays high for **five minutes**. That is
`scaleDown.stabilizationWindowSeconds: 300` from section 17.5, and it is
deliberate — it stops a brief lull from removing capacity you are about to need
again.

Wait it out and watch it step down:

```bash
kubectl get hpa,pods -n devboard -l app=backend -w    # Ctrl-C when it reaches 2
```

It stops at `minReplicas: 2`, never lower.

### Step 5: Tune the behaviour and feel the difference

```bash
kubectl apply -f solution/03-backend-hpa-tuned.yaml
kubectl describe hpa backend -n devboard | grep -A20 Behavior
```

This version scales up aggressively (double every 15s, no stabilisation) and
down cautiously (50% per minute, after 2 minutes of calm). Re-run the load test
and compare how quickly it reacts in each direction.

```bash
kubectl apply -f solution/02-load-generator.yaml
sleep 120
kubectl get hpa,pods -n devboard -l app=backend
kubectl delete -f solution/02-load-generator.yaml
```

### Step 6: Scale to the ceiling and hit the wall

```bash
kubectl patch hpa backend -n devboard -p '{"spec":{"maxReplicas":40}}'
kubectl apply -f solution/04-load-generator-heavy.yaml

sleep 180
kubectl get hpa backend -n devboard
kubectl get pods -n devboard -l app=backend | tail -5
kubectl get pods -n devboard --field-selector=status.phase=Pending
```

Eventually some pods sit `Pending`:

```bash
kubectl describe pod -n devboard -l app=backend | grep -B2 -A3 "FailedScheduling"
# 0/3 nodes are available: 3 Insufficient cpu.
```

**The HPA did its job and the cluster ran out of room.** The HPA cannot add
nodes. On EKS or GKE, the **Cluster Autoscaler** would notice those unschedulable
pods and provision machines. On kind, nothing will — the ceiling is your laptop.

This is exactly the distinction from 17.6, and it is a common interview
follow-up: *"your HPA is scaling but pods are Pending — what is missing?"*

```bash
kubectl delete -f solution/04-load-generator-heavy.yaml
kubectl patch hpa backend -n devboard -p '{"spec":{"maxReplicas":10}}'
```

### Step 7: Scale the frontend too

```bash
kubectl apply -f solution/05-frontend-hpa.yaml
kubectl get hpa -n devboard
```

Two HPAs, independent. In a real system each tier scales on its own signal —
frontends on request volume, backends on CPU, workers on queue depth.

---

## Validate

```bash
kubectl get hpa backend -n devboard
kubectl get hpa backend -n devboard \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}{"\n"}'
# a number, not empty

# scale up under load
kubectl apply -f solution/02-load-generator.yaml
sleep 150
kubectl get hpa backend -n devboard
kubectl get pods -n devboard -l app=backend --no-headers | wc -l    # more than 2

# and back down (be patient - 5 minutes)
kubectl delete -f solution/02-load-generator.yaml
sleep 360
kubectl get pods -n devboard -l app=backend --no-headers | wc -l    # 2
```

Ready for Day 18 when you can:

1. Write the HPA formula from memory and apply it to a worked example.
2. Explain what `averageUtilization: 50` is a percentage *of*.
3. Say why an HPA reports `<unknown>` and never scales.
4. Explain the difference between the HPA and the Cluster Autoscaler.

---

## Break it

**A. Remove the CPU request — the number one HPA bug.**

```bash
kubectl patch deployment backend -n devboard --type=json -p \
'[{"op":"remove","path":"/spec/template/spec/containers/0/resources/requests/cpu"}]'
kubectl rollout status deployment/backend -n devboard

sleep 60
kubectl get hpa backend -n devboard
# TARGETS: <unknown>/50%     -- forever

kubectl describe hpa backend -n devboard | grep -A5 Conditions
# ScalingActive  False  FailedGetResourceMetric
# missing request for cpu
```

No request means no denominator, so no utilisation percentage, so no scaling —
silently. The HPA object exists and looks fine in `kubectl get hpa`. Restore:

```bash
kubectl apply -f ../day-16-resources-requests-limits-metrics-server/solution/05-backend-with-resources.yaml
```

**B. HPA versus a hardcoded `replicas`.**

```bash
kubectl apply -f solution/02-load-generator.yaml
sleep 150
kubectl get pods -n devboard -l app=backend --no-headers | wc -l   # e.g. 6

# now simulate a GitOps sync re-applying the manifest
kubectl apply -f ../day-16-resources-requests-limits-metrics-server/solution/05-backend-with-resources.yaml
kubectl get pods -n devboard -l app=backend --no-headers | wc -l   # snapped to 2
sleep 60
kubectl get pods -n devboard -l app=backend --no-headers | wc -l   # HPA pushes it back up
```

Your Deployment says 2, your HPA says 6, and they fight — flapping capacity
during your busiest period. **Omit `replicas` entirely from any Deployment
managed by an HPA.** `solution/06-backend-no-replicas.yaml` shows the correct
shape.

```bash
kubectl delete -f solution/02-load-generator.yaml
kubectl apply -f solution/06-backend-no-replicas.yaml
```

**C. minReplicas: 0.**

```bash
kubectl patch hpa backend -n devboard -p '{"spec":{"minReplicas":0}}'
# Invalid value: 0: must be greater than or equal to 1
```

A plain HPA cannot scale to zero. **KEDA** can, and that is the expected answer.

**D. Autoscale on memory and watch it never come back down.**

```bash
kubectl apply -f solution/07-hpa-memory-BAD.yaml
kubectl apply -f solution/02-load-generator.yaml
sleep 180
kubectl get hpa backend-memory -n devboard
kubectl delete -f solution/02-load-generator.yaml
sleep 420
kubectl get hpa backend-memory -n devboard
```

Memory usage does not fall the way CPU does — the Go runtime holds onto pages,
connection pools stay allocated. The HPA scaled out and now has no reason to
scale back in. **Memory is a poor autoscaling signal** for most applications.

```bash
kubectl delete -f solution/07-hpa-memory-BAD.yaml
```

**E. Target a DaemonSet.**

```bash
kubectl apply -f solution/08-hpa-bad-target.yaml
kubectl describe hpa bad-target -n devboard | grep -A4 Conditions
# AbleToScale  False  FailedGetScale ... the server could not find the requested resource
kubectl delete -f solution/08-hpa-bad-target.yaml
```

A DaemonSet has no `scale` subresource — one pod per node is the definition, so
there is nothing to scale.

---

## Interview questions

<details>
<summary><b>1. How does the HPA decide how many replicas to run?</b></summary>

`desiredReplicas = ceil(currentReplicas x currentMetricValue / desiredMetricValue)`,
evaluated every 15 seconds by default. A 10% tolerance suppresses churn near the
target, and `behavior` policies plus stabilisation windows rate-limit how fast
it may move in each direction. With multiple metrics it computes a desired count
per metric and takes the highest.
</details>

<details>
<summary><b>2. averageUtilization: 50 is 50% of what?</b></summary>

Of the CPU **request**, not of a core and not of the limit. A pod requesting
100m and using 150m is at 150% utilisation. This is why a pod with no CPU
request breaks the HPA entirely - there is no denominator - and why request
values directly determine autoscaling behaviour.
</details>

<details>
<summary><b>3. Your HPA shows unknown/50% and never scales. Why?</b></summary>

Most likely the target container has no CPU request. Otherwise metrics-server is
not installed or not Ready, or its scrape is failing - on kind, TLS verification
against self-signed kubelet certificates. `kubectl describe hpa` shows the
condition `ScalingActive: False` with `FailedGetResourceMetric` and the precise
reason.
</details>

<details>
<summary><b>4. HPA vs VPA vs Cluster Autoscaler?</b></summary>

HPA changes the number of pods. VPA changes the CPU and memory of each pod,
which requires recreating them. Cluster Autoscaler changes the number of nodes,
reacting to pods that cannot be scheduled. They compose: HPA adds pods, Cluster
Autoscaler adds nodes when those pods do not fit. HPA and VPA conflict if both
act on the same metric, so run VPA on memory or in recommendation mode only.
</details>

<details>
<summary><b>5. Why does the HPA scale up quickly but down slowly?</b></summary>

Deliberate asymmetry. Under-provisioning causes user-visible failures, so
scale-up is immediate by default. Over-provisioning only costs money, so
scale-down waits out a five-minute stabilisation window to avoid removing
capacity during a brief lull and thrashing. Both are tunable through `behavior`.
</details>

<details>
<summary><b>6. Why is memory usually a bad autoscaling metric?</b></summary>

Most runtimes do not return memory when load falls - JVM heaps, Go's allocator,
connection pools and caches all retain it. So memory ratchets upward, the HPA
scales out, and it never has a reason to scale back in. CPU tracks load far more
faithfully, and a real load signal such as requests per second or queue depth is
better still, via a custom metrics adapter.
</details>

<details>
<summary><b>7. How would you autoscale on requests per second or queue depth?</b></summary>

Custom or external metrics. Run Prometheus, expose it through
`prometheus-adapter` so the HPA can read `custom.metrics.k8s.io`, then target
for example a per-pod requests-per-second value. For event-driven workloads KEDA
is simpler: 60+ scalers for Kafka, SQS, RabbitMQ and more, and it supports
scaling to zero, which a plain HPA cannot.
</details>

<details>
<summary><b>8. Your HPA scaled to 20 but half the pods are Pending. What is wrong?</b></summary>

The HPA worked; the cluster has no capacity. It only edits the replica count -
it cannot add machines. You need the Cluster Autoscaler or Karpenter to
provision nodes for unschedulable pods, or the pods' requests are too large to
fit any node, or a ResourceQuota is capping the namespace. Check
`kubectl describe pod` for the FailedScheduling reason.
</details>

<details>
<summary><b>9. Can you set replicas and an HPA on the same Deployment?</b></summary>

You can, and you should not. Whenever the manifest is re-applied it resets the
replica count and the HPA then corrects it, producing flapping capacity -
especially damaging under GitOps, which re-applies continuously. Omit `replicas`
from any HPA-managed Deployment, or configure the sync tool to ignore that
field.
</details>

---

## Cheat card

```bash
kubectl apply -f hpa.yaml
kubectl get hpa -n devboard
kubectl get hpa backend -n devboard -w
kubectl describe hpa backend -n devboard        # Conditions + Events = the truth

# imperative version (autoscaling/v1 - prefer the manifest)
kubectl autoscale deployment backend --cpu-percent=50 --min=2 --max=10 -n devboard

kubectl top pods -n devboard -l app=backend
kubectl get hpa backend -n devboard \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}'

kubectl delete hpa backend -n devboard
```

```
desiredReplicas = ceil( currentReplicas x currentMetric / targetMetric )
```

| Symptom | Cause |
|---|---|
| `TARGETS: <unknown>` | no CPU request, or metrics-server broken |
| Scales up, never down | 5-minute stabilisation window, or a memory metric |
| Replica count flapping | a hardcoded `replicas` fighting the HPA |
| Scaled, but pods `Pending` | no cluster capacity — needs the Cluster Autoscaler |
| `minReplicas: 0` rejected | plain HPA cannot scale to zero; use KEDA |

---

**Next: [Day 18 - Scheduling, taints and DaemonSets](../day-18-scheduling-taints-affinity-daemonsets/)**
