# Interview Questions

Every question from the course, plus the ones that come up most, organised by
experience level. Answers live in the day files — the day number is in brackets.

**Use this properly:** answer out loud, from memory, before opening anything.
Reading an answer and thinking "yes, I knew that" is not the same as being able
to say it under pressure.

---

## How Kubernetes interviews actually work

| Experience | What they ask |
|---|---|
| 0-2 years | definitions and basic commands. "What is a Pod?" "Deployment vs StatefulSet?" |
| 2-5 years | scenarios. "A pod is Pending, walk me through it." "How do you do a zero-downtime deploy?" |
| 5-8 years | design and trade-offs. "Should databases run in Kubernetes?" "How would you structure multi-tenancy?" |
| 8+ years | architecture and failure. "Design a platform for 50 teams." "etcd is degraded, what happens?" |

Above two years, **almost everything is a scenario**. Answer as a *process* —
what you would check, in what order, and why — not as a definition.

Three habits that read as senior at any level:

1. **State the trade-off.** "I would use X, though it costs Y" beats "X is best".
2. **Say when the answer is "do not do this".** "Use RDS unless you have a
   specific reason not to."
3. **Admit the limits of your answer.** "These numbers came from a test cluster;
   real ones need production observation."

---

## Level 1 — Fundamentals

1. What is Kubernetes and what problem does it solve? [01]
2. Explain the architecture: control plane and data plane. [01]
3. Which container runtime does Kubernetes use? (trap: not Docker) [01]
4. What is a Pod, and why not just run containers? [02]
5. What does it mean that pods are ephemeral? Give three consequences. [02]
6. `kubectl create` vs `kubectl apply`? [02]
7. What is a namespace and what does it isolate? [03]
8. Name three resources that are **not** namespaced. [03]
9. Deployment vs ReplicaSet vs Pod? [04]
10. How does a Service know which pods to send traffic to? [04, 06]
11. Labels vs annotations? [04]
12. Explain the four Service types. [06, 07]
13. `port` vs `targetPort` vs `nodePort`? [06]
14. How does DNS work inside a cluster? [06]
15. ConfigMap vs Secret? [09, 10]
16. Are Kubernetes Secrets secure? [10]
17. What are liveness and readiness probes? [13]
18. Requests vs limits? [16]
19. What is a DaemonSet? [18]
20. What is the default API server port? [01]

---

## Level 2 — Scenarios

21. A pod is stuck in `Pending`. Walk me through it. [02, 16, 18, 21]
22. `CrashLoopBackOff`. What do you do? [02, 21]
23. A Service returns nothing. How do you debug it? [06, 21]
24. Your frontend gets 502 but every pod is healthy. Where do you look? [08, 12, 21]
25. How do you do a zero-downtime deployment? [05, 13]
26. You deployed a bad image. What does the cluster look like, and what do you do? [05]
27. How do you roll back, and how fast is it? [05]
28. How do you make pods pick up a changed ConfigMap? [09]
29. Why did changing the ConfigMap not change anything? [09]
30. Your HPA shows `<unknown>` and never scales. Why? [17]
31. Your HPA scaled but half the pods are `Pending`. What is missing? [17]
32. A pod is `Running` but `0/1 Ready`. Where do you look? [13, 21]
33. Data disappeared after a pod restart. Why? [14, 21]
34. A PVC is stuck `Pending`. Walk me through it. [14]
35. Someone can list pods but not read logs. Why? [19]
36. How do you debug a container with no shell? [02, 21]
37. What is exit code 137? [16, 21]
38. Why do application pods not run on the control plane? [18]
39. How do you drain a node safely? [18]
40. How do you test whether an RBAC rule works? [19]

---

## Level 3 — Design and trade-offs

41. Should databases run in Kubernetes? [11]
42. Why is a Deployment wrong for a database? [11, 15]
43. Does a StatefulSet give you a highly available database? [15]
44. Should you set CPU limits? [16]
45. Why is memory a poor autoscaling metric? [17]
46. HPA vs VPA vs Cluster Autoscaler? [17]
47. How do you actually secure secrets in production? [10]
48. Your app needs a DSN containing the password. How do you keep the
    ConfigMap/Secret split clean? [10]
49. How do you rotate a database password with zero downtime? [10, 11]
50. You have 30 microservices to expose. How? [07, 20]
51. Is Ingress deprecated? [20]
52. What problems does the Gateway API solve? [20]
53. How would you migrate from Ingress to the Gateway API? [20]
54. How do you guarantee replicas land on different nodes, and what is the trap? [18]
55. Taints and tolerations vs node affinity? [18]
56. How would you give a new team access to their own namespace only? [19]
57. Which RBAC permissions should you guard most carefully? [19]
58. How do you handle schema migrations with rolling updates? [05, 11]
59. How do you organise manifests across environments? [12]
60. When is Kubernetes the **wrong** tool? [01, 12]

