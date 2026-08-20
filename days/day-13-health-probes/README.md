# Day 13 — Liveness, Readiness & Startup Probes

**Time:** 75-90 minutes
**Prerequisites:** Day 12 (full stack running)

Probes are the most commonly misconfigured thing in Kubernetes, and misconfigured
probes cause outages rather than preventing them. Today you fix a real design
flaw in DevBoard's health checking.

---

## Part 1 - Concepts

### 13.1 Three probes, three completely different jobs

| Probe | Question it answers | On failure |
|---|---|---|
| **liveness** | "Is this process wedged and beyond saving?" | **kill and restart the container** |
| **readiness** | "Can this pod serve traffic *right now*?" | **remove it from Service endpoints** (no restart) |
| **startup** | "Has this slow app finished booting?" | kill the container; **disables the other two until it passes** |

The distinction that matters most:

> **Liveness failure = restart. Readiness failure = stop sending traffic.**
>
> They are not interchangeable, and using liveness where you meant readiness is
> how a dependency outage becomes a restart storm.

### 13.2 The rule for what a liveness probe may check

**A liveness probe must only test whether this process is healthy on its own.
It must never test a dependency.**

Imagine `/health` checked the database, and the database had a 30-second blip:

1. Every backend pod fails liveness.
2. Kubernetes kills every backend pod.
3. They all restart, all reconnect at once, and hammer the recovering database.
4. Which slows it further, so they fail liveness again.

You turned a 30-second database blip into a total, self-sustaining outage. This
is a genuinely common production incident.

**Readiness may — and usually should — check dependencies.** A pod that cannot
reach the database should leave the load-balancer rotation, keep running, and
rejoin when the database recovers. No restarts, no thundering herd.

### 13.3 DevBoard's problem, precisely

The Go backend has exactly one health endpoint:

```go
r.GET("/health", func(c *gin.Context) {
    c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "backend"})
})
```

It never touches the database. As a **liveness** probe that is **perfect** — it
is exactly the rule in 13.2.

As a **readiness** probe it is **wrong**, and you saw the consequence on Day 12:
Postgres died, and the backend pods stayed `1/1 Ready`, stayed in the Service
endpoints, and kept accepting requests they could only answer with a 500.

Three ways to fix it, in increasing order of quality:

**A. An `exec` readiness probe that checks the dependency from the side.**
Run a command in the container that proves the database is reachable. No code
change. This is what you will do today, because you cannot always modify an
upstream app — and knowing how to work around that is a genuinely useful skill.

**B. Add a real `/ready` endpoint to the app.** The right long-term answer: the
application knows whether *its own* connection pool is healthy, which an external
check cannot see. Roughly ten lines of Go.

**C. Fail fast and let liveness handle it.** Some designs prefer the process to
exit when its dependency is unreachable and let Kubernetes restart it — with
backoff. Simple, but it converts a brief blip into pod churn.

### 13.4 The four probe mechanisms

```yaml
# 1. httpGet -- the most common. 200-399 = success.
livenessProbe:
  httpGet:
    path: /health
    port: http                     # a name or a number
    httpHeaders:
      - name: X-Probe
        value: kubelet

# 2. exec -- any command. exit 0 = success.
readinessProbe:
  exec:
    command: ["sh", "-c", "pg_isready -h postgres -U devboard"]

# 3. tcpSocket -- can we open a connection?
livenessProbe:
  tcpSocket:
    port: 5432

# 4. grpc -- native gRPC health checking protocol (1.24+)
livenessProbe:
  grpc:
    port: 9000
```

`exec` is the most expensive: it forks a process in the container on every
check. An `exec` probe every second in a 200-pod deployment is real CPU. Prefer
`httpGet` where you can.

### 13.5 The timing fields, and what each one actually costs

```yaml
livenessProbe:
  httpGet: { path: /health, port: http }
  initialDelaySeconds: 10   # wait this long before the FIRST probe
  periodSeconds: 10         # then probe every N seconds
  timeoutSeconds: 1         # a probe taking longer than this counts as failed
  failureThreshold: 3       # consecutive failures before acting
  successThreshold: 1       # consecutive successes to be considered healthy
```

**Time to detect a failure** = `periodSeconds × failureThreshold` (+ up to one
period of latency). With the defaults above: up to 30 seconds before a wedged
container is restarted.

Defaults worth memorising: `periodSeconds: 10`, `timeoutSeconds: 1`,
`failureThreshold: 3`, `successThreshold: 1` (and it **must** be 1 for liveness
and startup).

