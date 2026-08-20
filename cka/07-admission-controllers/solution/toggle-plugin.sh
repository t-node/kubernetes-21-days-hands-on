#!/usr/bin/env bash
# Add or remove an admission plugin on the kube-apiserver static pod manifest.
#
#   bash toggle-plugin.sh add-enable   NamespaceAutoProvision
#   bash toggle-plugin.sh del-enable   NamespaceAutoProvision
#   bash toggle-plugin.sh add-disable  DefaultStorageClass
#   bash toggle-plugin.sh del-disable  DefaultStorageClass
#
# It edits on the host and copies back, rather than running an editor inside the
# node -- fewer ways to leave a half-written manifest behind.
set -euo pipefail

CP=${CP:-devops-control-plane}
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
ACTION=${1:-}
PLUGIN=${2:-}
[ -n "$ACTION" ] && [ -n "$PLUGIN" ] || { echo "usage: $0 <add-enable|del-enable|add-disable|del-disable> <Plugin>"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

docker exec "$CP" test -f /root/apiserver.backup.yaml 2>/dev/null || {
  echo "-- taking a first-time backup at /root/apiserver.backup.yaml on $CP"
  docker exec "$CP" cp "$MANIFEST" /root/apiserver.backup.yaml
}

docker cp "$CP:$MANIFEST" "$WORK/api.yaml"

FLAG=enable-admission-plugins
case "$ACTION" in
  *disable) FLAG=disable-admission-plugins ;;
esac

python - "$WORK/api.yaml" "$ACTION" "$PLUGIN" "$FLAG" <<'PY'
import sys, re
path, action, plugin, flag = sys.argv[1:5]
lines = open(path).read().split("\n")
idx = next((i for i, l in enumerate(lines) if "--" + flag + "=" in l), None)

if action.startswith("add"):
    if idx is None:
        # insert next to the other apiserver flags, preserving indentation
        anchor = next(i for i, l in enumerate(lines) if "--advertise-address" in l or l.strip().startswith("- --"))
        indent = lines[anchor][:len(lines[anchor]) - len(lines[anchor].lstrip())]
        lines.insert(anchor, indent + "- --" + flag + "=" + plugin)
        print("ADDED new flag: --" + flag + "=" + plugin)
    else:
        cur = lines[idx].split("=", 1)[1].strip()
        vals = [v for v in cur.split(",") if v]
        if plugin in vals:
            print("already present, nothing to do")
        else:
            vals.append(plugin)
            lines[idx] = lines[idx].split("=", 1)[0] + "=" + ",".join(vals)
            print("UPDATED: --" + flag + "=" + ",".join(vals))
else:
    if idx is None:
        print("flag not present, nothing to do")
    else:
        vals = [v for v in lines[idx].split("=", 1)[1].strip().split(",") if v and v != plugin]
        if vals:
            lines[idx] = lines[idx].split("=", 1)[0] + "=" + ",".join(vals)
            print("UPDATED: --" + flag + "=" + ",".join(vals))
        else:
            del lines[idx]
            print("REMOVED the now-empty --" + flag + " flag")

open(path, "w", newline="\n").write("\n".join(lines))
PY

docker cp "$WORK/api.yaml" "$CP:$MANIFEST"
echo "-- manifest replaced; kubelet will restart the API server"

echo -n "-- waiting for the API server"
for i in $(seq 1 90); do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then
    echo " ... back after ${i}s"
    exit 0
  fi
  echo -n "."
  sleep 1
done
echo
echo "!! API server did not come back in 90s."
echo "!! Inspect:  docker exec $CP crictl ps -a | grep apiserver"
echo "!! Restore:  docker exec $CP cp /root/apiserver.backup.yaml $MANIFEST"
exit 1
