# Day 12 — Wire the Three Tiers Together

**Time:** 60-75 minutes
**Prerequisites:** Days 08-11

Everything exists. Today you assemble it into one deployable unit, trace a
single request from your browser to Postgres and back, and learn the
init-container pattern that replaces `depends_on`.

---

## Part 1 - Concepts

### 12.1 The full request path

Trace this until you can recite it. It is the best single summary of everything
in weeks 1 and 2.

```
 1. Browser        GET http://localhost:30080/api/tasks
                        |
 2. Docker         kind extraPortMapping: host 30080 -> node container 30080
                        |
 3. NodePort       kube-proxy iptables rule on the node
                        |
 4. Service        devboard-frontend   (port 80 -> targetPort 4173)
                        |
 5. Pod            vite preview, listening on :4173
                        |
 6. vite proxy     /api/tasks  ->  http://backend:8080/tasks
                                   ^^^^^^^          ^^^^^^
                                   Service name     /api STRIPPED
                        |
 7. CoreDNS        backend -> backend.devboard.svc.cluster.local -> ClusterIP
                        |
 8. Service        backend   (port 8080 -> targetPort 8080)
                        |
 9. Pod            Go + Gin, listening on :8080, route GET /tasks
                        |
10. App            database/sql opens POSTGRES_URL
                   postgres://devboard:***@postgres:5432/devboard
                        |
11. CoreDNS        postgres -> ClusterIP
                        |
12. Service        postgres  (5432 -> 5432)
                        |
13. Pod            postgres:16-alpine, SELECT ... FROM tasks
                        |
                   ...and all the way back as JSON
```

Every hop is something you built: NodePort (07), Services and DNS (06), labels
and selectors (04), ConfigMap (09), Secret (10).

**Note hop 6 carefully.** The browser asks for `/api/tasks`; the Go backend has
no `/api` prefix at all — its route is `GET /tasks`. vite rewrites the path on
the way through. If you ever bypass the frontend and call the backend directly,
drop the `/api`.

### 12.2 Why the frontend proxies instead of the browser calling the backend

You *could* expose the backend on its own NodePort. Proxying through the
frontend is better because:

- **One origin.** No CORS configuration, no preflight requests. The DevBoard
  API client (`frontend/src/api/client.js`) calls plain relative paths like
  `/api/tasks` precisely because of this.
- **One exposed surface.** The backend stays `ClusterIP` — completely
  unreachable from outside the cluster.
- **The browser needs no cluster knowledge.** Nothing to configure per
  environment.

That is the **backend-for-frontend / gateway** shape, and it is what an Ingress
does at cluster level on Day 20 — at which point the vite proxy becomes
redundant.

### 12.3 Startup ordering: Kubernetes has no `depends_on`

`docker-compose.yml` says:

```yaml
depends_on:
  postgres:
    condition: service_healthy
```

Kubernetes deliberately has no equivalent, because it assumes **applications
should tolerate their dependencies being temporarily absent**. That is the more
resilient design: dependencies fail at runtime too, not only at startup.

Three mechanisms, in increasing order of quality:

**1. Application retry logic.** DevBoard's Go backend already does this:

```go
for i := 0; i < 30; i++ {
    if err = db.Ping(); err == nil { break }
    log.Printf("[backend] waiting for postgres (%d)…", i+1)
    time.Sleep(2 * time.Second)
}
if err != nil { log.Fatalf("[backend] FATAL ping db: %v", err) }
```

60 seconds of tolerance, then it exits and Kubernetes restarts it — which is why
you saw `CrashLoopBackOff` on Day 08 rather than a hung pod. Crucially this also
survives a database restart *after* startup, which the other two do not.

**2. Init containers.** Run to completion before app containers start:

```yaml
initContainers:
  - name: wait-for-postgres
    image: postgres:16-alpine
    command: ['sh','-c','until pg_isready -h postgres -U devboard; do sleep 2; done']
```

They run **sequentially**, each must exit 0, and a failing one shows as
`Init:CrashLoopBackOff`. This is the closest analogue to `depends_on`.

