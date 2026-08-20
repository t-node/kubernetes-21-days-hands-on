# Setup — do this once

You need four things: **Docker**, **kind**, **kubectl**, and a terminal you like.
Total time: about 20 minutes, most of it Docker Desktop downloading.

Nothing in this course touches a cloud account. Nothing costs money.

---

## 0. Check your hardware first

| | Minimum | Comfortable |
|---|---|---|
| RAM | 8 GB | 16 GB |
| Free disk | 15 GB | 30 GB |
| CPU | 2 cores | 4 cores |

A 3-node kind cluster idles at roughly 2 GB RAM. Adding Postgres, metrics-server
and the ingress controller takes it to about 3 GB. If you have 8 GB total and
a browser open, use the single-node config (see step 4).

---

## 1. Docker

kind runs each Kubernetes node as a Docker container, so Docker has to work
before anything else does.

### Windows 10/11

1. Install **Docker Desktop for Windows**: <https://docs.docker.com/desktop/install/windows-install/>
2. During install, keep **"Use WSL 2 instead of Hyper-V"** checked. WSL2 is
   faster and uses less memory.
3. Start Docker Desktop and wait for the whale icon to stop animating.
4. Give it enough memory: **Settings → Resources → Memory → at least 4 GB**
   (6 GB if you have 16 GB total). This is the single most common cause of
   "my cluster keeps dying".

> If Docker Desktop refuses to start, run `wsl --install` in an Administrator
> PowerShell, reboot, then try again.

### macOS

```bash
brew install --cask docker
open -a Docker
```

Apple Silicon and Intel both work. Docker Desktop → Settings → Resources →
Memory → 4 GB or more.

### Linux

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker
```

### Verify

```bash
docker version
docker run --rm hello-world
```

You must see a server version, not just a client version. If you see
`Cannot connect to the Docker daemon`, Docker Desktop is not running.

---

## 2. kubectl

`kubectl` is the CLI you will spend the next three weeks inside. It talks to the
cluster's API server over HTTPS; it does not need Docker.

### Windows (PowerShell)

The easiest route is winget:

```powershell
winget install -e --id Kubernetes.kubectl
```

Manual alternative — download and put it somewhere on your `PATH`:

```powershell
curl.exe -LO "https://dl.k8s.io/release/v1.31.4/bin/windows/amd64/kubectl.exe"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Move-Item .\kubectl.exe "$HOME\bin\kubectl.exe" -Force
# add $HOME\bin to PATH permanently:
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";$HOME\bin", "User")
```

Close and reopen the terminal so the PATH change takes effect.

### macOS

```bash
brew install kubectl
```

### Linux

```bash
curl -LO "https://dl.k8s.io/release/v1.31.4/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

### Verify

```bash
kubectl version --client
```

`Client Version: v1.31.x` is what you want. It is fine if it is a minor version
off from the cluster; kubectl supports plus or minus one minor version.

---

## 3. kind

kind = **K**ubernetes **IN** **D**ocker. It builds a real, conformant Kubernetes
cluster out of Docker containers in about 60 seconds, and deletes it just as
fast. That disposability is exactly what you want while learning.

### Windows (PowerShell)

```powershell
winget install -e --id Kubernetes.kind
```

Manual:

```powershell
curl.exe -Lo kind.exe https://kind.sigs.k8s.io/dl/v0.25.0/kind-windows-amd64
Move-Item .\kind.exe "$HOME\bin\kind.exe" -Force
```

### macOS

```bash
brew install kind
```

### Linux

```bash
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

### Verify

```bash
kind version
```

---

## 4. Get the repo and create the cluster

```bash
git clone <your-fork-url> kubernetes-21-days-hands-on
cd kubernetes-21-days-hands-on

kind create cluster --config cluster/kind-config.yaml
```

Low on RAM? Use the single-node config instead — everything works except a few
Day 18 scheduling exercises, which say so explicitly:

```bash
kind create cluster --config cluster/kind-config-single-node.yaml
```

Expected output, roughly:

```
Creating cluster "devops" ...
 - Ensuring node image (kindest/node:v1.31.4)
 - Preparing nodes
 - Writing configuration
 - Starting control-plane
 - Installing CNI
 - Installing StorageClass
 - Joining worker nodes
Set kubectl context to "kind-devops"
```

### Verify the cluster

```bash
kubectl cluster-info --context kind-devops
kubectl get nodes -o wide
```

You should see three nodes, all `Ready`:

```
NAME                   STATUS   ROLES           AGE   VERSION
devops-control-plane   Ready    control-plane   72s   v1.31.4
devops-worker          Ready    <none>          58s   v1.31.4
devops-worker2         Ready    <none>          58s   v1.31.4
```

And to prove that "nodes are just containers":

```bash
docker ps
```

Three containers, one per node. That is the whole trick behind kind.

---

## 5. Quality-of-life setup (optional, but do it)

### Shorten `kubectl` to `k`

**bash / zsh** — add to `~/.bashrc` or `~/.zshrc`:

```bash
alias k=kubectl
source <(kubectl completion bash)   # or: zsh
complete -o default -F __start_kubectl k
```

**PowerShell** — add to your profile (`notepad $PROFILE`):

```powershell
Set-Alias -Name k -Value kubectl
kubectl completion powershell | Out-String | Invoke-Expression
```

### Stop typing `-n devboard` a hundred times

Once the namespace exists (Day 03), pin it as the default for your context:

```bash
kubectl config set-context --current --namespace=devboard
```

The course still writes `-n devboard` everywhere so the commands work no matter
what your default is. Keeping the explicit flag is a good habit for real work.

### VS Code

Install the **Kubernetes** extension (`ms-kubernetes-tools.vscode-kubernetes-tools`)
and **YAML** (`redhat.vscode-yaml`). The YAML extension gives you schema
validation and autocomplete on Kubernetes manifests, which catches roughly half
of all indentation mistakes before you ever run `kubectl apply`.

---

## Setup troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop is not running | Start it and wait for the whale to settle |
| `kind: command not found` after install | PATH not reloaded | Close and reopen the terminal |
| Cluster creation hangs at "Starting control-plane" | Docker has too little memory | Docker Desktop → Settings → Resources → Memory → 4 GB+ |
| `failed to create cluster: node(s) already exist` | Old cluster of the same name | `kind delete cluster --name devops`, then create again |
| `port is already allocated` | Something else holds 30080 or 8080 | Stop it, or edit `hostPort` in `cluster/kind-config.yaml` |
| Nodes stuck `NotReady` | CNI still installing | Wait 60s; if it persists, recreate the cluster |
| `kubectl` talks to the wrong cluster | Multiple contexts | `kubectl config use-context kind-devops` |
| Everything is very slow on Windows | Repo lives on a Windows path used from WSL | Keep the repo on the same filesystem as your shell |

---

## Daily commands you will want

```bash
# start a stopped cluster (after a reboot, Docker restarts the containers)
docker start devops-control-plane devops-worker devops-worker2

# which cluster am I pointed at?
kubectl config current-context

# blow it all away and start clean
kind delete cluster --name devops
```

---

**Setup done. → [Day 01](days/day-01-architecture-and-kind-cluster/)**
