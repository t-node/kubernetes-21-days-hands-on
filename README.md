# Kubernetes: 21 Days, Hands-On

A build-it-yourself Kubernetes course in the *"100 Days of X"* format — except it
is 21 days, because that is how long this material actually takes when nothing
is padded.

You will not read about Kubernetes. You will take a **real three-tier
application** — React + Vite → Go + Gin → PostgreSQL — from a
`docker-compose.yml` onto a local cluster, then all the way through config,
secrets, persistent storage, health probes, autoscaling, scheduling and RBAC:
the same path a production app actually walks.

Every day is self-contained. The concept explanation, every command, every YAML
file, the expected output, the validation steps, the ways it breaks, and the
interview questions are all **in this repo**. You should not need a second tab
open to finish a day.

---

## What you build

You deploy **[DevBoard](https://github.com/t-node/devboard)** — a real
project-and-task tracker, not a hello-world — and take it from a
`docker-compose.yml` all the way to a production-shaped Kubernetes deployment.

```
                     your browser
                          |
                    localhost:30080
                          |
        +-----------------v------------------+
        |        Kubernetes cluster          |
        |        (3 nodes, via kind)         |
        |                                    |
        |   Service devboard-frontend        |
        |   NodePort 30080 -> 4173           |
        |        |                           |
        |   +----v----------------+          |
        |   |  frontend           |          |
        |   |  React + Vite :4173 |  2 pods  |
        |   |  proxies /api  -----|--+       |
        |   +---------------------+  |       |
        |                            |       |
        |   Service "backend" :8080 <-+      |
        |        |                           |
        |   +----v----------------+          |
        |   |  backend            |  2 pods  |
        |   |  Go + Gin :8080     |  + HPA   |
        |   +----+----------------+          |
        |        |  POSTGRES_URL             |
        |   Service "postgres" :5432         |
        |        |                           |
        |   +----v----------------+          |
        |   |  postgres:16-alpine |          |
        |   |  StatefulSet + PVC  |          |
        |   +---------------------+          |
        |                                    |
        |   ConfigMap - Secret - RBAC        |
        +------------------------------------+
```

| Tier | Stack | Port |
|---|---|---|
| frontend | React + Vite (`vite preview`) | 4173 |
| backend | Go + Gin | 8080 |
| database | PostgreSQL 16 | 5432 |

The frontend proxies `/api/*` to `http://backend:8080` — a hostname baked into
the image, which makes the backend Service name an **API contract** rather than
a free choice. You meet that the hard way on Day 09.

Full application contract — every endpoint, environment variable and port —
is in **[app/README.md](app/README.md)**. You build the images yourself on Day 08.

## Before you start

Read **[SETUP.md](SETUP.md)** and get these four things working. It takes about
20 minutes and you only do it once.

| Tool | Why |
|---|---|
| Docker Desktop | kind runs Kubernetes nodes as Docker containers |
| `kind` | creates the local cluster |
| `kubectl` | the client you will spend 21 days living inside |
| `git` | to fetch the DevBoard application source |
| A terminal | PowerShell, Git Bash, WSL2, macOS or Linux all work |

Hardware: **8 GB RAM minimum**, 16 GB comfortable. If you are tight on memory,
`cluster/kind-config-single-node.yaml` runs everything on one node.

---

## How to work through a day

Each day folder looks like this:

```
days/day-NN-topic/
  README.md      <- concepts, then the lab, step by step
  solution/      <- the finished manifests. Peek only after you have tried.
```

The rhythm that makes this stick:

1. **Read the concept section.** About 10 minutes. Do not skim the "why" — the
   why is what interviews actually test.
2. **Type the commands.** Do not copy-paste the YAML on the first pass. Typing
   `apiVersion: apps/v1` fifty times is how it stops being something you look up.
3. **Run the Validate block.** If your output does not match, that is the lesson.
4. **Do the Break It section.** Deliberately breaking things is the single
   highest-value part of this course.
5. **Answer the Interview Questions out loud** before reading the answers.

Budget **45 to 90 minutes per day.** Days 11 to 17 are heavier; give them more.

---

## The 21 days

### Week 1 — Core objects

| Day | Topic | You will be able to |
|:--:|---|---|
| [01](days/day-01-architecture-and-kind-cluster/) | Architecture and your first cluster | Name every control-plane and node component and say what it does; create a 3-node cluster |
| [02](days/day-02-kubectl-and-your-first-pod/) | kubectl and your first Pod | Write a Pod manifest from scratch; use `describe`, `logs`, `exec`, `port-forward` |
| [03](days/day-03-namespaces/) | Namespaces | Isolate resources; know what is and is not namespaced; set a ResourceQuota |
| [04](days/day-04-labels-replicasets-deployments/) | Labels, ReplicaSets, Deployments | Explain how selectors glue objects together; self-heal and scale |
| [05](days/day-05-rolling-updates-and-rollbacks/) | Rolling updates and rollbacks | Ship a new version with zero downtime; roll back a bad deploy in one command |
| [06](days/day-06-services-clusterip-and-dns/) | Services I: ClusterIP and DNS | Explain `port` vs `targetPort`; resolve Services by name; debug empty Endpoints |
| [07](days/day-07-services-nodeport-loadbalancer/) | Services II: NodePort and LoadBalancer | Choose the right Service type; expose an app to your browser |

### Week 2 — Real applications

| Day | Topic | You will be able to |
|:--:|---|---|
| [08](days/day-08-build-and-load-app-images/) | Build and load the app images | Build images and get them into kind without a registry |
| [09](days/day-09-configmaps/) | ConfigMaps | Inject config as env vars and as mounted files; know when each is right |
| [10](days/day-10-secrets/) | Secrets | Handle credentials; explain honestly why base64 is not encryption |
| [11](days/day-11-postgres-with-config-and-secrets/) | Postgres with config and secrets | Run a database, seed a schema, connect with `psql` |
| [12](days/day-12-wire-the-three-tier-app/) | Wire the three tiers together | Ship the full app and reach it from your browser |
| [13](days/day-13-health-probes/) | Liveness, readiness, startup probes | Design probes that heal your app instead of causing outages |
| [14](days/day-14-volumes-pv-pvc/) | Volumes, PV, PVC | Explain the PV/PVC binding dance; make data survive a Pod delete |

### Week 3 — Production concerns

| Day | Topic | You will be able to |
|:--:|---|---|
| [15](days/day-15-statefulsets-and-headless-services/) | StatefulSets and headless Services | Say precisely why a database is not a Deployment; get stable identities |
| [16](days/day-16-resources-requests-limits-metrics-server/) | Requests, limits, metrics-server | Explain QoS classes and OOMKills; read `kubectl top` |
| [17](days/day-17-horizontal-pod-autoscaler/) | Horizontal Pod Autoscaler | Watch pods scale 2 to 10 under load, then back down |
| [18](days/day-18-scheduling-taints-affinity-daemonsets/) | Scheduling, taints, DaemonSets | Control where pods land; answer "why do app pods not run on the control plane?" |
| [19](days/day-19-rbac/) | RBAC | Create a read-only intern and an admin; prove it with `auth can-i` |
| [20](days/day-20-ingress-and-gateway-api/) | Ingress and Gateway API | Route by host and path; migrate an Ingress to the Gateway API |
| [21](days/day-21-break-and-fix-troubleshooting/) | Break and fix | Diagnose 8 deliberately broken clusters under time pressure |

### Finale

| | |
|---|---|
| [Capstone](capstone/) | Rebuild everything on a fresh cluster from an empty folder, with no step-by-step guide. This is the one you put on your CV. |

---

## CKA track (parallel, optional)

The 21 days teach you to **deploy an application**. The Certified Kubernetes
Administrator exam tests something different: running and repairing the
**cluster itself**. That material lives in **[`cka/`](cka/)** and can be taken
any time after Day 01.

| # | Topic | Why it is not in the main track |
|:--:|---|---|
| [01](cka/01-container-runtimes-and-crictl/) | Container runtimes: CRI, OCI, `ctr` / `nerdctl` / `crictl` | debugging a node when `kubectl` itself is down |
| [02](cka/02-etcd-and-cluster-data/) | etcd: the key-value model, `etcdctl`, the `/registry` tree | reading cluster state straight from the datastore |

More arrives as the source transcripts do — see
[cka/README.md](cka/README.md) for what is covered and what is still pending.

---

## Reference material (use these all course long)

- **[SETUP.md](SETUP.md)** — install Docker, kind and kubectl on Windows, macOS or Linux
- **[CHEATSHEET.md](CHEATSHEET.md)** — every kubectl command in this course, grouped by task
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — symptom, cause and fix for every failure mode you will hit
- **[GLOSSARY.md](GLOSSARY.md)** — every term, defined in one line
- **[INTERVIEW-QUESTIONS.md](INTERVIEW-QUESTIONS.md)** — 100+ questions with answers, sorted by experience level

---

## Rules that will save you hours

1. **Everything in Kubernetes is a YAML manifest.** If you reach for an
   imperative `kubectl create deployment ...`, use it to *generate* YAML with
   `--dry-run=client -o yaml` and commit the file.
2. **`kubectl describe` before Google.** Around 90 percent of failures explain
   themselves in the `Events:` section at the bottom of `describe`.
3. **`kubectl apply` is idempotent.** Re-running it is always safe. Build the
   habit of editing the file and re-applying, not `kubectl edit`.
4. **Namespace everything.** Nearly every command here carries `-n devboard`.
   Forgetting it is the most common "where did my pod go?"
5. **Version matters.** This course targets **Kubernetes 1.31**. API versions
   move; when you see "no matches for kind", suspect `apiVersion` first.

---

## If you get stuck

Reset the cluster and lose nothing you cannot rebuild in two minutes:

```bash
bash cluster/recreate-cluster.sh
```

Each day has a `solution/` folder with working manifests. Reaching for it is not
failure — diffing your YAML against a working one is a legitimate way to learn.
The only thing that does not work is reading the solution instead of trying.

---

**Start here: [Day 01 — Architecture and your first cluster](days/day-01-architecture-and-kind-cluster/)**
