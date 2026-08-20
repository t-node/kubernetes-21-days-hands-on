# Scenario 8 — 403 Forbidden, everything healthy

## Diagnosis

```bash
kubectl exec -n devboard reporting -- kubectl get deployments -n devboard
```

```
Error from server (Forbidden): deployments.apps is forbidden:
User "system:serviceaccount:devboard:reporting" cannot list resource
"deployments" in API group "apps" in the namespace "devboard"
```

**Read the whole error.** It names the user, the verb, the resource, **the API
group** and the namespace. Note it says `in API group "apps"`.

```bash
kubectl get role reporting -n devboard -o yaml | grep -A5 rules
```

```yaml
rules:
  - apiGroups: [""]                                   # <-- the fault
    resources: ["pods", "services", "deployments"]
    verbs: ["get", "list", "watch"]
```

`deployments` is listed under the **core** group. Deployments live in `apps`:

```bash
kubectl api-resources | grep -E "^deployments|^pods "
# pods         po      v1        true   Pod
# deployments  deploy  apps/v1   true   Deployment
```

The Role was **accepted without any error** — RBAC does not validate that a
resource exists in the group you named. It simply grants nothing.

Confirm with impersonation:

```bash
SA=system:serviceaccount:devboard:reporting
kubectl auth can-i list pods        -n devboard --as=$SA   # yes
kubectl auth can-i list deployments -n devboard --as=$SA   # no
```

## Fix

```bash
kubectl patch role reporting -n devboard --type=json -p '[
  {"op":"replace","path":"/rules","value":[
    {"apiGroups":[""],     "resources":["pods","services"],   "verbs":["get","list","watch"]},
    {"apiGroups":["apps"], "resources":["deployments","replicasets"], "verbs":["get","list","watch"]}
  ]}
]'

kubectl auth can-i list deployments -n devboard --as=$SA    # yes
kubectl exec -n devboard reporting -- kubectl get deployments -n devboard
```

## The lesson

Two habits: **read the whole error message** — it named the API group — and
**verify RBAC with `kubectl auth can-i --as=`** rather than by trial and error.

A wrong `apiGroups` is a silent failure: no error at apply time, no event, just
permissions that quietly do not exist. (Day 19)
