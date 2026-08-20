#!/usr/bin/env bash
# Prepare the mock exam.
#
#   bash solution/setup-mock.sh          create the namespaces and the broken objects
#   bash solution/setup-mock.sh clean    remove everything the mock exam created
#
# It prints NOTHING about what is broken. That is the exercise.
set -uo pipefail
NSS="mock-a mock-w mock-n mock-s mock-t1 mock-t2 mock-t3 mock-t4 mock-t5"

if [ "${1:-}" = "clean" ]; then
  echo "==> removing mock exam objects"
  for ns in $NSS; do kubectl delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1; done
  kubectl label node devops-worker2 tier- >/dev/null 2>&1
  kubectl taint node devops-worker2 mock-t4- >/dev/null 2>&1
  kubectl uncordon devops-worker2 >/dev/null 2>&1
  docker exec devops-worker rm -f /etc/kubernetes/manifests/mock-static.yaml >/dev/null 2>&1
  rm -f /tmp/mock-dns.txt /tmp/mock-unschedulable.txt 2>/dev/null
  echo "    done (namespaces terminate in the background)"
  exit 0
fi

echo "==> creating namespaces"
for ns in $NSS; do
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

echo "==> creating the objects the tasks operate on"

# --- mock-n: a Deployment for the networking tasks
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: mock-n, labels: {app: web}}
spec:
  replicas: 3
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports: [{name: http, containerPort: 80}]
          readinessProbe: {httpGet: {path: /, port: http}, periodSeconds: 3}
          resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF

# --- mock-t1: a Service whose selector matches nothing
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: mock-t1, labels: {app: web}}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports: [{name: http, containerPort: 80}]
          readinessProbe: {httpGet: {path: /, port: http}, periodSeconds: 3}
          resources: {requests: {cpu: 10m, memory: 16Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: web, namespace: mock-t1}
spec:
  selector: {app: web-server}
  ports: [{name: http, port: 80, targetPort: http}]
---
apiVersion: v1
kind: Pod
metadata: {name: client, namespace: mock-t1}
spec:
  containers:
    - name: c
      image: curlimages/curl:8.10.1
      command: ["sleep", "36000"]
      resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF

# --- mock-t2: a readiness probe pointed at a port nothing listens on
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: mock-t2, labels: {app: api}}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports: [{name: http, containerPort: 80}]
          readinessProbe:
            httpGet: {path: /, port: 8080}
            periodSeconds: 3
          resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF

# --- mock-t3: a pod referencing a ConfigMap key that does not exist
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: cache-config, namespace: mock-t3}
data:
  MAX_ENTRIES: "1000"
---
apiVersion: v1
kind: Pod
metadata: {name: cache, namespace: mock-t3, labels: {app: cache}}
spec:
  containers:
    - name: cache
      image: nginx:1.27-alpine
      env:
        - name: CACHE_SIZE
          valueFrom:
            configMapKeyRef: {name: cache-config, key: CACHE_SIZE_MB}
      resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF

# --- mock-t4: a taint on the only node the workload tolerates... inverted
kubectl taint node devops-worker2 mock-t4=blocked:NoSchedule --overwrite >/dev/null 2>&1
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker, namespace: mock-t4, labels: {app: worker}}
spec:
  replicas: 3
  selector: {matchLabels: {app: worker}}
  template:
    metadata: {labels: {app: worker}}
    spec:
      # The workload's requirements are CORRECT: it tolerates the batch taint
      # it is supposed to run under, and requires the batch node label.
      tolerations:
        - key: workload
          operator: Equal
          value: batch
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: workload-class
                    operator: In
                    values: ["batch"]
      containers:
        - name: worker
          image: nginx:1.27-alpine
          resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF

# --- mock-t5: a ServiceAccount with no permissions
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata: {name: reader, namespace: mock-t5}
EOF

echo
echo "==> ready. Namespaces created:"
kubectl get ns | grep mock-
echo
echo "Five of them contain something broken. Nothing here says what."
echo
echo "Set a timer for 2 hours and start at Task 1."
echo "Grade yourself with:  bash solution/grade.sh"