`timeoutSeconds: 1` is the default and is aggressive. An application under load
that takes 1.2 seconds to answer `/health` will be declared dead and restarted —
at exactly the moment it is busiest. Set it deliberately.

### 13.6 Startup probes exist because of slow starters

A JVM app taking 90 seconds to boot has a problem: a liveness probe with a
30-second detection window kills it before it finishes, forever. The old
workaround was a huge `initialDelaySeconds`, which then means a *wedged*
container also goes 90 seconds undetected.

A startup probe separates the two concerns:

```yaml
startupProbe:
  httpGet: { path: /health, port: http }
  failureThreshold: 30
  periodSeconds: 5          # allows 30 x 5 = 150 seconds to boot

livenessProbe:
  httpGet: { path: /health, port: http }
  periodSeconds: 10
  failureThreshold: 3       # once started, detect a hang in ~30s
```

While the startup probe is running, liveness and readiness are **suspended**.
Once it passes, it never runs again and the other two take over. Generous at
boot, strict thereafter.

### 13.7 Probes and zero-downtime deploys

From Day 05: during a rolling update, a new pod must become **Ready** before an
old one is removed. Without a readiness probe, "Ready" means "the process
started", and you route traffic to a container that is not listening yet.

**A rolling update without a readiness probe is not a zero-downtime deploy.**
It only looks like one when the app happens to start instantly.

The other half is **graceful shutdown**, which people forget. When a pod is
deleted, two things happen *in parallel*:

1. it is removed from the Service endpoints (asynchronously, via kube-proxy on
   every node — which takes a moment)
2. `SIGTERM` is sent to the container

If your app exits on `SIGTERM` immediately, in-flight requests are dropped and
traffic still arriving from a not-yet-updated node gets connection-refused. The
standard fix is a `preStop` sleep:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
terminationGracePeriodSeconds: 30
```

Sleep for longer than endpoint propagation takes, *then* let the app shut down.
Crude, and it is what most production deployments actually do.

---

## Part 2 - Hands-on lab

### Step 1: Reproduce the flaw

```bash
kubectl apply -f ../day-12-wire-the-three-tier-app/solution/
kubectl rollout status deployment/backend -n devboard

kubectl scale deployment postgres --replicas=0 -n devboard
sleep 20

kubectl get pods -n devboard -l app=backend
kubectl get endpoints backend -n devboard
```

```
NAME                       READY   STATUS    RESTARTS   AGE
backend-7d9f8c4b5-2xk9p    1/1     Running   0          5m
backend-7d9f8c4b5-q7wzl    1/1     Running   0          5m

NAME      ENDPOINTS                           AGE
backend   10.244.1.12:8080,10.244.2.8:8080    5m
```

**Both pods claim to be Ready with no database.** So traffic keeps arriving:

```bash
curl -s -o /dev/null -w "API: %{http_code}\n" http://localhost:30080/api/tasks
kubectl logs -n devboard -l app=backend --tail=5
```

The user gets a 500. Kubernetes had a mechanism to prevent that and you did not
use it.

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
kubectl rollout status deployment/postgres -n devboard
```

### Step 2: Fix readiness with an exec probe

`solution/01-backend-probes-exec.yaml` keeps `/health` for liveness and adds a
readiness probe that actually tests the dependency. Since the Go image has no
`psql`, it opens a TCP connection to Postgres from inside the container using
`/dev/tcp`, which Alpine's shell supports:

```yaml
livenessProbe:                      # process health ONLY -- never a dependency
  httpGet: { path: /health, port: http }

readinessProbe:                     # dependency health -- takes it out of rotation
  exec:
    command:
      - sh
      - -c
      - "wget -q -O /dev/null http://127.0.0.1:8080/health && nc -z $POSTGRES_HOST $POSTGRES_PORT"
```

```bash
kubectl apply -f solution/01-backend-probes-exec.yaml
kubectl rollout status deployment/backend -n devboard
kubectl get pods -n devboard -l app=backend        # 1/1 Ready
```

Now repeat the experiment:

```bash
kubectl scale deployment postgres --replicas=0 -n devboard
sleep 25

kubectl get pods -n devboard -l app=backend
# READY 0/1, STATUS Running, RESTARTS 0     <- the important line
kubectl get endpoints backend -n devboard
# ENDPOINTS: <none>

curl -s -o /dev/null -w "API: %{http_code}\n" http://localhost:30080/api/tasks
# 502  -- the proxy has no healthy backend, rather than a backend returning 500
```

