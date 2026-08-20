# Day 08 solution

```bash
bash app/get-devboard.sh              # from the repo root
bash app/build-images.sh 1.0
kubectl apply -f days/day-08-build-and-load-app-images/solution/
```

Open <http://localhost:30080>. The UI loads; the board is empty.

Expected end state -- this is NOT a failure:

| Workload | State | Why |
|---|---|---|
| `frontend` | 2/2 Ready | static assets, no dependencies |
| `backend` | CrashLoopBackOff | no Postgres; the Go app `log.Fatalf`s after ~60s of retries |
| `endpoints/backend` | `<none>` | no Ready pods |
| `/api/tasks` | 502 | vite has nothing to proxy to |

Day 11 adds Postgres and it all turns green.

## The two things to notice in these manifests

1. **`imagePullPolicy: IfNotPresent`** on both Deployments. Delete it and set the
   tag to `:latest` to watch ImagePullBackOff happen on an image that is
   demonstrably already on the node.

2. **The Service is named `backend`, not `devboard-backend`.** The frontend image
   hardcodes `http://backend:8080`. The frontend Service can be called anything
   (it is `devboard-frontend` here) because nothing inside an image refers to it
   -- only the NodePort matters. That asymmetry is the point.
