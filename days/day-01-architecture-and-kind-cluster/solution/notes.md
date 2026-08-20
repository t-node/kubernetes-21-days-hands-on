# Day 01 solution notes

There is no manifest to write today. The "solution" is the cluster config you
already used: [`cluster/kind-config.yaml`](../../../cluster/kind-config.yaml).

If your cluster is broken, reset it:

```bash
bash cluster/recreate-cluster.sh
```

Answers to the Validate self-check:

1. The **scheduler** decides where; the **kubelet** on that node starts it.
2. **kube-apiserver** is the only component that reads/writes etcd.
3. Yes. Existing pods keep serving. You just cannot schedule new ones.
4. The kubelet is a systemd service on the node, not a Pod. It has to exist
   before pods can exist at all.
5. CNI assigns pod IPs and enables cross-node pod traffic. Without it, nodes
   stay NotReady and nothing schedules.