---

## Level 4 — Senior and architecture

61. What happens if etcd is lost? What is your recovery plan? [01]
62. Why are the control-plane components static pods? [01, 18]
63. Does a Service load balance HTTP requests? (trap: no) [06]
64. Explain `ndots:5` and when it becomes a problem. [06]
65. What is gang scheduling, and does Kubernetes support it? [18]
66. How would you back up and restore a stateful workload? Prove the restore. [11, 15]
67. Design a multi-tenant platform for 50 teams. What are your boundaries? [03, 19]
68. RBAC vs admission control — where does each apply? [19]
69. How do you audit RBAC on a cluster you inherited? [19]
70. What changes when you move this from kind to EKS? [capstone]
71. How would you autoscale on requests-per-second or queue depth? [17]
72. A microservice is slow but the cluster looks fine. Where do you look? [16, 21]
73. How do you achieve real canary deployments? [05, 20]
74. What is a PodDisruptionBudget, and what does it *not* protect against? [18]
75. Can you convert a Deployment to a StatefulSet in place? [15]

---

## The traps

Questions where the obvious answer is wrong. Getting these right stands out.

| Question | The trap |
|---|---|
| "Which container runtime does Kubernetes use?" | **Not Docker** — any CRI runtime; dockershim was removed in 1.24 |
| "How do you create a user?" | **You cannot** — there is no User object; users are strings from the authenticator |
| "Is the API server stateful?" | **No** — stateless and horizontally scalable; state lives in etcd |
| "Are Secrets encrypted?" | **No** — base64 is encoding; encryption at rest is separate configuration |
| "Does ReadWriteOnce mean one pod?" | **No, one NODE.** Several pods on the same node can mount it |
| "Are namespaces a security boundary?" | **Not by default** — they scope the API, not the network |
| "Does a Service load balance requests?" | **No, connections.** A keep-alive client pins to one pod |
| "Can you write a deny rule in RBAC?" | **No** — RBAC is purely additive |
| "Does a toleration put a pod on a tainted node?" | **No** — that is permission; you also need affinity |
| "Is a PersistentVolume namespaced?" | **No** — cluster-scoped. The PVC is namespaced |
| "Does the HPA add nodes?" | **No** — that is the Cluster Autoscaler |
| "Does an Ingress object do anything on its own?" | **No** — inert without a controller |
| "Is Ingress deprecated?" | **Not in Kubernetes** — stable but frozen; Ingress-NGINX the *project* is in maintenance |
| "Does the scheduler look at actual usage?" | **No** — only requests |
| "Does a StatefulSet set up replication?" | **No** — identity and storage only |
| "Do env vars from a ConfigMap update?" | **Never.** A process's environment is fixed at exec |
| "Do subPath volume mounts update?" | **Never.** They bypass the atomic-swap symlink |
| "Does `pods` include `pods/log`?" | **No** — subresources are separate permissions |

---

## The five you must be able to answer cold

If you prepare nothing else:

1. **Explain the Kubernetes architecture.** [01]
2. **Walk me through what happens when you `kubectl apply` a Deployment.** [01]
3. **A pod is Pending / CrashLooping. Debug it out loud.** [21]
4. **Liveness vs readiness, and why liveness must not check the database.** [13]
5. **How do you do a zero-downtime deploy, and roll it back?** [05]

---

## Questions to ask them

Interviews go both ways, and good questions signal experience:

- How many clusters, and how do you manage them? Are they cattle or pets?
- How do you handle secrets today?
- What does your deployment pipeline look like — GitOps, or CI pushing?
- Who is on call for the cluster, and what does a typical page look like?
- Ingress or Gateway API? What is your migration plan?
- Are you running databases in-cluster? Why or why not?
- What is your worst Kubernetes incident so far, and what changed after it?

That last one tells you more about a team than anything on their careers page.

---

## Practising

- **[Day 21](days/day-21-break-and-fix-troubleshooting/)** is nine deliberately
  broken clusters. Solving those under time pressure is the closest thing here
  to a live technical screen.
- **The [capstone](capstone/) exit interview** is ten questions requiring you to
  defend your own design — which is what a senior interview actually feels like.
- **Say the answers out loud.** The gap between "I understand this" and "I can
  explain this in 60 seconds" is closed entirely by practice, and it is exactly
  the gap interviews measure.
