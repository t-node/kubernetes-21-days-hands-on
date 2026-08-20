# Day 19 solution

```bash
kubectl apply -f .
kubectl get sa,roles,rolebindings -n devboard
```

## The core test

```bash
SA=system:serviceaccount:devboard:devboard-intern

kubectl auth can-i list   pods    -n devboard --as=$SA   # yes
kubectl auth can-i get    pods/log -n devboard --as=$SA  # yes
kubectl auth can-i delete pods    -n devboard --as=$SA   # no
kubectl auth can-i get    secrets -n devboard --as=$SA   # NO  <- the point
kubectl auth can-i create pods/exec -n devboard --as=$SA # NO  <- also the point

kubectl auth can-i --list -n devboard --as=$SA
```

And end to end, through a real pod:

```bash
kubectl wait --for=condition=Ready pod/rbac-intern -n devboard --timeout=90s
kubectl exec -n devboard rbac-intern -- kubectl get pods -n devboard
kubectl exec -n devboard rbac-intern -- kubectl delete pod rbac-intern -n devboard
# Error from server (Forbidden): ... cannot delete resource "pods" ...
```

## Files

| File | Shows |
|---|---|
| `01-serviceaccounts.yaml` | identities for pods — they start with **zero** permissions |
| `02-role-viewer.yaml` | read-only, deliberately excluding secrets and exec |
| `03-rolebinding-intern.yaml` | Role → ServiceAccount, namespaced |
| `04-test-pods.yaml` | pods running `kubectl` as those identities |
| `05` + `06` | a namespace admin: all power inside, none outside |
| `07-rolebinding-builtin-view.yaml` | **the pattern to actually use**: RoleBinding → built-in ClusterRole |
| `08-app-serviceaccount.yaml` | least privilege, narrowed with `resourceNames` |
| `09-role-pods-only.yaml` | Break It A: `pods` ≠ `pods/log` |
| `10-role-exec-danger.yaml` | Break It B: `pods/exec` bypasses everything |
| `11-role-wrong-apigroup.yaml` | Break It C: wrong apiGroup, **accepted silently**, grants nothing |

## The four rules worth carrying out of today

1. **RBAC is additive.** There is no deny. To remove access, remove a binding.
2. **Subresources are separate.** `pods` does not include `pods/log` or
   `pods/exec`.
3. **`pods/exec` is admin-level.** It bypasses every restriction on secrets.
4. **Bind built-in ClusterRoles with RoleBindings.** Do not hand-write viewer
   roles; `view`, `edit` and `admin` already exist and are maintained for you.

## Clean up before Day 20

```bash
kubectl delete pod rbac-intern rbac-admin config-reader -n devboard --ignore-not-found
kubectl delete clusterrolebinding dangerous --ignore-not-found
kubectl delete rolebinding oops-admin -n devboard --ignore-not-found
```

Keep the ServiceAccounts and Roles — the Capstone reuses them.