Read that carefully, because it is the whole day:

- `RESTARTS: 0` — **liveness did not fire.** No restart storm. The pods are
  alive and correct; they simply cannot serve.
- `ENDPOINTS: <none>` — **readiness fired.** Kubernetes stopped routing traffic.
- The 502 is honest: "no healthy upstream", not a broken response from a pod
  that should have known better.

And it self-heals with no intervention:

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
kubectl rollout status deployment/postgres -n devboard
sleep 20
kubectl get pods,endpoints -n devboard -l app=backend
curl -s -o /dev/null -w "API: %{http_code}\n" http://localhost:30080/api/tasks   # 200
```

Pods rejoined the Service the moment their dependency returned. No restarts, no
human.

### Step 3: The proper fix, for comparison

An external probe cannot see whether the app's *own connection pool* is healthy
— only whether the port is open. The right long-term answer is a real endpoint.
About ten lines in `main.go`:

```go
r.GET("/ready", func(c *gin.Context) {
    ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
    defer cancel()
    if err := db.PingContext(ctx); err != nil {
        c.JSON(http.StatusServiceUnavailable, gin.H{"status": "not-ready", "error": err.Error()})
        return
    }
    c.JSON(http.StatusOK, gin.H{"status": "ready"})
})
```

Then the probe becomes a cheap `httpGet` on `/ready`. Full instructions and the
patch are in `solution/OPTIONAL-add-ready-endpoint.md` — a good exercise if you
want to practise the build-and-load loop from Day 08 on a real code change.

**Know both.** Interviewers ask "what if you cannot change the application?"
and the exec-probe answer is what they are looking for.

### Step 4: Watch liveness restart a genuinely wedged container

Use a deliberately broken pod so you can see the mechanism without breaking your
stack:

```bash
kubectl apply -f solution/02-liveness-demo.yaml
kubectl get pods -n devboard -l demo=liveness -w      # Ctrl-C after ~2 min
```

The container creates `/tmp/healthy`, then deletes it after 30 seconds. The
liveness probe `cat`s that file.

```
NAME             READY   STATUS    RESTARTS   AGE
liveness-demo    1/1     Running   0          35s
liveness-demo    1/1     Running   1          65s     <- restarted
liveness-demo    1/1     Running   2          95s     <- and again
```

```bash
kubectl describe pod liveness-demo -n devboard | grep -A5 Events
# Warning  Unhealthy  Liveness probe failed: cat: can't open '/tmp/healthy'
# Normal   Killing    Container failed liveness probe, will be restarted
```

Note that `RESTARTS` climbs while `READY` stays `1/1` — the container is
restarted in place, in the same pod, keeping its name and IP. Liveness never
reschedules a pod to another node.

```bash
kubectl delete pod liveness-demo -n devboard
```

### Step 5: Readiness as a traffic switch, with no restart

```bash
kubectl apply -f solution/03-readiness-demo.yaml
kubectl get pods,endpoints -n devboard -l demo=readiness -w   # Ctrl-C when Ready
```

The container is ready for 30 seconds, then removes its marker file:

```
readiness-demo   1/1   Running   0   30s     ENDPOINTS: 10.244.1.20:80
readiness-demo   0/1   Running   0   45s     ENDPOINTS: <none>
```

**`RESTARTS` stays 0.** The container is untouched — only its Service membership
changed. That is the entire difference between the two probes, in one screen.

```bash
kubectl delete -f solution/03-readiness-demo.yaml
```

### Step 6: Startup probes for a slow starter

```bash
kubectl apply -f solution/04-startup-probe-demo.yaml
kubectl get pods -n devboard -l demo=startup -w
```

The container sleeps 60 seconds before listening. Without a startup probe, a
liveness probe with `failureThreshold: 3, periodSeconds: 10` would kill it at
30 seconds — forever, an infinite restart loop.

With the startup probe it gets 150 seconds to boot, then liveness takes over
with a tight 30-second detection window.

```bash
kubectl describe pod -n devboard -l demo=startup | grep -E "Startup|Liveness"
kubectl delete -f solution/04-startup-probe-demo.yaml
```

### Step 7: Graceful shutdown

```bash
kubectl apply -f solution/05-backend-graceful.yaml
kubectl rollout status deployment/backend -n devboard
```

The addition:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
terminationGracePeriodSeconds: 30
```

Test it under continuous load. Terminal 1:

```bash
while true; do
  curl -s -o /dev/null -w "%{http_code} " http://localhost:30080/api/tasks
  sleep 0.2
done
```

