# Capstone — Ship DevBoard Properly

**Time:** 3-5 hours
**Prerequisites:** all 21 days

Everything so far had step-by-step instructions. This does not.

You are given **requirements**, not commands. Start from an empty folder and a
fresh cluster, and produce a production-shaped deployment of DevBoard that you
would be comfortable defending in an interview.

This is the artefact you put on your CV.

---

## The brief

> DevBoard is going to production. You are the platform engineer. Deliver a
> Kubernetes deployment that is **secure**, **observable**, **resilient** and
> **reproducible** — and be able to justify every decision.

You may look at anything in this repo. You may not copy `days/*/solution/`
wholesale without understanding it — the exit interview at the end will find
that out quickly.

---

## Rules

1. **Start clean.**
   ```bash
   kind delete cluster --name devops
   kind create cluster --config cluster/kind-config.yaml
   mkdir -p capstone/my-solution && cd capstone/my-solution
   ```
2. **Everything is a manifest.** No imperative `kubectl create` except to
   *generate* YAML you then commit. At the end, `kubectl delete namespace
   devboard` followed by `kubectl apply -f .` must restore the whole system.
3. **Write the reasoning down.** Every non-obvious decision gets a comment or a
   line in your README. "Why 512Mi?" must have an answer.
4. **Do not read `capstone/reference/` until you are finished.** It is one
   possible solution, not the solution.

---

## Requirements

### R1 — Foundation

- [ ] A dedicated namespace with meaningful labels.
- [ ] A **ResourceQuota** capping the namespace, and a **LimitRange** supplying
      defaults so pods without explicit resources are still admitted.
- [ ] Every object carries consistent labels. Use the
      `app.kubernetes.io/*` convention.

### R2 — Configuration

- [ ] All non-sensitive configuration in a **ConfigMap**.
- [ ] The Postgres password in a **Secret**, and nowhere else.
- [ ] `POSTGRES_URL` **assembled** from ConfigMap and Secret parts — the
      password must not be duplicated anywhere.
- [ ] The database schema and seed loaded from a ConfigMap.
- [ ] Explain in a comment how you would handle this Secret in a real cluster
      (you are not required to install anything).

### R3 — The database

- [ ] Postgres as a **StatefulSet** with a `volumeClaimTemplate`.
- [ ] A **headless Service** for identity plus a **ClusterIP Service** for
      clients.
- [ ] Data survives deleting the pod **and** deleting the StatefulSet.
- [ ] `PGDATA` handled correctly for a real volume.
- [ ] **Guaranteed** QoS.
- [ ] Probes that check the database accepts connections, not merely that a
      process exists.

### R4 — The application

- [ ] Backend and frontend as **Deployments**, at least 2 replicas each.
- [ ] The backend waits for Postgres before starting (**init container**).
- [ ] **Liveness** probes that check only the process.
- [ ] **Readiness** probes that reflect real ability to serve, including
      dependencies.
- [ ] **Graceful shutdown**: `preStop` and a sensible grace period.
- [ ] Resource requests and limits on every container, with your reasoning.
- [ ] Rolling update strategy configured deliberately, not left to defaults.
- [ ] The Service names the frontend image actually requires.

### R5 — Networking

- [ ] All Services are **ClusterIP** — no NodePort in the final state.
- [ ] An **Ingress** (or Gateway API) as the single entry point.
- [ ] Host-based or path-based routing, with the `/api` prefix handled
      correctly.
- [ ] **TLS**, even with a self-signed certificate.
- [ ] HTTP redirects to HTTPS.

### R6 — Scaling and resilience

- [ ] **HPA** on the backend, correctly configured (and remember what must
      *not* be in the Deployment).
- [ ] Replicas spread across nodes.
- [ ] A **PodDisruptionBudget** for each stateless tier.
- [ ] The system survives `kubectl drain` of any single worker node.

### R7 — Security

- [ ] A dedicated **ServiceAccount** per workload; none uses `default`.
- [ ] `automountServiceAccountToken: false` wherever the API is not used.
- [ ] A **Role** and **RoleBinding** granting an operator read-only access to
      the namespace, verified with `kubectl auth can-i`.
- [ ] A `securityContext` on every pod: non-root, no privilege escalation,
      read-only root filesystem where possible, dropped capabilities.
- [ ] No secret values in any ConfigMap, argument or image.

### R8 — Operations

- [ ] `metrics-server` working; `kubectl top` returns data.
- [ ] A `README.md` in your solution folder covering: how to deploy, how to
      verify, how to roll back, how to back up the database, and the decisions
      you made with their reasoning.
- [ ] A `verify.sh` that checks the whole system end to end and exits non-zero
      on failure.
- [ ] A documented backup procedure — and evidence you have tested the
      **restore**.

---

## Stretch goals

Only after R1-R8 are complete and verified:

- [ ] **Kustomize**: a `base/` plus `overlays/dev` and `overlays/prod` differing
      in replicas, resources and image tags.
- [ ] **NetworkPolicy**: default-deny in the namespace, then allow exactly
      frontend→backend and backend→postgres. (Note: kind's default CNI does not
      enforce NetworkPolicy — install Calico or Cilium, or state that limitation
      in your README.)
