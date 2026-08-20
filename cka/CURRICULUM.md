# CKA Curriculum — the complete ordered path

Every lecture in the 312-lecture source course, mapped to an assignment.

**200 lectures carry transcript content. All 200 are mapped. Nothing is unaccounted for.**

The order below is the order to work through them: each assignment assumes
the ones before it. Where a topic is already taught in the 21-day track, the
assignment says so and links there rather than repeating it.

Reference for the source course:
[kodekloudhub/certified-kubernetes-administrator-course](https://github.com/kodekloudhub/certified-kubernetes-administrator-course)

---
## How the two tracks fit together

| | **21 Days** | **CKA assignments** |
|---|---|---|
| Teaches | deploying and operating an app | building and repairing the cluster |
| Shape | one app, evolved daily | topic-by-topic, exam-shaped |
| Start here if | you are new to Kubernetes | you can already deploy an app |

**Recommended path:** Days 01-21, then CKA 01-33 in order. If you already
deploy to Kubernetes at work, start at CKA 01 and follow the *Builds on*
column back into the 21 days when you need ground under a topic.

---
## The assignments

33 assignments. **10 built, 23 to build.**


### Core Concepts

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 01 | [Control Plane Components in Depth](01-control-plane-components/) | 14, 15, 16, 17 | Day 01 | **built** |
| 02 | [Container Runtimes: CRI, OCI, crictl](02-container-runtimes-and-crictl/) | 8, 9 | Day 01 | **built** |
| 03 | [etcd and Cluster Data](03-etcd-and-cluster-data/) | 10, 11, 12 | CKA 02 | **built** |
| 04 | [Imperative vs Declarative, and kubectl apply](04-imperative-declarative-and-apply/) | 41, 43, 45, 46, 48 | Day 02 | **built** |

### Scheduling

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 05 | [Manual Scheduling and Static Pods](05-manual-scheduling-and-static-pods/) | 50, 51, 53, 72, 74 | Day 18 | **built** |
| 06 | [Priority Classes, Multiple Schedulers, Profiles](06-priority-schedulers-profiles/) | 75, 77, 79, 80 | CKA 05 | **built** |
| 07 | Admission Controllers | 81, 83, 84, 86 | CKA 15 | to build |

### Application Lifecycle Management

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 08 | [Commands and Arguments](08-commands-and-arguments/) | 99, 100, 102 | Day 02 | **built** |
| 09 | Encrypting Secret Data at Rest | 110, 111 | Day 10, CKA 03 | to build |
| 10 | Multi-Container Pods and Init Containers | 114, 115, 119 | Day 02, Day 12 | to build |
| 11 | Autoscaling: VPA and In-Place Resize | 121, 122, 125, 126 | Day 17 | to build |

### Cluster Maintenance

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 12 | [Cluster Maintenance and etcd Backup/Restore](12-cluster-maintenance/) | 129, 130, 132, 133, 134, 136 | CKA 03 | **built** |

### Security

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 13 | TLS in Kubernetes | 141, 142, 143, 144, 145, 146, 147, 148, 151 | CKA 03 | to build |
| 14 | [KubeConfig and the API](14-kubeconfig-and-the-api/) | 155, 157, 159 | CKA 13 | **built** |
| 15 | [Certificates API and Authorization Modes](15-certificates-api-and-authorization/) | 152, 154, 160, 161, 163, 164, 166 | CKA 14, Day 19 | **built** |
| 16 | Service Accounts | 167, 169 | CKA 15 | to build |
| 17 | Image Security and Security Contexts | 170, 172, 173, 174, 176 | Day 08 | to build |
| 18 | Network Policies | 177, 178, 180 | Day 06, Day 12 | to build |
| 19 | CRDs, Custom Controllers, Operators | 182, 184, 185 | Day 15 | to build |

### Storage

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 20 | Storage Internals and CSI | 186, 187, 188, 189, 190, 191, 192, 193, 196, 199, 201 | Day 14 | to build |

### Networking

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 21 | Linux Networking Foundations | 202, 203, 204, 206, 208 | none | to build |
| 22 | Pod Networking and CNI | 209, 210, 213, 214, 215, 217, 219, 220 | CKA 21 | to build |
| 23 | Service Networking | 222, 224 | Day 06, CKA 22 | to build |
| 24 | DNS and CoreDNS | 225, 226, 228 | Day 06 | to build |
| 25 | Ingress and the Gateway API in Depth | 229, 233, 235, 236 | Day 20 | to build |

### Design and Install

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 26 | Cluster Design and High Availability | 239, 240, 241, 242 | CKA 03, CKA 12 | to build |

### Install kubeadm way

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 27 | Build a Cluster with kubeadm | 244, 246, 247, 249 | CKA 26 | to build |

### Helm

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 28 | Helm | 250, 251, 253, 254, 255, 256, 257, 259 | Day 12 | to build |

### Kustomize

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 29 | Kustomize: Structure and Transformers | 261, 262, 263, 264, 265, 266, 267, 268, 270, 271, 272 | Day 12 | to build |
| 30 | Kustomize: Patches, Overlays, Components | 274, 275, 276, 277, 279, 281 | CKA 29 | to build |

### Troubleshooting

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 31 | Troubleshooting: The Three Failure Domains | 283, 284, 286, 287, 289, 290, 292 | Day 21 | to build |

### Other Topics JSONPath

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 32 | JSONPath and Output Formatting | 297 | Day 02 | to build |

### Mock Exams

| # | Assignment | Lectures | Builds on | Status |
|---|---|---|---|---|
| 33 | Mock Exam Task Bank | 302, 304, 306 | everything | to build |

---
## Lectures already covered by the 21-day track

These need no CKA assignment — the main track teaches them, often in more
depth, because it applies them to a real application.

| Lecture | Title | Covered by |
|---:|---|---|
| 1 | Course Introduction | orientation |
| 2 | Certification | orientation |
| 4 | The Kubernetes Trilogy | orientation |
| 6 | Core Concepts - Section Introduction | Day 01 |
| 7 | Cluster Architecture | Day 01 |
| 13 | Kube-API Server | Day 01 |
| 18 | Pods | Day 02 |
| 19 | Pods with YAML | Day 02 |
| 20 | Demo - Pods with YAML | Day 02 |
| 21 | Practice Test Introduction | Day 02 |
| 25 | Lab Solution - Pods (optional) | Day 02 |
| 26 | Recap - ReplicaSets | Day 04 |
| 28 | Lab Solution - ReplicaSets (optional) | Day 04 |
| 29 | Deployments | Day 04 |
| 32 | Lab Solution - Deployments (optional) | Day 04 |
| 33 | Services | Day 06 |
| 34 | Services Cluster IP | Day 06 |
| 35 | Services - Loadbalancer | Day 07 |
| 37 | Lab Solution - Services (optional) | Day 06 |
| 38 | Namespaces | Day 03 |
| 40 | Lab Solution - Namespaces (optional) | Day 03 |
| 54 | Labels and Selectors | Day 04 |
| 56 | Lab Solution : Labels and Selectors : (Optional) | Day 04 |
| 57 | Taints and Tolerations | Day 18 |
| 59 | Lab Solution -  Taints and Tolerations (Optional) | Day 18 |
| 60 | Node Selectors | Day 18 |
| 61 | Node Affinity | Day 18 |
| 63 | Lab Solution - Node Affinity (Optional) | Day 18 |
| 64 | Taints and Tolerations vs Node Affinity | Day 18 |
| 65 | Resource Requirements | Day 16 |
| 68 | Lab Solution - Resource Limits | Day 16 |
| 69 | DaemonSets | Day 18 |
| 71 | Lab Solution - DaemonSets (optional) | Day 18 |
| 87 | Logging and Monitoring - Section Introduction | Day 16 |
| 88 | Monitor Cluster Components | Day 16 |
| 90 | Lab Solution: Monitor Cluster Components | Day 16 |
| 91 | Managing Application Logs | Day 02 |
| 93 | Lab Solution: Logging : (Optional) | Day 02 |
| 94 | Application Lifecycle Management - Section Introduction | Day 05 |
| 95 | Rolling Updates and Rollbacks | Day 05 |
| 97 | Lab Solution: Rolling update | Day 05 |
| 103 | Configure Environment Variables in Applications | Day 09 |
| 104 | Configuring ConfigMaps in Applications | Day 09 |
| 106 | Lab Solution -  Env Variables (Optional) | Day 09 |
| 107 | Secrets | Day 10 |
| 310 | Conclusion | orientation |
| 311 | What's Next? | Capstone |

---
## Full lecture index

Every lecture in course order. `-` means the export carried no transcript
(a quiz, or a hands-on lab with no narration).

| # | Lecture | Section | Assignment |
|---:|---|---|---|
| 1 | Course Introduction | Introduction | orientation |
| 2 | Certification | Introduction | orientation |
| 3 | Course Release Notes | Introduction | - |
| 4 | The Kubernetes Trilogy | Introduction | orientation |
| 5 | Notes available at KodeKloud Notes | Introduction | - |
| 6 | Core Concepts - Section Introduction | Core Concepts | Day 01 |
| 7 | Cluster Architecture | Core Concepts | Day 01 |
| 8 | Docker-vs-ContainerD | Core Concepts | CKA 02 |
| 9 | A note on Docker deprecation | Core Concepts | CKA 02 |
| 10 | ETCD For Beginners | Core Concepts | CKA 03 |
| 11 | ETCD in Kubernetes | Core Concepts | CKA 03 |
| 12 | ETCD - Commands (Optional) | Core Concepts | - |
| 13 | Kube-API Server | Core Concepts | Day 01 |
| 14 | Kube Controller Manager | Core Concepts | CKA 01 |
| 15 | Kube Scheduler | Core Concepts | CKA 01 |
| 16 | Kubelet | Core Concepts | CKA 01 |
| 17 | Kube Proxy | Core Concepts | CKA 01 |
| 18 | Pods | Core Concepts | Day 02 |
| 19 | Pods with YAML | Core Concepts | Day 02 |
| 20 | Demo - Pods with YAML | Core Concepts | Day 02 |
| 21 | Practice Test Introduction | Core Concepts | Day 02 |
| 22 | Demo: Accessing Labs | Core Concepts | - |
| 23 | Course setup - accessing the labs | Core Concepts | - |
| 24 | Lab - Pods | Core Concepts | - |
| 25 | Lab Solution - Pods (optional) | Core Concepts | Day 02 |
| 26 | Recap - ReplicaSets | Core Concepts | Day 04 |
| 27 | Lab - ReplicaSets | Core Concepts | - |
| 28 | Lab Solution - ReplicaSets (optional) | Core Concepts | Day 04 |
| 29 | Deployments | Core Concepts | Day 04 |
| 30 | Certification Tip! | Core Concepts | - |
| 31 | Lab - Deployments | Core Concepts | - |
| 32 | Lab Solution - Deployments (optional) | Core Concepts | Day 04 |
| 33 | Services | Core Concepts | Day 06 |
| 34 | Services Cluster IP | Core Concepts | Day 06 |
| 35 | Services - Loadbalancer | Core Concepts | Day 07 |
| 36 | Lab- Services | Core Concepts | - |
| 37 | Lab Solution - Services (optional) | Core Concepts | Day 06 |
| 38 | Namespaces | Core Concepts | Day 03 |
| 39 | Lab - Namespaces | Core Concepts | - |
| 40 | Lab Solution - Namespaces (optional) | Core Concepts | Day 03 |
| 41 | Imperative vs Declarative | Core Concepts | CKA 04 |
| 42 | Certification Tips - Imperative Commands with Kubectl | Core Concepts | - |
| 43 | Kubectl Explain Command | Core Concepts | CKA 04 |
| 44 | Lab - Imperative Commands | Core Concepts | - |
| 45 | Lab Solution - Imperative Commands (optional) | Core Concepts | CKA 04 |
| 46 | Kubectl Apply Command | Core Concepts | CKA 04 |
| 47 | Here's some inspiration to keep going | Core Concepts | - |
| 48 | A Quick Reminder | Core Concepts | CKA 04 |
| 49 | Reference Notes for lectures and labs | Core Concepts | - |
| 50 | Scheduling - Section Introduction | Scheduling | CKA 05 |
| 51 | Manual Scheduling | Scheduling | CKA 05 |
| 52 | Lab- Manual Scheduling | Scheduling | - |
| 53 | Lab Solution -  Manual Scheduling (optional) | Scheduling | CKA 05 |
| 54 | Labels and Selectors | Scheduling | Day 04 |
| 55 | Lab - Labels and Selectors | Scheduling | - |
| 56 | Lab Solution : Labels and Selectors : (Optional) | Scheduling | Day 04 |
| 57 | Taints and Tolerations | Scheduling | Day 18 |
| 58 | Lab - Taints and Tolerations | Scheduling | - |
| 59 | Lab Solution -  Taints and Tolerations (Optional) | Scheduling | Day 18 |
| 60 | Node Selectors | Scheduling | Day 18 |
| 61 | Node Affinity | Scheduling | Day 18 |
| 62 | Lab - Node Affinity | Scheduling | - |
| 63 | Lab Solution - Node Affinity (Optional) | Scheduling | Day 18 |
| 64 | Taints and Tolerations vs Node Affinity | Scheduling | Day 18 |
| 65 | Resource Requirements | Scheduling | Day 16 |
| 66 | A quick note on editing Pods and Deployments | Scheduling | - |
| 67 | Lab - Resource Limits | Scheduling | - |
| 68 | Lab Solution - Resource Limits | Scheduling | Day 16 |
| 69 | DaemonSets | Scheduling | Day 18 |
| 70 | Lab - DaemonSets | Scheduling | - |
| 71 | Lab Solution - DaemonSets (optional) | Scheduling | Day 18 |
| 72 | Static Pods | Scheduling | CKA 05 |
| 73 | Lab - Static Pods | Scheduling | - |
| 74 | Lab Solution - Static Pods (Optional) | Scheduling | CKA 05 |
| 75 | Priority Classes | Scheduling | CKA 06 |
| 76 | Lab - Priority Classes | Scheduling | - |
| 77 | Multiple Schedulers | Scheduling | CKA 06 |
| 78 | Lab - Multiple Schedulers | Scheduling | - |
| 79 | Lab Solution - Multiple Scheduler | Scheduling | CKA 06 |
| 80 | Configuring Scheduler Profiles | Scheduling | CKA 06 |
| 81 | (2025 Updates)Admission Controllers | Scheduling | CKA 07 |
| 82 | (2025 Updates)Lab – Admission Controllers | Scheduling | - |
| 83 | (2025 Updates)Lab Solution: Admission Controllers | Scheduling | CKA 07 |
| 84 | (2025 Updates)Validating and Mutating Admission Controllers | Scheduling | CKA 07 |
| 85 | (2025 Updates)Lab  – Validating and Mutating Admission Controllers | Scheduling | - |
| 86 | (2025 Updates)Lab Solution: Validating and Mutating Admission Controllers | Scheduling | CKA 07 |
| 87 | Logging and Monitoring - Section Introduction | Logging and Monitoring | Day 16 |
| 88 | Monitor Cluster Components | Logging and Monitoring | Day 16 |
| 89 | Lab - Monitoring Cluster Components | Logging and Monitoring | - |
| 90 | Lab Solution: Monitor Cluster Components | Logging and Monitoring | Day 16 |
| 91 | Managing Application Logs | Logging and Monitoring | Day 02 |
| 92 | Lab - Monitor Application Logs | Logging and Monitoring | - |
| 93 | Lab Solution: Logging : (Optional) | Logging and Monitoring | Day 02 |
| 94 | Application Lifecycle Management - Section Introduction | Application Lifecycle Management | Day 05 |
| 95 | Rolling Updates and Rollbacks | Application Lifecycle Management | Day 05 |
| 96 | Lab - Rolling Updates and Rollbacks | Application Lifecycle Management | - |
| 97 | Lab Solution: Rolling update | Application Lifecycle Management | Day 05 |
| 98 | Configure Applications | Application Lifecycle Management | - |
| 99 | Commands and Arguments in Docker | Application Lifecycle Management | CKA 08 |
| 100 | Commands and Arguments in Kubernetes | Application Lifecycle Management | CKA 08 |
| 101 | Lab - Commands and Arguments | Application Lifecycle Management | - |
| 102 | Lab Solution -  Commands and Arguments (Optional) | Application Lifecycle Management | CKA 08 |
| 103 | Configure Environment Variables in Applications | Application Lifecycle Management | Day 09 |
| 104 | Configuring ConfigMaps in Applications | Application Lifecycle Management | Day 09 |
| 105 | Lab: Env Variables | Application Lifecycle Management | - |
| 106 | Lab Solution -  Env Variables (Optional) | Application Lifecycle Management | Day 09 |
| 107 | Secrets | Application Lifecycle Management | Day 10 |
| 108 | Lab - Secrets | Application Lifecycle Management | - |
| 109 | Additional Resource | Application Lifecycle Management | - |
| 110 | Lab Solution -  Secrets (Optional) | Application Lifecycle Management | CKA 09 |
| 111 | Demo: Encrypting Secret Data at Rest | Application Lifecycle Management | CKA 09 |
| 112 | A Note on Secrets | Application Lifecycle Management | - |
| 113 | Scale Applications | Application Lifecycle Management | - |
| 114 | Multi Container Pods | Application Lifecycle Management | CKA 10 |
| 115 | Multi container Pods Design Pattern | Application Lifecycle Management | CKA 10 |
| 116 | Lab - Multi Container Pods | Application Lifecycle Management | - |
| 117 | InitContainers | Application Lifecycle Management | - |
| 118 | Lab - Init Containers | Application Lifecycle Management | - |
| 119 | Lab Solution - Init Containers (Optional) | Application Lifecycle Management | CKA 10 |
| 120 | Self Healing Applications | Application Lifecycle Management | - |
| 121 | (2025 Updates) Introduction to Autoscaling? | Application Lifecycle Management | CKA 11 |
| 122 | (2025 Updates) Horizontal Pod Autoscaler (HPA)? | Application Lifecycle Management | CKA 11 |
| 123 | (2025 Updates) Lab - Manual Scaling? | Application Lifecycle Management | - |
| 124 | (2025 Updates) Lab - HPA? | Application Lifecycle Management | - |
| 125 | (2025 Updates) In-Place Resize of Pods? | Application Lifecycle Management | CKA 11 |
| 126 | (2025 Updates) Vertical Pod Autoscaling (VPA)? | Application Lifecycle Management | CKA 11 |
| 127 | (2025 Updates) Lab - Install VPA? | Application Lifecycle Management | - |
| 128 | (2025 Updates) Lab - Modifying CPU resources in VPA? | Application Lifecycle Management | - |
| 129 | Cluster Maintenance - Section Introduction | Cluster Maintenance | CKA 12 |
| 130 | OS Upgrades | Cluster Maintenance | CKA 12 |
| 131 | Lab - OS Upgrades | Cluster Maintenance | - |
| 132 | Kubernetes Releases | Cluster Maintenance | CKA 12 |
| 133 | Cluster Upgrade Introduction | Cluster Maintenance | CKA 12 |
| 134 | Demo - Cluster upgrade | Cluster Maintenance | CKA 12 |
| 135 | Lab - Cluster Upgrade | Cluster Maintenance | - |
| 136 | Backup and Restore Methods | Cluster Maintenance | CKA 12 |
| 137 | Working with ETCDCTL and ETCDUTL | Cluster Maintenance | - |
| 138 | Lab - Backup and Restore Methods | Cluster Maintenance | - |
| 139 | Certification Exam Tip! | Cluster Maintenance | - |
| 140 | References | Cluster Maintenance | - |
| 141 | Security - Section Introduction | Security | CKA 13 |
| 142 | Kubernetes Security Primitives | Security | CKA 13 |
| 143 | Authentication | Security | CKA 13 |
| 144 | TLS Introduction | Security | CKA 13 |
| 145 | TLS Basics | Security | CKA 13 |
| 146 | TLS in Kubernetes | Security | CKA 13 |
| 147 | TLS in Kubernetes - Certificate Creation | Security | CKA 13 |
| 148 | View Certificate Details | Security | CKA 13 |
| 149 | Resource: Download Kubernetes Certificate Health Check Spreadsheet | Security | - |
| 150 | Lab - View Certificates | Security | - |
| 151 | Lab Solution - View Certification Details | Security | CKA 13 |
| 152 | Certificates API | Security | CKA 15 |
| 153 | Lab - Certificates API | Security | - |
| 154 | Lab Solution - Certificates API | Security | CKA 15 |
| 155 | KubeConfig | Security | CKA 14 |
| 156 | Lab - KubeConfig | Security | - |
| 157 | Lab Solution - KubeConfig | Security | CKA 14 |
| 158 | Persistent Key/Value Store | Security | - |
| 159 | API Groups | Security | CKA 14 |
| 160 | Authorization | Security | CKA 15 |
| 161 | Role Based Access Controls | Security | CKA 15 |
| 162 | Lab - Role-Based Access Controls | Security | - |
| 163 | Lab Solution - Role-Based Access Controls | Security | CKA 15 |
| 164 | Cluster Roles | Security | CKA 15 |
| 165 | Lab - Cluster Roles | Security | - |
| 166 | Lab Solution - Cluster Roles | Security | CKA 15 |
| 167 | Service Accounts | Security | CKA 16 |
| 168 | Lab: Service Accounts | Security | - |
| 169 | Lab Solution:  Service Accounts | Security | CKA 16 |
| 170 | Image Security | Security | CKA 17 |
| 171 | Lab - Image Security | Security | - |
| 172 | Lab Solution - Image Security | Security | CKA 17 |
| 173 | Pre-requisite - Security in Docker | Security | CKA 17 |
| 174 | Security Contexts | Security | CKA 17 |
| 175 | Lab - Security Contexts | Security | - |
| 176 | Lab Solution -  Security Contexts | Security | CKA 17 |
| 177 | Network Policy | Security | CKA 18 |
| 178 | Developing network policies | Security | CKA 18 |
| 179 | Lab - Network Policy | Security | - |
| 180 | Lab Solution -  Network Policies (optional) | Security | CKA 18 |
| 181 | Kubectx and Kubens - Command Line Utilities | Security | - |
| 182 | (2025 Updates)Custorm Resource Definition (CRD) | Security | CKA 19 |
| 183 | (2025 Updates) Lab - Custom Resource Definition | Security | - |
| 184 | (2025 Updates) Custom Controllers | Security | CKA 19 |
| 185 | (2025 Updates) Operator Framework | Security | CKA 19 |
| 186 | Storage - Section Introduction | Storage | CKA 20 |
| 187 | Docker Storage - Introduction | Storage | CKA 20 |
| 188 | Storage in Docker | Storage | CKA 20 |
| 189 | Volume Driver Plugins in Docker | Storage | CKA 20 |
| 190 | Container Storage Interface | Storage | CKA 20 |
| 191 | Volumes | Storage | CKA 20 |
| 192 | Persistent Volumes | Storage | CKA 20 |
| 193 | Persistent Volume Claims | Storage | CKA 20 |
| 194 | Using PVCs in Pods | Storage | - |
| 195 | Lab - Persistent Volume Claims | Storage | - |
| 196 | Lab Solution - Persistent Volumes and Persistent Volume Claims | Storage | CKA 20 |
| 197 | Application Configuration | Storage | - |
| 198 | Additional Topics | Storage | - |
| 199 | Storage Class | Storage | CKA 20 |
| 200 | Lab - Storage Class | Storage | - |
| 201 | Lab Solution - Storage Class | Storage | CKA 20 |
| 202 | Networking - Introduction | Networking | CKA 21 |
| 203 | Prerequisite Switching, Routing, Gateways CNI in Kubernetes | Networking | CKA 21 |
| 204 | Prerequisite DNS | Networking | CKA 21 |
| 205 | Prerequisite - CoreDNS | Networking | - |
| 206 | Prerequisite Network Namespaces | Networking | CKA 21 |
| 207 | FAQ | Networking | - |
| 208 | Prerequisite Docker Networking | Networking | CKA 21 |
| 209 | Prerequisite CNI | Networking | CKA 22 |
| 210 | Cluster Networking | Networking | CKA 22 |
| 211 | Important Note about CNI and CKA Exam | Networking | - |
| 212 | Lab - Explore Environment | Networking | - |
| 213 | Lab Solution - Explore Environment (optional) | Networking | CKA 22 |
| 214 | Pod Networking | Networking | CKA 22 |
| 215 | CNI in kubernetes | Networking | CKA 22 |
| 216 | Note CNI Weave | Networking | - |
| 217 | CNI weave | Networking | CKA 22 |
| 218 | Lab - CNI | Networking | - |
| 219 | Lab Solution - Explore CNI (optional) | Networking | CKA 22 |
| 220 | ipam weave | Networking | CKA 22 |
| 221 | Lab - Networking CNIs | Networking | - |
| 222 | Service Networking | Networking | CKA 23 |
| 223 | Lab - Service Networking | Networking | - |
| 224 | Lab Solution - Service Networking (optional) | Networking | CKA 23 |
| 225 | DNS in kubernetes | Networking | CKA 24 |
| 226 | CoreDNS in Kubernetes | Networking | CKA 24 |
| 227 | Lab - CoreDNS in Kubernetes | Networking | - |
| 228 | Lab Solution -  Explore DNS (optional) | Networking | CKA 24 |
| 229 | Ingress | Networking | CKA 25 |
| 230 | Article: Ingress | Networking | - |
| 231 | Ingress - Annotations and rewrite-target | Networking | - |
| 232 | Lab - CKA Ingress Networking - 1 | Networking | - |
| 233 | Lab Solution -  Ingress Networking 1  - (optional) | Networking | CKA 25 |
| 234 | Lab - CKA Ingress Networking - 2 | Networking | - |
| 235 | Lab Solution - Ingress Networking - 2 (optional) | Networking | CKA 25 |
| 236 | Introduction to Gateway API (2025 updates) | Networking | CKA 25 |
| 237 | Practical Guide to Gateway API (2025 Updates) | Networking | - |
| 238 | (2025 Updates) Lab - Gateway API (2025 Updates) | Networking | - |
| 239 | Design a Kubernetes Cluster | Design and Install | CKA 26 |
| 240 | Choosing Kubernetes Infrastructure | Design and Install | CKA 26 |
| 241 | Configure High Availability | Design and Install | CKA 26 |
| 242 | ETCD in HA | Design and Install | CKA 26 |
| 243 | Important Update: Kubernetes the Hard Way | Design and Install | - |
| 244 | Deployment With kubeadm - Introduction | Install kubeadm way | CKA 27 |
| 245 | Resources | Install kubeadm way | - |
| 246 | Deployment With Kubeadm - Provision VMs With Vagrant | Install kubeadm way | CKA 27 |
| 247 | Demo - Deployment with Kubeadm | Install kubeadm way | CKA 27 |
| 248 | Lab - Deploy a Kubernetes Cluster using Kubeadm | Install kubeadm way | - |
| 249 | Lab Solution - Deploy a Kubernetes Cluster using kubeadm : (Optional) | Install kubeadm way | CKA 27 |
| 250 | Helm - Introduction | Helm | CKA 28 |
| 251 | Installation and Configuration | Helm | CKA 28 |
| 252 | Lab: Installing Helm | Helm | - |
| 253 | A Quick Note on Helm2 vs Helm3 | Helm | CKA 28 |
| 254 | Helm Components | Helm | CKA 28 |
| 255 | Helm Charts | Helm | CKA 28 |
| 256 | Working With Helm - Basics | Helm | CKA 28 |
| 257 | Customizing Chart Parameters | Helm | CKA 28 |
| 258 | Lab: Using Helm to Deploy a chart | Helm | - |
| 259 | Lifecycle Management With Helm | Helm | CKA 28 |
| 260 | Lab: Upgrading a Helm Chart | Helm | - |
| 261 | Kustomize Problem Statement and Ideology | Kustomize | CKA 29 |
| 262 | Kustomize vs Helm | Kustomize | CKA 29 |
| 263 | Installation/Setup | Kustomize | CKA 29 |
| 264 | The kustomization.yaml File | Kustomize | CKA 29 |
| 265 | Kustomize Output | Kustomize | CKA 29 |
| 266 | Kustomize ApiVersion & Kind | Kustomize | CKA 29 |
| 267 | Managing Directories | Kustomize | CKA 29 |
| 268 | Managing Directories Demo | Kustomize | CKA 29 |
| 269 | Lab: Managing Directories | Kustomize | - |
| 270 | Common Transformers | Kustomize | CKA 29 |
| 271 | Image Transformers | Kustomize | CKA 29 |
| 272 | Transformers Demo | Kustomize | CKA 29 |
| 273 | Lab: Transformers | Kustomize | - |
| 274 | Patches Intro | Kustomize | CKA 30 |
| 275 | Different Types of Patches | Kustomize | CKA 30 |
| 276 | Patches Dictionary | Kustomize | CKA 30 |
| 277 | Patches List | Kustomize | CKA 30 |
| 278 | Lab: Patches | Kustomize | - |
| 279 | Overlays | Kustomize | CKA 30 |
| 280 | Lab: Overlay | Kustomize | - |
| 281 | Components | Kustomize | CKA 30 |
| 282 | Lab: Components | Kustomize | - |
| 283 | Troubleshooting - Section Introduction | Troubleshooting | CKA 31 |
| 284 | Application Failure | Troubleshooting | CKA 31 |
| 285 | Lab - Application Failure | Troubleshooting | - |
| 286 | Lab Solution - Application Failure : (Optional) | Troubleshooting | CKA 31 |
| 287 | Control Plane Failure | Troubleshooting | CKA 31 |
| 288 | Lab - Control Plane Failure | Troubleshooting | - |
| 289 | Lab Solution - Control Plane Failure : (Optional) | Troubleshooting | CKA 31 |
| 290 | Worker Node Failure | Troubleshooting | CKA 31 |
| 291 | Lab - Worker Node Failure | Troubleshooting | - |
| 292 | Lab Solution - Worker Node Failure : (Optional) | Troubleshooting | CKA 31 |
| 293 | Network Troubleshooting | Troubleshooting | - |
| 294 | Practice Test - Troubleshoot Network | Troubleshooting | - |
| 295 | Lab  - JSON PATH | Troubleshooting | - |
| 296 | Pre-Requisites - JSON PATH | Troubleshooting | - |
| 297 | JSON Path in Kubernetes | Other Topics JSONPath | CKA 32 |
| 298 | Lab - Advanced Kubectl Commands | Other Topics JSONPath | - |
| 299 | Lightning Lab Introduction | Other Topics JSONPath | - |
| 300 | Lightning Lab - 1 | Other Topics JSONPath | - |
| 301 | Mock Exam - 1 | Other Topics JSONPath | - |
| 302 | Solution - Mock Exam -1 (Optional) | Mock Exams | CKA 33 |
| 303 | Mock Exam - 2 | Mock Exams | - |
| 304 | Mock Exam - 2 - Solution : (Optional) | Mock Exams | CKA 33 |
| 305 | Mock Exam - 3 | Mock Exams | - |
| 306 | Mock Exam - 3 - Solution : (Optional) | Mock Exams | CKA 33 |
| 307 | Bonus Lecture | Mock Exams | - |
| 308 | Frequently Asked Questions! | Mock Exams | - |
| 309 | More Certification Tips! | Mock Exams | - |
| 310 | Conclusion | Conclusion | orientation |
| 311 | What's Next? | Conclusion | Capstone |
| 312 | Kubernetes Update and Project Videos - Your Essential Guide | Conclusion | - |