Terminal 2:

```bash
kubectl rollout restart deployment/backend -n devboard
```

You should see an unbroken stream of `200`s. Remove the `preStop` hook and run
it again — with only two replicas and fast pod churn, occasional `502`s appear
as a pod dies before every node's kube-proxy has removed it from the endpoints.

---

## Validate

```bash
kubectl apply -f ../day-12-wire-the-three-tier-app/solution/
kubectl apply -f solution/01-backend-probes-exec.yaml
kubectl rollout status deployment/backend -n devboard --timeout=120s

# 1. all Ready with a healthy database
kubectl get pods -n devboard -l app=backend

# 2. readiness reacts to a dependency, liveness does not
kubectl scale deployment postgres --replicas=0 -n devboard
sleep 30
kubectl get pods -n devboard -l app=backend \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
# READY=false, RESTARTS=0    <- the point of the whole day
kubectl get endpoints backend -n devboard          # <none>

# 3. it self-heals
kubectl scale deployment postgres --replicas=1 -n devboard
sleep 40
kubectl get endpoints backend -n devboard          # populated again
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks
```

Ready for Day 14 when you can:

1. State what happens on liveness failure vs readiness failure.
2. Explain why a liveness probe must never check a dependency.
3. Compute detection time from `periodSeconds` and `failureThreshold`.
4. Explain what a startup probe is for and what it suspends.

---

## Break it

**A. Make liveness check the database — the classic outage.**

```bash
kubectl apply -f solution/06-backend-BAD-liveness.yaml
kubectl rollout status deployment/backend -n devboard

kubectl scale deployment postgres --replicas=0 -n devboard
kubectl get pods -n devboard -l app=backend -w     # Ctrl-C after ~2 min
```

```
backend-...   0/1   Running            0
backend-...   0/1   Running            1
backend-...   0/1   CrashLoopBackOff   2
backend-...   0/1   CrashLoopBackOff   3
```

Every backend pod now restarts on a loop. When Postgres returns, all of them
reconnect simultaneously and hammer it. **You converted a database blip into a
restart storm.** This is section 13.2, live.

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
kubectl apply -f solution/01-backend-probes-exec.yaml
```

**B. A readiness probe pointed at a path that does not exist.**

```bash
kubectl patch deployment backend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"backend","readinessProbe":{"httpGet":{"path":"/healthz","port":8080},"periodSeconds":2}}]}}}}'

kubectl get pods -n devboard -l app=backend        # 0/1 Ready, forever
kubectl get endpoints backend -n devboard          # <none>
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks   # 502
```

`/healthz` does not exist — the Gin route is `/health`. Your entire service is
offline while every pod reports `Running` and every log looks clean. A one-letter
difference, a total outage. **This is one of the most common self-inflicted
Kubernetes incidents there is.**

```bash
kubectl apply -f solution/01-backend-probes-exec.yaml
```

**C. `initialDelaySeconds` too short.**

```bash
kubectl patch deployment backend -n devboard -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"backend","livenessProbe":{"httpGet":{"path":"/health","port":8080},"initialDelaySeconds":0,"periodSeconds":1,"failureThreshold":1}}]}}}}'