- [ ] **cert-manager** with a self-signed ClusterIssuer instead of a hand-made
      certificate.
- [ ] **Gateway API** instead of Ingress.
- [ ] A **CronJob** running `pg_dump` to a PVC on a schedule.
- [ ] A **PodSecurity** admission label on the namespace (`restricted`) — and
      make every workload actually comply.
- [ ] Convert the whole thing into a **Helm chart**.

---

## Self-assessment

Run through this before comparing with the reference. Be strict.

### Reproducibility

```bash
kubectl delete namespace devboard --wait=true
kubectl apply -f .                       # your manifests only
bash verify.sh                           # must pass
```

If that fails, you have hidden state — an imperative command you ran once and
never wrote down. Find it.

### Resilience

```bash
# 1. kill every pod of each workload; the app must recover unaided
kubectl delete pod -n devboard --all --wait=false
sleep 90 && bash verify.sh

# 2. drain a node; the app must stay up
kubectl drain devops-worker --ignore-daemonsets --delete-emptydir-data
bash verify.sh
kubectl uncordon devops-worker

# 3. the database must not lose data
kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -c "INSERT INTO tasks (title, project_id) VALUES ('capstone survival', 1);"
kubectl delete pod postgres-0 -n devboard
sleep 60
kubectl exec -n devboard postgres-0 -- psql -U devboard -d devboard \
  -tAc "SELECT count(*) FROM tasks WHERE title='capstone survival';"    # 1

# 4. a bad deploy must not take the app down
kubectl set image deployment/backend backend=devboard-backend:does-not-exist -n devboard
sleep 45
bash verify.sh                            # must still pass
kubectl rollout undo deployment/backend -n devboard
```

### Security

```bash
kubectl auth can-i --list -n devboard \
  --as=system:serviceaccount:devboard:devboard-operator

# no workload should run as root
kubectl get pods -n devboard -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext.runAsNonRoot}{"\n"}{end}'

# no pod that does not need a token should have one
kubectl get pods -n devboard -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.automountServiceAccountToken}{"\n"}{end}'

# no secret values anywhere they should not be
grep -ri "password" . --include=*.yaml | grep -v secretKeyRef | grep -v "^./README"
```

### Scaling

```bash
kubectl get hpa -n devboard
kubectl apply -f ../../days/day-17-horizontal-pod-autoscaler/solution/02-load-generator.yaml
sleep 180
kubectl get hpa,pods -n devboard -l app=backend      # must have scaled up
kubectl delete -f ../../days/day-17-horizontal-pod-autoscaler/solution/02-load-generator.yaml
```

---

## Scoring

| Requirement | Points |
|---|---|
| R1 Foundation | 10 |
| R2 Configuration | 15 |
| R3 Database | 15 |
| R4 Application | 20 |
| R5 Networking | 10 |
| R6 Scaling and resilience | 10 |
| R7 Security | 10 |
| R8 Operations | 10 |
| **Total** | **100** |
| Each stretch goal | +5 |

| Score | Meaning |
|---|---|
| < 60 | revisit the days you skipped |
| 60-79 | solid. You can run this in a real cluster with supervision |
| 80-94 | strong. This is a portfolio project |
| 95+ | you can defend every decision in a senior interview |

---

## The exit interview

Answer these **out loud**, without notes. If any answer is vague, that topic
needs another pass — the day number is in brackets.

1. Walk me through what happens when a user loads your app, from browser to
   database and back. [12]
2. Why is Postgres a StatefulSet and the backend a Deployment? [15]
3. Your liveness probe — what does it check, and what does it deliberately not
   check? Why? [13]
4. Where is the database password, how does it reach the application, and how
   would you rotate it? [10, 11]
5. Your HPA is scaling but pods are Pending. What is missing? [17]
6. A node dies. Narrate what happens to each of your three tiers. [04, 14, 18]
7. How would you deploy v2 of the backend with zero downtime, and roll back if
   it is bad? [05]
8. Someone gets an intern account. What can they see, and what stops them
   reading the database password? [19]
9. Your app returns 502. Give me your first four commands and why. [21]
10. What would you change to run this on EKS instead of kind? [07, 14, 20]

**Question 10 deserves preparation.** A good answer covers: images from ECR
rather than `kind load`; a real StorageClass (gp3 via the EBS CSI driver) with
`Retain`; `type: LoadBalancer` or an ALB Ingress controller actually
provisioning; Secrets from AWS Secrets Manager via External Secrets, or IAM
database authentication so there is no static password; IRSA instead of
long-lived credentials; the Cluster Autoscaler or Karpenter so the HPA has
somewhere to scale into; multi-AZ topology spread constraints; a managed RDS
instance instead of a self-hosted StatefulSet; and real observability —
Prometheus, Grafana, Loki — rather than `kubectl top`.

---

## When you are done

```bash
cd capstone/my-solution
git add -A
git commit -m "capstone: production-shaped DevBoard on Kubernetes"
```

Then read [`reference/`](reference/) and **diff it against yours**. Where you
differ, decide which is better and be able to say why. Some of your choices will
be better than the reference — that is the point of the exercise.
