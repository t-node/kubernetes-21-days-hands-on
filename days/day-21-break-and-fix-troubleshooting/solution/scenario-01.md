# Scenario 1 — no tasks in the UI

**Symptom:** UI loads, board is empty, `/api/tasks` fails. All pods `1/1 Running`.

## Diagnosis

```bash
kubectl get pods -n devboard              # everything Running and Ready
kubectl get endpoints -n devboard         # backend: <none>   <-- THE ANSWER
```

Healthy pods plus empty endpoints means a **Service to Pod** problem: either the
selector does not match, or no pod is Ready. The pods are `1/1`, so it is the
selector.

```bash
kubectl get svc backend -n devboard -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"devboard-backend"}
kubectl get pods -n devboard --show-labels | grep backend
# app=backend,tier=api
```

`devboard-backend` != `backend`.

## Fix

```bash
kubectl patch svc backend -n devboard -p '{"spec":{"selector":{"app":"backend"}}}'
kubectl get endpoints backend -n devboard
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30080/api/tasks
```

## The lesson

`kubectl get endpoints` is the **first** command for any "the service does not
work" report. Nothing in `kubectl logs` would have shown this — the backend
never received a request to log. (Day 06)
