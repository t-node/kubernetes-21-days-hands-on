# Day 12 solution — the complete DevBoard stack

```bash
bash app/build-images.sh 1.0            # images must exist on the nodes first
kubectl apply -f days/day-12-wire-the-three-tier-app/solution/
kubectl get all -n devboard
```

Open <http://localhost:30080>.

Or as a single file:

```bash
kubectl apply -f all-in-one.yaml
```

## What is in here

| File | Contains |
|---|---|
| `00-namespace.yaml` | the `devboard` namespace |
| `01-config.yaml` | ConfigMap: ports, host, db, user, sslmode |
| `02-secret.yaml` | Secret: the Postgres password only |
| `03-postgres-init.yaml` | ConfigMap: the real `01_schema.sql` + `02_seed.sql` |
| `04-postgres.yaml` | Postgres Deployment + Service (`postgres`) |
| `05-backend.yaml` | Backend Deployment + init container + Service (`backend`) |
| `06-frontend.yaml` | Frontend Deployment + NodePort Service (`devboard-frontend`) |
| `all-in-one.yaml` | all of the above, `---` separated |

## The three names that are not free choices

1. **Service `backend`, port 8080** — compiled into the frontend image.
2. **Service `postgres`** — must equal `POSTGRES_HOST` in the ConfigMap.
3. **nodePort 30080** — must be one of the ports mapped in
   `cluster/kind-config.yaml`, or your browser cannot reach it.

Everything else you may rename freely.

## What is still deliberately wrong

| Issue | Fixed on |
|---|---|
| Postgres uses `emptyDir` — data dies with the pod | Day 14 |
| Postgres is a Deployment — no stable identity | Day 15 |
| `/health` does not check the database, so readiness lies | Day 13 |
| No autoscaling | Day 17 |
| NodePort instead of Ingress | Day 20 |
| Every pod can reach every other pod | (NetworkPolicy, beyond this course) |

By the Capstone, all but the last are addressed.