kubectl get pods -n devboard -l app=backend -w
```

The container is killed before it can bind its port, restarted, killed again —
an infinite loop caused entirely by probe timing. This is exactly what startup
probes exist to prevent.

```bash
kubectl apply -f solution/01-backend-probes-exec.yaml
```

**D. `timeoutSeconds` too aggressive under load.**

Set `timeoutSeconds: 1` (the default) on an endpoint that occasionally takes
1.5 seconds under load, and the pod is restarted exactly when it is busiest —
reducing capacity, which increases load on the survivors, which makes them slow
too. A cascading failure caused by a health check. Always set `timeoutSeconds`
deliberately rather than inheriting the default.

---

## Interview questions

<details>
<summary><b>1. Difference between liveness and readiness probes?</b></summary>

Liveness answers "is this process wedged?" and failure causes the kubelet to
kill and restart the container. Readiness answers "can this pod serve traffic
right now?" and failure removes it from the Service endpoints without any
restart. Liveness is for unrecoverable in-process states; readiness is for
temporary inability to serve, including dependency outages.
</details>

<details>
<summary><b>2. Should a liveness probe check the database?</b></summary>

No, and this is the most important probe rule. If it did, a brief database
outage would fail liveness on every pod at once, so Kubernetes would restart
them all, and they would reconnect simultaneously and overwhelm the recovering
database - turning a blip into a self-sustaining outage. Dependency health
belongs in the readiness probe, which takes pods out of rotation without
restarting them.
</details>

<details>
<summary><b>3. What is a startup probe for?</b></summary>

Slow-starting applications. While it is running, liveness and readiness are
suspended, so a JVM taking 90 seconds to boot is not killed by a liveness probe
with a 30-second detection window. Once it passes, it never runs again. It lets
you be generous at startup and strict afterwards, instead of using a huge
initialDelaySeconds that also delays detection of a genuinely hung container.
</details>

<details>
<summary><b>4. How long before a failing container is restarted?</b></summary>

Roughly `periodSeconds x failureThreshold`, plus up to one period of latency,
plus `initialDelaySeconds` for the very first check. With defaults - period 10,
threshold 3 - that is up to about 30 seconds. Tightening it detects faster but
increases the chance of restarting a container that was merely slow.
</details>

<details>
<summary><b>5. Your app is fine but every pod shows 0/1 Ready. Where do you look?</b></summary>

The readiness probe. `kubectl describe pod` shows the exact probe failure in
Events. Usual causes: a path that does not exist - `/healthz` when the route is
`/health` - the wrong port or port name, the app binding 127.0.0.1 instead of
0.0.0.0 so the kubelet cannot reach it, a timeout too short for the response, or
a dependency check failing. The Service will have no endpoints, so the symptom
is a total outage with everything reporting Running.
</details>

<details>
<summary><b>6. You cannot modify a third-party image to add a /ready endpoint. What now?</b></summary>

Use an exec readiness probe that verifies the dependency from inside the
container - a TCP check, a CLI health command, or a small script. Alternatively
run a sidecar that performs a richer check and exposes it over HTTP for the
probe. Both are worse than a real endpoint, because only the application knows
whether its own connection pool is healthy, but both work without touching the
image.
</details>

<details>
<summary><b>7. How do probes relate to zero-downtime deployments?</b></summary>

During a rolling update a new pod must pass its readiness probe before an old
pod is removed. Without a readiness probe, Ready means only that the process
started, so traffic is routed to containers that are not listening yet. The
other half is graceful shutdown: endpoint removal and SIGTERM happen in
parallel, so without a preStop delay a pod can stop accepting connections while
some nodes are still sending traffic to it.
</details>

<details>
<summary><b>8. What does terminationGracePeriodSeconds do?</b></summary>

It is the time between SIGTERM and SIGKILL - default 30 seconds - and it
includes the preStop hook. The application should use it to finish in-flight
requests and close connections cleanly. Too short and long requests are severed;
too long and rolling updates and node drains crawl.
</details>

<details>
<summary><b>9. exec probes vs httpGet probes?</b></summary>

`exec` forks a process inside the container on every check, which is
significantly more expensive at scale and can itself cause CPU pressure with
short periods and many pods. `httpGet` is handled by the kubelet with no process
creation. Use exec only when there is no HTTP endpoint to check - databases with
CLI health tools being the usual case.
</details>

---

## Cheat card

```yaml
# The canonical shape
startupProbe:                     # generous: let it boot
  httpGet: { path: /health, port: http }
  failureThreshold: 30
  periodSeconds: 5                # 150s budget

livenessProbe:                    # THIS PROCESS ONLY. Never a dependency.
  httpGet: { path: /health, port: http }
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3             # ~30s to detect a hang

readinessProbe:                   # dependencies belong HERE
  httpGet: { path: /ready, port: http }
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 2             # ~10s to leave rotation

lifecycle:
  preStop:
    exec: { command: ["sh", "-c", "sleep 5"] }
terminationGracePeriodSeconds: 30
```

```bash
kubectl get pods -n devboard      # the READY column IS the readiness probe
kubectl describe pod <pod> -n devboard | grep -A5 -i probe
kubectl get endpoints backend -n devboard        # who is actually in rotation
kubectl get events -n devboard --field-selector reason=Unhealthy
```

| Field | Default | Note |
|---|---|---|
| `initialDelaySeconds` | 0 | prefer a startup probe over a large value |
| `periodSeconds` | 10 | |
| `timeoutSeconds` | 1 | aggressive; raise it deliberately |
| `failureThreshold` | 3 | detection time = period x threshold |
| `successThreshold` | 1 | must be 1 for liveness and startup |

---

**Next: [Day 14 - Volumes, PV and PVC](../day-14-volumes-pv-pvc/)**
