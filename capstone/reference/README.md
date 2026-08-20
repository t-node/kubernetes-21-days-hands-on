# Capstone reference solution

**Do not read this until you have finished your own.** Diffing your work against
this is the exercise; copying it is not.

This is **one** defensible answer, not the answer. Several choices are
trade-offs where a different decision would be equally correct — those are
flagged in the comments.

## Deploy

```bash
kind create cluster --config ../../cluster/kind-config.yaml
bash ../../app/build-images.sh 1.0

# metrics-server, required by the HPA
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# ingress-nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# TLS certificate (self-signed, for this exercise)
bash make-cert.sh

# the application
kubectl apply -f manifests/
bash verify.sh
```

Then <https://devboard.local:8443> after adding `127.0.0.1 devboard.local` to
your hosts file, or:

```bash
curl -sk -H "Host: devboard.local" https://localhost:8443/api/tasks
```

## Layout

```
manifests/
  00-namespace.yaml     namespace, ResourceQuota, LimitRange
  01-rbac.yaml          ServiceAccounts, operator read-only Role
  02-config.yaml        ConfigMap, Secret, init SQL
  03-postgres.yaml      StatefulSet, headless Service, ClusterIP Service
  04-backend.yaml       Deployment, Service, HPA, PodDisruptionBudget
  05-frontend.yaml      Deployment, Service, PodDisruptionBudget
  06-ingress.yaml       Ingress with TLS and the /api rewrite
make-cert.sh            generates the self-signed TLS Secret
verify.sh               end-to-end check, non-zero exit on failure
backup.sh               pg_dump to a local file
restore.sh              psql restore, tested
DECISIONS.md            why each non-obvious choice was made
```

## The decisions worth arguing about

Read [DECISIONS.md](DECISIONS.md). It covers, with reasoning:

- why the backend has no CPU limit but the database does
- why readiness uses an exec probe rather than the app's `/health`
- why the Postgres Service is named `postgres` and the backend `backend`
- why `POSTGRES_URL` is assembled rather than stored whole
- why the database is Guaranteed QoS and the app tiers are Burstable
- why topology spread is used instead of pod anti-affinity
- what would change on a real cloud cluster

If your answers differ and you can defend them, yours may well be better.
