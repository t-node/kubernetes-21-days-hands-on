# Design decisions and their reasoning

Every non-obvious choice, with the trade-off stated. This document is the part
that separates "it works" from "I can defend it".

---

## 1. The database gets a CPU limit; the application tiers do not

**Choice:** Postgres has `requests == limits` (Guaranteed QoS). Backend and
frontend have CPU *requests* but no CPU *limit*.

**Why:** CPU is compressible — a limit throttles rather than kills, and CFS
throttling causes severe tail latency even for workloads averaging well below
their limit. For a latency-sensitive API, letting it use idle capacity beats
capping it. The database is different: it must be the last thing evicted under
node pressure, which requires Guaranteed QoS, which requires requests to equal
limits.

**Trade-off:** without CPU limits the backend can become a noisy neighbour. The
ResourceQuota bounds the blast radius at namespace level, and the HPA scales out
before one pod needs an unreasonable share.

**When I would change it:** a multi-tenant cluster where cross-team
predictability matters more than per-service latency. Then set CPU limits
everywhere and accept the throttling.

---

## 2. Readiness uses an exec probe, not the app's /health

**Choice:** liveness is `httpGet /health`; readiness is an exec probe checking
both the local HTTP endpoint and TCP reachability of Postgres.

**Why:** DevBoard's `/health` deliberately does not touch the database, which
makes it a *correct* liveness probe — a database blip must never restart every
backend pod. But it is an inadequate readiness probe: without a dependency
check, pods stay in the Service endpoints during a database outage and return
500s to users.

**Trade-off:** exec probes fork a process on every check, measurably more
expensive at scale than an HTTP probe.

**The better fix:** add a real `/ready` endpoint to the Go service — about ten
lines, documented in
`days/day-13-health-probes/solution/OPTIONAL-add-ready-endpoint.md`. Only the
application knows whether its own connection pool is healthy; an external check
sees only whether a port is open. The exec probe is the right answer when you
cannot change the image, which is worth being able to handle.

---

## 3. Service names are not free choices

**Choice:** the backend Service is `backend` on port 8080; the Postgres Service
is `postgres`.

**Why:** `http://backend:8080` is compiled into the frontend image
(`vite.preview.config.js`). Rename it and the frontend returns 502 while every
pod reports healthy. `postgres` matches `POSTGRES_HOST` in the ConfigMap and the
upstream compose file, so the DSN transfers unchanged.

**The alternative:** mount a replacement `vite.config.js` from a ConfigMap
(Day 09) and use whatever names your convention demands. Right when a naming
standard is non-negotiable; it costs one more object and a `subPath` mount that
will never live-update.

---

## 4. POSTGRES_URL is assembled, not stored

**Choice:** username, host, port, database and sslmode live in the ConfigMap;
only the password is in the Secret; the DSN is composed in the pod spec with
`$(VAR)` interpolation.

**Why:** storing the whole URL in a Secret would duplicate the non-secret parts,
so changing a hostname would mean editing a Secret and configuration would
drift. This keeps one source of truth per value.

**Trade-off:** `$(VAR)` interpolation fails **silently** — an unresolvable
`$(FOO)` is left literally in the value with no error, surfacing later as a
baffling DNS failure. Mitigated by keeping the interpolated variables adjacent
and explicit in the same `env` list.

**Caveat noted in the manifest:** a password containing `@`, `/` or `:` must be
URL-encoded or the DSN becomes unparseable. Generated passwords should be
constrained to a URL-safe alphabet.

---

## 5. The Secret is plaintext in git, and that is called out

**Choice:** a plain `Secret` using `stringData`, so the repository is
self-contained.

**Why not in production:** git history is permanent, so a committed credential
must be treated as compromised and rotated. The real options, in order of
preference:

1. **No static credential at all** — IAM database authentication (RDS), or
   Vault dynamic credentials.
2. **External Secrets Operator** syncing from AWS Secrets Manager or Vault.
3. **Sealed Secrets or SOPS**, so only ciphertext is committed.

The manifest says this in a comment. An interviewer who sees a plaintext Secret
with no acknowledgement assumes you do not know better; one who sees the comment
knows you made a deliberate trade for a teaching repository.

---

## 6. Topology spread, not pod anti-affinity