**3. Readiness probes.** Keep a pod out of Service endpoints until it can serve.
DevBoard's `/health` does not check the database, so its readiness probe cannot
express "the database is reachable" — that gap is Day 13's whole subject.

Use all three where you can. Today you add the init container.

### 12.4 Init containers vs sidecars

| | init container | sidecar |
|---|---|---|
| When | before app containers, sequentially | alongside app containers |
| Lifetime | runs to completion, exits | the pod's lifetime |
| Failure | pod restarts and retries | depends on restartPolicy |
| Typical use | wait for a dependency, migrate a schema, fix permissions | log shipper, mesh proxy, metrics exporter |

Kubernetes 1.28+ added **native sidecars**: an init container with
`restartPolicy: Always` starts before the app containers *and keeps running* —
which finally solves "the mesh proxy must be up before my app starts, but must
not block pod completion".

### 12.5 One file or many?

You now have nine manifests. Four ways to organise them:

| Approach | Looks like | Good for |
|---|---|---|
| Many files, one dir | `kubectl apply -f solution/` | this course, small apps |
| One file, `---` separated | `kubectl apply -f all-in-one.yaml` | demos, sharing a whole app |
| Kustomize | `base/` + `overlays/dev|prod` | real multi-environment work |
| Helm | a templated chart | anything you distribute |

`kubectl apply -f <dir>` applies files in **alphabetical order**, which is why
the solution files are numbered `01-`, `02-` and so on. Ordering mostly does not
matter — Kubernetes reconciles eventually regardless — but it avoids a minute of
confusing errors on first apply.

---

## Part 2 - Hands-on lab

### Step 1: Deploy the whole stack from a clean namespace

The real test of whether your manifests are complete: throw everything away and
bring it back with one command.

```bash
kubectl delete namespace devboard --wait=true
kubectl apply -f solution/
kubectl get all -n devboard
```

Watch it converge:

```bash
kubectl get pods -n devboard -w
```

Postgres becomes Ready first; the backends sit in `Init:0/1` until their init
container sees `pg_isready` succeed; then the frontends.

```bash
kubectl rollout status deployment/postgres -n devboard
kubectl rollout status deployment/backend  -n devboard
kubectl rollout status deployment/frontend -n devboard
```

Open <http://localhost:30080>. The Kanban board, with two projects and ten
tasks. Create a task; it persists.

### Step 2: Watch the init container do its job

```bash
kubectl describe pod -n devboard -l app=backend | grep -A12 "Init Containers"
kubectl logs -n devboard -l app=backend -c wait-for-postgres
```

Now make it wait for real:

```bash
kubectl scale deployment postgres --replicas=0 -n devboard
kubectl rollout restart deployment/backend -n devboard

kubectl get pods -n devboard -l app=backend
# STATUS: Init:0/1

kubectl logs -n devboard -l app=backend -c wait-for-postgres --tail=5
# postgres:5432 - no response   (repeating)
```

The app container has not started at all — no CrashLoopBackOff, no log noise,
just a clear "waiting on a dependency" state. Bring Postgres back:

```bash
kubectl scale deployment postgres --replicas=1 -n devboard
kubectl rollout status deployment/backend -n devboard
```

Compare that with Day 08, where the same missing dependency produced
`CrashLoopBackOff`. Same underlying situation, far more legible failure. That is
what the init container bought you.

### Step 3: Trace one request through every hop

```bash
# hop 3-5: NodePort -> frontend Service -> frontend pods
kubectl get svc devboard-frontend -n devboard
kubectl get endpoints devboard-frontend -n devboard

# hop 6: the proxy rule, read from inside a running frontend pod
kubectl exec -n devboard deploy/frontend -- cat /app/vite.config.js

# hop 7: DNS
kubectl exec -n devboard deploy/frontend -- cat /etc/resolv.conf

# hop 8-9: the backend Service and its pods
kubectl get svc,endpoints backend -n devboard

# hop 10: what the backend thinks its database is
kubectl exec -n devboard deploy/backend -- env | grep POSTGRES_URL

# hop 11-13: the database Service and the data itself
kubectl get svc,endpoints postgres -n devboard
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
```

