# Day 08 — Build & Load the DevBoard Images

**Time:** 60-75 minutes
**Prerequisites:** Days 01-07, plus `git` and a working Docker

Until now you have deployed stock `nginx`. From today you deploy a **real
application** — and every remaining day builds on it.

---

## Part 1 - Concepts

### 8.1 Meet DevBoard

[DevBoard](https://github.com/t-node/devboard) is a project-and-task tracker: a
Kanban board with projects, tasks, statuses and priorities. Three tiers:

```
browser ──▶ frontend ──/api──▶ backend ──▶ postgres
            React+Vite         Go+Gin       16-alpine
            :4173              :8080        :5432
```

The complete contract — every route, every environment variable, every port —
is in **[app/README.md](../../app/README.md)**. Read it once now; you will refer
back to it constantly.

The three facts that shape the next 13 days:

**1. The backend takes one `POSTGRES_URL`, not separate variables.**

```
POSTGRES_URL=postgres://devboard:devboard@postgres:5432/devboard?sslmode=disable
```

One string, containing the password. That is awkward for the clean
ConfigMap/Secret split — and the solution (Day 10) teaches you a genuinely
useful Kubernetes technique.

**2. `/health` does not check the database.**

```go
r.GET("/health", func(c *gin.Context) {
    c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "backend"})
})
```

It returns 200 whenever the process is alive. Perfect as a **liveness** probe.
Insufficient as a **readiness** probe — and Day 13 is about that exact gap.

**3. The frontend's proxy target is baked into the image.**

`vite.preview.config.js`, compiled into the image at build time:

```js
preview: {
  proxy: {
    "/api": {
      target: "http://backend:8080",
      rewrite: (path) => path.replace(/^\/api/, ""),
    },
  },
}
```

So the browser calls `/api/tasks`, vite rewrites it to `/tasks` and forwards it
to `http://backend:8080/tasks`.

> **Consequence: your backend Service must be named exactly `backend`, on port
> 8080, in the same namespace.** Name it `devboard-backend` and the frontend
> returns 502 while every pod looks perfectly healthy.

That is not a bug in the app. **A Service name is an API contract.** Day 09
shows you how to override it from a ConfigMap when you cannot rename.

### 8.2 How a node gets an image

The kubelet asks containerd for the image. containerd checks its **local store
on that node** and pulls from a registry only if it is missing. The registry
comes from the image name:

| Image name | Pulls from |
|---|---|
| `postgres:16-alpine` | `docker.io/library/postgres:16-alpine` |
| `ghcr.io/me/api:1.0` | GitHub Container Registry |
| `devboard-backend:1.0` | **`docker.io/library/devboard-backend:1.0`** — does not exist |

That last row is the trap: an image name with no registry prefix means Docker
Hub, so a locally built image will be looked for there and you get
`ImagePullBackOff`.

### 8.3 Why `docker build` alone is not enough

Your kind "nodes" are Docker containers, each with **its own** containerd image
store. An image in *your laptop's* Docker daemon is invisible to them.

| Approach | Command | When |
|---|---|---|
| **`kind load docker-image`** | `kind load docker-image x:1.0 --name devops` | **this course** |
| Push to a registry | `docker push ghcr.io/you/x:1.0` | real clusters, CI/CD |
| Local registry container | run a registry on the kind network | fast iterate loops |

### 8.4 imagePullPolicy — the setting that decides whether this works

| Value | Behaviour |
|---|---|
| `Always` | pull from the registry every time a container starts |
| `IfNotPresent` | use the local copy if present, else pull |
| `Never` | only ever use a local copy; fail if absent |

**The defaults are implicit, and that is the trap:**

- tag `:latest` or omitted → default **`Always`**
- any other tag → default **`IfNotPresent`**

So `devboard-backend:1.0` would work by accident. Rely on that and the day
someone writes `:latest`, the pod breaks. **Always set
`imagePullPolicy: IfNotPresent` explicitly** for kind-loaded images. Every
manifest in this course does.

### 8.5 Why this repo ships its own Dockerfiles

Upstream builds `FROM dhi.io/golang:1-alpine-dev` and `FROM dhi.io/node:26-dev`
— **Docker Hardened Images**, which require an entitled Docker organisation.
Without one, `docker build` fails on the very first `FROM`:

```
ERROR: failed to authorize: failed to fetch oauth token: unexpected status: 401
```

`app/dockerfiles/backend.Dockerfile` and `frontend.Dockerfile` are functionally
identical builds on public bases (`golang:1.23-alpine`, `node:22-alpine`,
`alpine:3.20`). The backend runtime is Alpine rather than distroless
specifically so it **has a shell** and `kubectl exec -it -- sh` works during the
debugging days.

If you *do* have DHI access, build the upstream Dockerfiles — every manifest in
this course still applies unchanged.

---

## Part 2 - Hands-on lab

### Step 1: Fetch the source and read it

```bash
bash app/get-devboard.sh
# PowerShell: .\app\get-devboard.ps1
```

Spend ten minutes here. Every manifest for the next 13 days configures this
code:

```bash
sed -n '69,86p'  app/devboard/backend/main.go    # routes + PORT
sed -n '44,67p'  app/devboard/backend/main.go    # POSTGRES_URL + the retry loop
cat app/devboard/frontend/vite.preview.config.js # the /api -> backend:8080 proxy
cat app/devboard/init/postgres/01_schema.sql     # projects + tasks
cat app/devboard/docker-compose.yml              # what you are about to port
cat app/devboard/.env.example                    # the variables that exist
```

Read `docker-compose.yml` with the translation table in mind:

| docker-compose | Kubernetes |
|---|---|
| `services:` | one Deployment + one Service per tier |
| `environment:` | ConfigMap (Day 09) + Secret (Day 10) |
| `ports: "8080:4173"` | Service `type: NodePort` (Day 07) |
| service name `backend` | Service named `backend` + CoreDNS (Day 06) |
| `depends_on: service_healthy` | init container + readiness probe (Days 12-13) |
| `volumes: pgdata:` | PersistentVolumeClaim (Day 14) |
| `healthcheck:` | liveness / readiness probes (Day 13) |

That table *is* the rest of the course.

### Step 2: Run it in Compose first (optional but strongly recommended)

Seeing it work in the model you already know makes every Kubernetes failure
interpretable:

```bash
cd app/devboard
cp .env.example .env
docker compose up --build     # first build takes a few minutes
```

Open <http://localhost:8080> — the Kanban board, seeded with 2 projects and 10
tasks. Then:

```bash
curl -s localhost:8081/health
curl -s localhost:8081/tasks | head -c 300; echo
docker compose down -v
cd ../..
```

Note the backend is on **8081** on your host (`BACKEND_HOST_PORT`) but **8080**
inside the container. Host ports and container ports being different is the same
idea as `port` vs `targetPort`.

> If `docker compose up` fails with a 401 on `dhi.io`, that is section 8.5.
> Skip Compose and go to Step 3 — the course build works.

### Step 3: Build with the course Dockerfiles

```bash
bash app/build-images.sh 1.0
# PowerShell: .\app\build-images.ps1 -Version 1.0
```

This builds both images and `kind load`s them. First run takes 3-5 minutes
(`go mod download` and `npm ci`).

```bash
docker images | grep devboard
```

```
devboard-backend    1.0   a1b2c3d4e5f6   1 minute ago    23MB
devboard-frontend   1.0   f6e5d4c3b2a1   30 seconds ago  180MB
```

Note the backend is tiny — a static Go binary on Alpine. That is what
multi-stage builds buy you.

### Step 4: Test the images before involving Kubernetes

Debugging a broken image *and* broken manifests simultaneously is miserable.
Rule out the image first:

```bash
docker run --rm -d -p 8080:8080 --name bk-test devboard-backend:1.0
sleep 3
curl -s localhost:8080/health          # {"service":"backend","status":"ok"}
docker logs bk-test | tail -5          # "waiting for postgres (N)..."
docker rm -f bk-test
```

Read that carefully: `/health` returns **200 while Postgres is unreachable**.
The process is alive, so it is "healthy". Remember this for Day 13.

Also note the log: it retries 30 times at 2-second intervals, then calls
`log.Fatalf` and the process exits. So with no database the container will
eventually die and Kubernetes will restart it — a `CrashLoopBackOff` you should
be able to predict before it happens.

```bash
docker run --rm -d -p 4173:4173 --name fe-test devboard-frontend:1.0
sleep 3
curl -s localhost:4173 | head -5                                    # the SPA HTML
curl -s -o /dev/null -w "%{http_code}\n" localhost:4173/api/tasks   # 502
docker rm -f fe-test
```

The 502 is correct: vite tried to proxy to `http://backend:8080`, which does not
resolve outside a Docker network. Inside Kubernetes, with a Service called
`backend`, it will.

### Step 5: Verify the images reached the nodes

Do not trust it — check:

```bash
docker exec devops-worker        crictl images | grep devboard
docker exec devops-worker2       crictl images | grep devboard
docker exec devops-control-plane crictl images | grep devboard
```

`crictl` is the CRI equivalent of `docker images`, and it is what you reach for
when a pod says `ErrImageNeverPull` and you need to know whether the image is
genuinely there.

### Step 6: Deploy the backend (and watch it fail correctly)

```bash
kubectl apply -f solution/01-backend-deployment.yaml
kubectl apply -f solution/02-backend-service.yaml
kubectl get pods -n devboard -l app=backend -w      # Ctrl-C after a minute
```

Watch the sequence:

```
NAME                       READY   STATUS             RESTARTS   AGE
backend-6d4f8c9b5-2xk9p    1/1     Running            0          10s
backend-6d4f8c9b5-2xk9p    0/1     Error              0          70s
backend-6d4f8c9b5-2xk9p    0/1     CrashLoopBackOff   1          85s
```

**You predicted this in Step 4.** There is no Postgres, so after 30 retries the
Go process calls `log.Fatalf` and exits non-zero. Confirm:

```bash
kubectl logs -n devboard -l app=backend --tail=10
kubectl logs -n devboard -l app=backend --previous --tail=5
# [backend] waiting for postgres (30)...
# [backend] FATAL ping db: dial tcp: lookup postgres ... no such host
kubectl describe pod -n devboard -l app=backend | grep -A6 "Last State"
```

`Exit Code: 1`, `Reason: Error`. This is a **correctly diagnosed** failure, not a
mystery — you know exactly what is missing and Day 11 provides it.

Note the Service name in the manifest:

```yaml
metadata:
  name: backend          # NOT devboard-backend. The frontend image demands this.
```

### Step 7: Deploy the frontend

```bash
kubectl apply -f solution/03-frontend-deployment.yaml
kubectl apply -f solution/04-frontend-service.yaml
kubectl rollout status deployment/frontend -n devboard
kubectl get pods,svc -n devboard
```

Open <http://localhost:30080>. The DevBoard UI **loads** — the SPA is static
assets, served happily. But the board is empty and the browser console shows
failing `/api/tasks` calls, because the backend has no endpoints.

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080          # 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks # 502
kubectl get endpoints backend -n devboard                                 # <none>
```

Everything from Day 06 is visible in that last line: not-Ready pods are excluded
from the Service, so there is nothing to proxy to.

### Step 8: Build a v2 so rolling updates work on real code

```bash
bash app/build-images.sh 2.0
kubectl set image deployment/frontend frontend=devboard-frontend:2.0 -n devboard
kubectl rollout status deployment/frontend -n devboard
kubectl rollout undo   deployment/frontend -n devboard
```

Real code, real rollout, real rollback.

---

## Validate

```bash
docker images | grep devboard                            # 1.0 present
docker exec devops-worker crictl images | grep devboard  # on the node too

kubectl apply -f solution/
kubectl rollout status deployment/frontend -n devboard --timeout=120s

kubectl get pods -n devboard -o custom-columns=\
NAME:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase

kubectl get svc backend -n devboard -o jsonpath='{.metadata.name}:{.spec.ports[0].port}{"\n"}'
# backend:8080     <- exactly what the frontend image expects

curl -s -o /dev/null -w "frontend: %{http_code}\n" http://localhost:30080
```

**Expected end state — none of this is a failure:**

| Workload | State | Why |
|---|---|---|
| frontend | 2/2 Ready, UI loads | static assets, no dependencies |
| backend | CrashLoopBackOff | no Postgres; the Go app exits after 60s of retries |
| `endpoints/backend` | `<none>` | no Ready pods to list |
| `/api/tasks` | 502 | vite has nothing to proxy to |

Day 11 adds Postgres and all of it turns green.

Ready for Day 09 when you can:

1. Say why the backend Service must be called `backend`.
2. Explain why `:latest` breaks a kind-loaded image even when it is on the node.
3. Predict what `/health` returns while Postgres is down, and why that matters.
4. Explain why `docker build` alone does not make an image available to a pod.

---

## Break it

**A. Rename the backend Service and watch the frontend break.**

This is the exercise that makes section 8.1 permanent.

```bash
kubectl patch svc backend -n devboard -p '{"metadata":{"name":"devboard-backend"}}' 2>/dev/null \
  || { kubectl delete svc backend -n devboard
       kubectl create service clusterip devboard-backend --tcp=8080:8080 -n devboard; }

kubectl get svc -n devboard
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks   # 502
```

Now look at what is healthy: the backend pods, the new Service, DNS, the
frontend pods — everything. The *only* problem is a name the frontend image
hardcodes. Prove it from inside a frontend pod:

```bash
kubectl exec -n devboard deploy/frontend -- \
  node -e "require('dns').lookup('backend',(e,a)=>console.log(e?'NXDOMAIN':a))"
kubectl exec -n devboard deploy/frontend -- \
  node -e "require('dns').lookup('devboard-backend',(e,a)=>console.log(e?'NXDOMAIN':a))"
```

Restore it:

```bash
kubectl delete svc devboard-backend -n devboard --ignore-not-found
kubectl apply -f solution/02-backend-service.yaml
```

**B. Forget `imagePullPolicy` with a `:latest` tag.**

```bash
docker tag devboard-backend:1.0 devboard-backend:latest
kind load docker-image devboard-backend:latest --name devops

kubectl run bad --image=devboard-backend:latest -n devboard
kubectl get pod bad -n devboard              # ErrImagePull -> ImagePullBackOff
kubectl describe pod bad -n devboard | tail -5
```

```
Failed to pull image "devboard-backend:latest":
failed to resolve reference "docker.io/library/devboard-backend:latest"
```

The image **is on the node** — but `:latest` defaults to `Always`, so the
kubelet went to Docker Hub anyway.

```bash
kubectl delete pod bad -n devboard
kubectl run bad --image=devboard-backend:latest --image-pull-policy=IfNotPresent -n devboard
kubectl get pod bad -n devboard              # Running (then CrashLoop - no DB)
kubectl delete pod bad -n devboard
```

**C. Deploy an image you never loaded.**

```bash
kubectl set image deployment/frontend frontend=devboard-frontend:99.0 -n devboard
kubectl get pods -n devboard -l app=frontend
kubectl describe pod -n devboard -l app=frontend | grep -A3 Events
kubectl rollout undo deployment/frontend -n devboard
```

The old pods keep serving — Day 05's stalled-rollout lesson, on your own code.

**D. Rebuild the same tag and wonder why nothing changed.**

```bash
# edit app/devboard/frontend/index.html - change the <title>
bash app/build-images.sh 1.0
curl -s http://localhost:30080 | grep -i "<title>"    # STILL THE OLD TITLE
```

Nothing asked the running pods to restart.

```bash
kubectl rollout restart deployment/frontend -n devboard
kubectl rollout status  deployment/frontend -n devboard
curl -s http://localhost:30080 | grep -i "<title>"    # now updated
```

This is the number one "my change did not deploy" cause in local Kubernetes
development. The real fix is immutable tags: one tag, one set of bits, forever.

---

## Interview questions

<details>
<summary><b>1. How do you get a locally built image into a Kubernetes cluster?</b></summary>

Push it to a registry the cluster can reach, with imagePullSecrets if it is
private - that is the only answer for real clusters. Local development tools
shortcut it: `kind load docker-image`, `minikube image load`, or pointing your
Docker client at the cluster's daemon. Never rely on an image being present on a
production node.
</details>

<details>
<summary><b>2. imagePullPolicy values and defaults?</b></summary>

`Always`, `IfNotPresent`, `Never`. The default is `Always` when the tag is
`latest` or absent, and `IfNotPresent` otherwise. Because that default changes
with the tag, production manifests should set it explicitly.
</details>

<details>
<summary><b>3. Why is `latest` dangerous?</b></summary>

It is mutable, so different nodes can run different bits under one name;
`kubectl apply` sees no template change so no rollout happens; rollback is
meaningless because the old revision points at the same moving tag; and it
forces `imagePullPolicy: Always`, making every pod start depend on the registry.
</details>

<details>
<summary><b>4. A pod is in ImagePullBackOff. Walk me through it.</b></summary>

`kubectl describe pod` and read Events. Causes: a typo in the name or tag; the
tag genuinely absent from the registry; a private registry with no
imagePullSecret (401/403); the node cannot reach the registry (proxy, firewall,
DNS); or a Docker Hub rate limit. On kind, add: the image was never loaded, or
`:latest` forced a remote pull.
</details>

<details>
<summary><b>5. Your frontend gets 502 from its API but every pod is healthy. Where do you look?</b></summary>

At the name the frontend is calling versus the Service name that exists. Here
the proxy target `http://backend:8080` is compiled into the image, so a Service
named anything else resolves to NXDOMAIN and the proxy 502s while every workload
reports healthy. Confirm with a DNS lookup from inside the frontend pod, and
with `kubectl get endpoints`. The general lesson: a Service name is part of the
application's contract, not a free choice.
</details>

<details>
<summary><b>6. How do you pull from a private registry?</b></summary>

`kubectl create secret docker-registry regcred --docker-server=... --docker-username=... --docker-password=...`,
then `spec.imagePullSecrets` in the pod template, or attach it to the
namespace's default ServiceAccount so all pods inherit it. On cloud, prefer node
IAM roles or workload identity so no static registry credential exists.
</details>

<details>
<summary><b>7. What is a digest and when do you use one?</b></summary>

A content-addressed identifier, `image@sha256:...`. It is immutable, so it
pins exactly which bits run regardless of tag movement. Used for production
pinning, supply-chain verification, and by GitOps tooling that resolves tags to
digests at deploy time.
</details>

<details>
<summary><b>8. This image is 180 MB for a static site. How would you shrink it?</b></summary>

The frontend runtime only needs the built `dist/` directory and a static file
server, not `node_modules` and a Node runtime. Serving `dist/` from
`nginx:alpine` would drop it to roughly 25 MB. Upstream keeps Node because
`vite preview` also acts as the `/api` reverse proxy - in Kubernetes that job
belongs to an Ingress, so once you reach Day 20 the Node runtime is redundant.
Smaller images also mean faster pod startup, which matters for autoscaling.
</details>

---

## Cheat card

```bash
bash app/get-devboard.sh              # fetch source
bash app/build-images.sh 1.0          # build + kind load
.\app\build-images.ps1 -Version 1.0   # PowerShell

docker exec devops-worker crictl images | grep devboard   # verify on the node

kubectl rollout restart deployment/frontend -n devboard    # after rebuilding a tag

# what image is each pod actually running?
kubectl get pods -n devboard -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

**Two rules to carry forward:**

1. Every kind-loaded image needs `imagePullPolicy: IfNotPresent`.
2. The backend Service must be named **`backend`** on port **8080**.

---

**Next: [Day 09 - ConfigMaps](../day-09-configmaps/)**
