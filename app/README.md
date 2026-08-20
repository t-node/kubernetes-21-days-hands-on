# The DevBoard application

The workload you deploy for 21 days. It is a real project-and-task tracker
(a Kanban board), not a hello-world: three tiers, a real schema, a real API.

Upstream source: <https://github.com/t-node/devboard>

```
browser ──▶ frontend (React + Vite, :4173) ──/api──▶ backend (Go + Gin, :8080) ──▶ postgres:5432
```

---

## Get it and build it

```bash
bash app/get-devboard.sh      # clone the source into app/devboard/
bash app/build-images.sh 1.0  # build both images + kind load them
```

PowerShell:

```powershell
.\app\get-devboard.ps1
.\app\build-images.ps1 -Version 1.0
```

`app/devboard/` is gitignored — it is someone else's repo, fetched on demand.

---

## The contract (everything the manifests depend on)

### Backend — Go + Gin

| | |
|---|---|
| Listens on | `PORT`, default **8080** |
| Config | **`POSTGRES_URL`** — a single DSN, e.g. `postgres://devboard:devboard@postgres:5432/devboard?sslmode=disable` |
| Health | `GET /health` → `{"status":"ok","service":"backend"}` |
| Routes | `GET/POST /projects`, `GET/POST /tasks`, `PATCH /tasks/:id`, `GET /search` |
| Startup | pings Postgres, retrying **30 × 2s**. After ~60 s it **exits** (`log.Fatalf`) |

Two behaviours that shape the whole course:

- **`POSTGRES_URL` is one string containing the password.** The manifests build
  it from ConfigMap + Secret parts using `$(VAR)` interpolation rather than
  storing the assembled URL. See Day 10.
- **`/health` does not touch the database.** It returns 200 whenever the process
  is alive. Good as a *liveness* probe, insufficient as a *readiness* probe —
  Day 13 is about exactly this gap and how to close it.

### Frontend — React + Vite

| | |
|---|---|
| Listens on | **4173** (`vite preview --host 0.0.0.0`) |
| Proxy | `/api/*` → `http://backend:8080/*`, **`/api` prefix stripped** |
| Config | none — no `VITE_*` variables; all API calls are relative paths |

> ### The single most important line in this file
>
> **`http://backend:8080` is compiled into the frontend image**
> (`vite.preview.config.js`). Therefore your backend Service **must be named
> `backend`, on port 8080, in the same namespace** — or you must override
> `/app/vite.config.js` from a ConfigMap.
>
> That is not a flaw. A Service name *is* an API contract, and discovering it
> the hard way (502 from the frontend, healthy backend) is Day 09's lesson.

### Database — postgres:16-alpine

| | |
|---|---|
| Env | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (all `devboard` by default) |
| Schema | `init/postgres/01_schema.sql` — `projects`, `tasks`, indexes, an `updated_at` trigger |
| Seed | `init/postgres/02_seed.sql` — 2 projects, 10 tasks |

Those two SQL files become a **ConfigMap** mounted at
`/docker-entrypoint-initdb.d/` on Day 11. Remember they run **only when the data
directory is empty** — first boot on a fresh volume, never again.

---

## Ports, all in one place

Deliberately all different, so you can never confuse `port`, `targetPort` and
`nodePort`:

| Hop | Port |
|---|---|
| your browser | `localhost:30080` |
| frontend Service | `port: 80` → `targetPort: 4173` → `nodePort: 30080` |
| frontend container | `4173` |
| backend Service (**must be named `backend`**) | `port: 8080` → `targetPort: 8080` |
| backend container | `8080` |
| postgres Service | `port: 5432` |
| postgres container | `5432` |

---

## Why these Dockerfiles and not the upstream ones

Upstream builds `FROM dhi.io/golang` and `FROM dhi.io/node` — **Docker Hardened
Images**, which need an entitled Docker organisation. Without it, `docker build`
fails on the first `FROM` with an authentication error.

`app/dockerfiles/*.Dockerfile` are functionally identical builds on public base
images (`golang:1.23-alpine`, `node:22-alpine`, `alpine:3.20`). Two intentional
differences:

- the backend runtime is Alpine, which **has a shell**, so
  `kubectl exec -it deploy/backend -- sh` works during the debugging exercises
- no DHI entitlement required

If your organisation does have DHI access, build the upstream Dockerfiles
instead — the resulting images behave the same and every manifest in this
course still applies.

---

## Run it with Docker Compose first (10 minutes, worth it)

Before porting anything to Kubernetes, see the app work in the model you already
know. Day 12 is essentially "translate this compose file into Kubernetes
objects", so having it fresh in mind pays off.

```bash
cd app/devboard
cp .env.example .env
docker compose up --build
# open http://localhost:8080
```

Map it as you go:

| docker-compose | Kubernetes |
|---|---|
| `services:` | Deployment + Service per tier |
| `environment:` | ConfigMap + Secret |
| `ports: "8080:4173"` | Service `type: NodePort` |
| service name `backend` | Service named `backend` + cluster DNS |
| `depends_on: condition: service_healthy` | init container + readiness probe |
| `volumes: pgdata:` | PersistentVolumeClaim |
| `healthcheck:` | liveness / readiness probes |

```bash
docker compose down -v      # -v also drops the pgdata volume
```