**Choice:** `topologySpreadConstraints` with `maxSkew: 1` and
`whenUnsatisfiable: ScheduleAnyway`.

**Why:** `required` pod anti-affinity on `kubernetes.io/hostname` caps replicas
at the node count. With an HPA attached, a scale-up beyond that leaves pods
permanently `Pending` — autoscaling silently stops working at 2 a.m. Topology
spread distributes just as evenly and degrades gracefully instead of failing.

**Trade-off:** `ScheduleAnyway` means that under pressure two replicas can share
a node, so one node failure could remove more than one. `DoNotSchedule` gives a
hard guarantee and reintroduces the Pending risk. For three nodes and at most
ten replicas, graceful degradation is the better trade.

---

## 7. The Deployment under an HPA has no replicas field

**Choice:** `spec.replicas` is absent from the backend Deployment.

**Why:** if present, every `kubectl apply` — and every GitOps sync, which
happens continuously — resets the count, the HPA corrects it, and capacity
flaps, most damagingly during peak load.

**Alternative:** keep the field and configure the sync tool to ignore it (Argo
CD `ignoreDifferences` on `/spec/replicas`). Necessary when a policy engine
requires the field to be present.

---

## 8. Ingress rather than the Gateway API

**Choice:** an `Ingress` with ingress-nginx.

**Why:** it is what most existing clusters run today, and the `/api` rewrite is
worth practising in both forms. A Gateway API version is a stretch goal.

**What I would do for a new platform:** start with the Gateway API. It is GA for
HTTP, its routing features are typed fields rather than vendor annotations, and
it separates operator concerns (Gateway, TLS) from developer concerns
(HTTPRoute) in a way RBAC can enforce. Ingress-NGINX itself is in maintenance
mode. For existing Ingress, migrate incrementally — they coexist, and
`ingress2gateway` does the mechanical translation.

---

## 9. Resource values, and how they were chosen

| Workload | requests | limits | Reasoning |
|---|---|---|---|
| postgres | 250m / 256Mi | 250m / 256Mi | Guaranteed QoS so it is evicted last. Idle usage ~15 MiB; headroom for shared buffers and per-connection memory |
| backend | 50m / 64Mi | no cpu / 128Mi | Go binary, a few millicores idle. No CPU limit (decision 1). Memory limit about 4x observed peak |
| frontend | 100m / 128Mi | no cpu / 256Mi | Node runtime, measurably heavier than Go. Serving `dist/` from nginx would cut this by roughly 80% |
| init containers | 10m / 16Mi | 100m / 64Mi | run briefly; keep them out of the scheduler's accounting |

**Method:** deploy generously, run the Day 17 load generator, read
`kubectl top pods --containers` over several minutes, set requests near observed
p50-p90 and memory limits at peak plus meaningful headroom.

**Honest caveat:** these numbers come from a laptop cluster under synthetic
load. Real values need days of production observation via Prometheus, or the VPA
in recommendation mode.

---

## 10. What changes on EKS

| Here | On EKS |
|---|---|
| `kind load docker-image` | ECR, with IRSA for pull credentials |
| `standard` StorageClass | `gp3` via the EBS CSI driver, `reclaimPolicy: Retain` |
| self-hosted Postgres StatefulSet | **RDS**, unless there is a specific reason not to |
| plaintext Secret | Secrets Manager via External Secrets, or IAM DB auth |
| Ingress on kind | ALB Ingress Controller, or a Gateway API implementation |
| self-signed certificate | ACM, or cert-manager with Let's Encrypt |
| HPA alone | HPA **plus** Cluster Autoscaler or Karpenter |
| `kubernetes.io/hostname` spread | `topology.kubernetes.io/zone` for multi-AZ |
| `kubectl top` | Prometheus, Grafana, Loki, and alerting |
| manual `pg_dump` CronJob | RDS automated backups with point-in-time recovery |
| no NetworkPolicy enforcement | a CNI that enforces it (Calico, Cilium, VPC CNI) |

The single largest change is **using RDS**. Running a database yourself is
justified by cost at scale, regulatory constraints, or the absence of a managed
option — not by preference. If self-hosting is required, use an operator such as
CloudNativePG rather than a hand-written StatefulSet: failover, backup and
major-version upgrades are the hard parts, and this manifest solves none of them.