Now walk the same path with live requests, from progressively further in. **This
bisection is the debugging technique** — it finds the failing hop in four
commands instead of guesswork:

```bash
# 1. from your laptop, through everything
curl -s http://localhost:30080/api/tasks | head -c 200; echo

# 2. from inside the cluster, skipping the NodePort
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- devboard-frontend:80/api/tasks | head -c 200

# 3. straight to the backend, skipping vite  (NOTE: no /api prefix!)
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- backend:8080/tasks | head -c 200

# 4. straight to Postgres, skipping the backend
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"
```

Step 3 is where the `/api` rewrite becomes real: `backend:8080/api/tasks` returns
404, `backend:8080/tasks` returns JSON. Try both.

### Step 4: See load balancing across backends

```bash
kubectl scale deployment backend --replicas=4 -n devboard
kubectl rollout status deployment/backend -n devboard

# which pod served each request? watch the backend logs while you curl
kubectl logs -n devboard -l app=backend -f --prefix --tail=1 &
for i in $(seq 1 12); do curl -s -o /dev/null http://localhost:30080/api/tasks; done
sleep 2; kill %1
```

The `--prefix` flag prints the pod name before each line, so you can see
requests spreading across pods. It is **not** perfectly round-robin: routing is
random per connection, and HTTP keep-alive means consecutive requests often
reuse a connection and land on the same pod. That is the L4 caveat from Day 06,
visible on real traffic.

### Step 5: Kill things and watch what survives

```bash
# a frontend pod - the browser barely notices
kubectl delete pod -n devboard -l app=frontend --wait=false
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080

# all backends - the API fails, the UI still loads
kubectl delete pod -n devboard -l app=backend --wait=false
curl -s -o /dev/null -w "UI:  %{http_code}\n"  http://localhost:30080
curl -s -o /dev/null -w "API: %{http_code}\n"  http://localhost:30080/api/tasks   # 502
sleep 30
curl -s -o /dev/null -w "API: %{http_code}\n"  http://localhost:30080/api/tasks   # 200
```

The UI staying up while the API is down is the tiering working: the frontend has
no dependency on the backend *to serve pages*, only *to fetch data*.

Now the interesting one:

```bash
kubectl delete pod -n devboard -l app=postgres --wait=false
sleep 15
kubectl get pods -n devboard
```

Look at the backend pods. With DevBoard's `/health` probe — which does **not**
touch the database — they stay `1/1 Ready` with `RESTARTS: 0`. They remain in
the Service endpoints and happily accept requests they cannot serve:

```bash
curl -s -o /dev/null -w "API: %{http_code}\n" http://localhost:30080/api/tasks
kubectl logs -n devboard -l app=backend --tail=5
```

**That is a bug in the probe design, not in Kubernetes**, and it is exactly what
Day 13 fixes. A readiness probe that reflected database connectivity would have
pulled these pods out of rotation instead of returning 500s to users.

Note also the data loss when Postgres returns — still `emptyDir`. Day 14.

### Step 6: Package it as one file

```bash
kubectl kustomize solution/ > /tmp/devboard-all.yaml 2>/dev/null \
  || cat solution/*.yaml > /tmp/devboard-all.yaml

kubectl delete namespace devboard --wait=true
kubectl apply -f solution/00-namespace.yaml
kubectl apply -f solution/
kubectl get all -n devboard
```

`solution/all-in-one.yaml` is the same manifests concatenated with `---`
separators — handy for sharing an entire application in one paste.

### Step 7: Compare with docker-compose, honestly

Open `app/devboard/docker-compose.yml` next to `solution/` and count.

| Concern | compose | Kubernetes |
|---|---|---|
| Define the app | 45 lines | ~250 lines |
| Start ordering | `depends_on` + `condition` | init container |
| Config | `.env` + `environment:` | ConfigMap + Secret |
| Expose | `ports:` | Service + NodePort |
| Persistence | `volumes: pgdata:` | PVC (Day 14) |
| Health | `healthcheck:` | liveness + readiness probes |
| Scale | `--scale backend=4` | `replicas` / HPA |
| Self-healing | restart policy | ReplicaSet controller |
| Rolling update | none | built in |
| Multi-machine | no | yes |

