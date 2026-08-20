# Optional: add a real `/ready` endpoint to the Go backend

The exec probe in `01-backend-probes-exec.yaml` works, but it only proves that
*something* is listening on the Postgres port. It cannot see whether the Go
app's own `database/sql` connection pool is healthy — which is the thing that
actually determines whether a request will succeed.

The proper fix is about ten lines of Go. It is also good practice at the
build-and-load loop from Day 08 on a real code change.

## 1. Edit the source

Open `app/devboard/backend/main.go` and find the existing health route:

```go
	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "backend"})
	})
```

Add this immediately after it:

```go
	// Readiness: can this pod actually serve? Unlike /health, this DOES touch
	// the database, because readiness failure removes the pod from the Service
	// endpoints rather than restarting it.
	r.GET("/ready", func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if err := db.PingContext(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"status": "not-ready",
				"error":  err.Error(),
			})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	})
```

Add `"context"` to the import block at the top (`time` is already imported):

```go
import (
	"context"
	"database/sql"
	"log"
	...
)
```

## 2. Rebuild and load

```bash
bash app/build-images.sh 1.1
```

Use a **new tag**. Rebuilding `1.0` in place means the running pods keep the old
binary until you `rollout restart` — Day 08, Break It D.

## 3. Deploy it

```bash
kubectl set image deployment/backend backend=devboard-backend:1.1 -n devboard
kubectl rollout status deployment/backend -n devboard
```

## 4. Switch the probe to the new endpoint

```bash
kubectl patch deployment backend -n devboard -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name": "backend",
    "readinessProbe": {
      "httpGet": {"path": "/ready", "port": 8080},
      "initialDelaySeconds": 3,
      "periodSeconds": 5,
      "timeoutSeconds": 3,
      "failureThreshold": 2
    }
  }]}}}
}'
kubectl rollout status deployment/backend -n devboard
```

## 5. Verify it behaves the same way — but better

```bash
kubectl port-forward -n devboard deploy/backend 8080:8080 &
sleep 2
curl -s -w " [%{http_code}]\n" localhost:8080/health   # 200
curl -s -w " [%{http_code}]\n" localhost:8080/ready    # 200
kill %1

kubectl scale deployment postgres --replicas=0 -n devboard
sleep 25
kubectl get pods -n devboard -l app=backend    # 0/1 Ready, RESTARTS 0
kubectl get endpoints backend -n devboard      # <none>

kubectl scale deployment postgres --replicas=1 -n devboard
```

## Why this is better than the exec probe

| | exec probe | `/ready` endpoint |
|---|---|---|
| Cost per check | forks a process in the container | one HTTP request handled by the kubelet |
| What it proves | a TCP port is open | **the app's own pool can execute a query** |
| Catches a saturated connection pool | no | **yes** |
| Catches wrong credentials | no | **yes** |
| Catches a database in recovery mode | no | **yes** |
| Needs the image changed | no | yes |

**Know both.** "What if you cannot change the application?" is a common
interview follow-up, and the exec probe is the answer.