Kubernetes is roughly five times the YAML. Be honest about that in interviews:
for a single machine, compose is the better tool. Kubernetes earns its
complexity at multiple nodes, multiple teams, real scaling and zero-downtime
deploys — which is what the rest of this course is about.

---

## Validate

```bash
kubectl delete namespace devboard --wait=true
kubectl apply -f solution/
kubectl rollout status deployment/postgres -n devboard --timeout=180s
kubectl rollout status deployment/backend  -n devboard --timeout=180s
kubectl rollout status deployment/frontend -n devboard --timeout=180s

kubectl get pods -n devboard
kubectl get endpoints -n devboard

curl -s -o /dev/null -w "UI:       %{http_code}\n" http://localhost:30080
curl -s -o /dev/null -w "tasks:    %{http_code}\n" http://localhost:30080/api/tasks
curl -s -o /dev/null -w "projects: %{http_code}\n" http://localhost:30080/api/projects
curl -s http://localhost:30080/api/tasks | head -c 200; echo
```

All three should be 200, all pods Ready, all endpoints populated.

Ready for Day 13 when you can:

1. Recite the 13 hops from browser to database.
2. Explain what happens to `/api` between the browser and the Go router.
3. Give three ways to handle startup ordering, and why Kubernetes has no
   `depends_on`.
4. Explain why the backend pods stayed Ready when Postgres died, and why that
   is wrong.

---

## Break it

**A. Break the vite proxy target.**

```bash
kubectl apply -f ../day-09-configmaps/solution/04-vite-config-configmap.yaml
kubectl apply -f ../day-09-configmaps/solution/05-frontend-deployment-mounted.yaml
kubectl rollout status deployment/frontend -n devboard

curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks   # 502
```

The ConfigMap points at `devboard-backend`, which does not exist in this
namespace. Everything is healthy; one hostname is wrong. Restore:

```bash
kubectl apply -f solution/06-frontend-deployment.yaml
```

**B. Forget the `/api` rewrite.**

```bash
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- backend:8080/api/tasks
# 404 page not found
```

The Gin router has no `/api` prefix. If you ever move this behind an Ingress
(Day 20), you must reproduce the strip — a `rewrite-target` annotation on
ingress-nginx, or a `URLRewrite` filter in the Gateway API. Forgetting it is one
of the most common Ingress bugs.

**C. Point the backend at a database that does not exist.**

```bash
kubectl set env deployment/backend -n devboard \
  POSTGRES_URL='postgres://devboard:devboard@nowhere:5432/devboard?sslmode=disable'

kubectl get pods -n devboard -l app=backend -w     # Ctrl-C after ~90s
kubectl logs -n devboard -l app=backend --tail=3
```

Init container passes (Postgres *is* up), then the app retries 30 times and
`log.Fatalf`s. `CrashLoopBackOff`. Note the init container checked the *right*
database while the app used the *wrong* one — a reminder that an init container
only proves what you told it to check.

```bash
kubectl rollout undo deployment/backend -n devboard
```

**D. Delete the namespace mid-traffic.**

```bash
kubectl delete namespace devboard
kubectl get ns devboard        # Terminating, then gone
```

One command, entire application gone, no confirmation. Rebuild it:

```bash
kubectl apply -f solution/
```

The fact that this takes 90 seconds to fully rebuild — from an empty cluster to
a working three-tier app — is the actual payoff of everything you have done.

---

## Interview questions

<details>
<summary><b>1. Walk me through what happens when a user loads your app.</b></summary>

The browser hits a NodePort on any node; kube-proxy DNATs it to the frontend
Service's endpoints and on to a pod. The frontend serves the SPA. The SPA's
XHR to `/api/tasks` goes back to the same origin, where the frontend proxies it
to `http://backend:8080/tasks` - CoreDNS resolves the Service name to a
ClusterIP, kube-proxy picks a backend pod. The backend opens a connection using
its DSN, resolving the `postgres` Service the same way, queries, and the JSON
returns along the same path.
</details>

<details>
<summary><b>2. Kubernetes has no depends_on. How do you order startup?</b></summary>

You mostly do not - you design applications to tolerate absent dependencies,
because dependencies also fail at runtime. Where ordering genuinely matters, an
init container blocks until the dependency answers. Readiness probes keep a pod
out of Service endpoints until it can serve, and application-level retry with
backoff is the most robust because it survives dependency restarts after
startup, not only before. Use all three.
</details>

<details>
<summary><b>3. Init container vs sidecar?</b></summary>

An init container runs to completion before any app container starts, and they
run sequentially - used for waiting on dependencies, running migrations, fixing
volume permissions. A sidecar runs alongside for the pod's lifetime - log
shippers, mesh proxies, metric exporters. Since 1.28 a native sidecar is an init
container with `restartPolicy: Always`, which starts before the app containers
and keeps running.
</details>

<details>
<summary><b>4. Your frontend returns 502 for API calls. How do you debug it?</b></summary>

Bisect from the inside out. Query the database directly; then call the backend
Service from a pod in the cluster; then call the frontend Service from a pod;
then from outside. The first hop that fails localises the fault. Alongside that,
`kubectl get endpoints` on each Service - `<none>` means a selector or readiness
problem - and check the proxy target the frontend is actually configured with,
since a hostname that no longer resolves produces exactly this symptom with
every workload healthy.
</details>

<details>
<summary><b>5. Why proxy the API through the frontend instead of exposing it?</b></summary>

Single origin, so no CORS and no preflight. A smaller attack surface, since the
backend stays ClusterIP and is unreachable from outside. And the browser needs
no per-environment configuration because it calls relative paths. At cluster
scale, an Ingress or Gateway does the same job for many services at once, with
TLS termination and routing in one place.
</details>

<details>
<summary><b>6. When would you NOT use Kubernetes for this app?</b></summary>

A single machine, one team, modest steady traffic - `docker compose` does the
same job in a fifth of the configuration with a fraction of the operational
burden. Kubernetes earns its complexity with multiple nodes, self-healing across
node failures, zero-downtime rollouts, autoscaling, and many teams sharing
infrastructure with RBAC and quotas. Being able to say when it is the wrong tool
is a strong signal.
</details>

<details>
<summary><b>7. How do you organise manifests across environments?</b></summary>

Kustomize with a `base/` and per-environment `overlays/` is the standard
lightweight answer - patches change replicas, resources and image tags without
duplicating the base. Helm when you need templating, conditionals and
distribution to others. Avoid copy-pasted directories per environment; they
diverge silently. Whatever you choose, the manifests belong in git and get
applied by CI or a GitOps controller, not from a laptop.
</details>

---

## Cheat card

```bash
# deploy everything
kubectl apply -f solution/
kubectl get all -n devboard

# the bisection ladder
curl -s http://localhost:30080/api/tasks                                    # outside
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- devboard-frontend:80/api/tasks                                  # in-cluster, via frontend
kubectl run t --rm -i -n devboard --image=busybox:1.36 --restart=Never -- \
  wget -qO- backend:8080/tasks                                              # direct, NO /api
kubectl exec -n devboard deploy/postgres -- \
  psql -U devboard -d devboard -tAc "SELECT count(*) FROM tasks;"           # database

# init containers
kubectl logs -n devboard <pod> -c wait-for-postgres
kubectl describe pod -n devboard <pod> | grep -A12 "Init Containers"

# logs from every pod of a workload, labelled
kubectl logs -n devboard -l app=backend -f --prefix --tail=20
```

| Symptom | Most likely |
|---|---|
| `Init:0/1` | init container still waiting on a dependency |
| `Init:CrashLoopBackOff` | init container exiting non-zero |
| UI loads, API 502 | proxy target wrong, or backend has no endpoints |
| API 404 | `/api` prefix not stripped |
| Backend `CrashLoopBackOff` | cannot reach the database within its retry budget |

---

**Next: [Day 13 - Health probes](../day-13-health-probes/)**
