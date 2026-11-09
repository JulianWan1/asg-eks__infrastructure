# asg-eks-infrastructure

Infrastructure for the URL shortener, split into a shared foundation and two
swappable compute layers. Pick ASG or EKS — one command up, one command down,
no file shuffling.

## Prerequisites

- Terraform ≥ 1.5
- AWS CLI configured (`aws configure`) — region `ap-southeast-1`
- Docker installed (for building and pushing the app image)
- `kubectl` installed (for EKS only)
- `helm` installed (for EKS only — installs the AWS Load Balancer Controller and metrics-server)
- `hey` installed (for EKS load testing only — `brew install hey`)
- Phase 0 complete (S3 state bucket + DynamoDB lock table)

## Directory layout

```
asg-eks-infrastructure/
  Makefile             one-command up/down for each compute layer
  foundation/          VPC, subnets, security groups, RDS, ECR
  asg/                 ALB + Auto Scaling Group (reads foundation state)
  eks/                 EKS cluster + managed node group (reads foundation state)
  eks/k8s/             Kubernetes manifests (Deployment, Service, Ingress, HPA — EKS only)
```

Each directory has its own Terraform state in S3:

| Directory    | State key                      | What it manages                                            |
| ------------ | ------------------------------ | ---------------------------------------------------------- |
| `foundation` | `foundation/terraform.tfstate` | VPC, subnets, IGW, NAT, security groups, RDS, ECR          |
| `asg`        | `asg/terraform.tfstate`        | ALB, target group, listener, launch template, ASG          |
| `eks`        | `eks/terraform.tfstate`        | EKS cluster, managed node group, LBC IAM role, RDS SG rule |

The `asg/` and `eks/` directories read foundation outputs via
`terraform_remote_state`. Foundation must be up before either compute layer
can be applied.

## First-time setup

Initialize each directory once:

```bash
cd foundation && terraform init -upgrade
cd ../asg && terraform init -upgrade
cd ../eks && terraform init -upgrade
```

After this, the Makefile handles everything.

---

## Step 1 — Build and push the Docker image

The ASG user data script and the Kubernetes Deployment both pull from ECR.
If the image isn't there, instances fail health checks and pods crash-loop.

**`make up-asg` and `make up-eks` handle this automatically** — they push
the image after foundation apply and before the compute layer starts. The
manual steps below are for when you need to push outside that flow (e.g.
after updating your app code without rebuilding the cluster).

```bash
# 1. Bring up foundation (creates the ECR repo among other things)
terraform -chdir=foundation apply

# 2. Get the repo URL
ECR_URL=$(terraform -chdir=foundation output -raw ecr_repository_url)

# 3. Authenticate Docker to ECR (token valid 12 hours)
aws ecr get-login-password --region ap-southeast-1 \
  | docker login --username AWS --password-stdin "${ECR_URL}"

# 4. Build the image (run from the project root where the Dockerfile lives)
docker build --platform linux/amd64 -t "${ECR_URL}:latest" .

# 5. Push it
docker push "${ECR_URL}:latest"
```

To verify:

```bash
aws ecr describe-images \
  --repository-name "$(terraform -chdir=foundation output -raw ecr_repository_url | cut -d/ -f2)" \
  --region ap-southeast-1
```

**When to re-push:** any time you `make down-*` and `make up-*` in the same
session, the ECR repo is destroyed and recreated. Push the image again after
foundation comes back up.

---

## Step 2 — Bring up a compute layer

### Option A — ASG (Phase 1)

```bash
make up-asg
```

This runs foundation apply → image push → asg apply. Foundation is a no-op
if already up. Once the ASG instances pass health checks (~2–3 min), the
app is reachable via the ALB:

```bash
# Get the ALB URL
terraform -chdir=asg output -raw alb_dns_name

# Test it
curl -s http://<alb-dns>/healthz
curl -s -X POST http://<alb-dns>/shorten \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com"}'
```

### Option B — EKS (Phase 2)

```bash
make up-eks
```

This runs in sequence: foundation apply → image push → eks apply →
kubeconfig setup → LBC install (Helm) → metrics-server install (Helm) →
deploy (secret, manifests, ingress and HPA). The EKS cluster takes ~15
minutes to provision. Once everything completes, verify:

```bash
kubectl get nodes    # 2 nodes in Ready state
kubectl get pods     # 2 pods in Running state, 1/1 READY
kubectl get ingress  # ADDRESS column filled in (~2 min after deploy)
kubectl get hpa      # TARGETS shows cpu: ~5%/50% (not <unknown>)
```

Test via the public ALB (no port-forward needed):

```bash
ALB=$(kubectl get ingress url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://${ALB}/healthz
curl -s -X POST http://${ALB}/shorten \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com"}'
```

Test with port-forward (direct tunnel to one pod, skips the ALB):

```bash
kubectl port-forward service/url-shortener 3000:80
# in another terminal:
curl -s http://localhost:3000/healthz
```

See the EKS deployment details section below for what each step does.

---

## Switching compute layers

Destroy one, bring up the other. Foundation stays up:

```bash
# EKS → ASG
make down-eks                   # ~15 min (EKS is slow to tear down)
make up-asg                     # ~5 min (foundation already up, just creates ASG)

# ASG → EKS
make down-asg                   # ~3 min
make up-eks                     # ~15 min (foundation already up, just creates EKS)
```

Both can technically run at the same time (they don't conflict), but you'd
be paying for two compute layers for no reason. Destroy one first.

---

## Teardown

```bash
make down-eks     # or make down-asg
```

This destroys the compute layer first, then the foundation. Order matters —
AWS won't let you delete subnets that still have instances in them, so the
Makefile runs the compute destroy before the foundation destroy.

**If you try to destroy foundation first**, it will fail with dependency
errors. No damage — just destroy the compute layer and re-run.

---

## Makefile reference

| Target       | What it does                                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `plan-asg`   | Plan foundation + ASG (foundation must be up already)                                                                            |
| `up-asg`     | Apply foundation → push image → apply ASG                                                                                        |
| `down-asg`   | Destroy ASG → destroy foundation                                                                                                 |
| `plan-eks`   | Plan foundation + EKS (foundation must be up already)                                                                            |
| `up-eks`     | Apply foundation → push image → apply EKS → kubeconfig → install/upgrade LBC → install/upgrade metrics-server → deploy manifests |
| `down-eks`   | Destroy EKS → destroy foundation                                                                                                 |
| `push-image` | Build and push Docker image to ECR (foundation must be up)                                                                       |
| `deploy`     | Label namespace for readiness gates → apply secret + Deployment + Service + Ingress + HPA (EKS must be up, kubectl configured)   |

The `plan-*` targets only work after foundation has been applied at least
once, because the compute layer needs to read foundation's state outputs.
For a cold start, use `up-*` directly — it applies foundation first.

`push-image` and `deploy` are useful standalone when you update your app
code and want to redeploy without recreating the cluster. `deploy` is also
how you apply a manifest change (e.g. a probe setting) — no need to re-run
`up-eks`.

---

## Foundation resources

**What it creates:**

- VPC (10.0.0.0/16) with DNS support
- 2 public subnets (10.0.1.0/24, 10.0.2.0/24) — for ALB / NAT / internet-facing resources
- 2 private subnets (10.0.10.0/24, 10.0.11.0/24) — for compute instances and RDS
- Internet Gateway
- NAT Gateway + Elastic IP (in public subnet AZ-a)
- Public route table (0.0.0.0/0 → IGW) + associations
- Private route table (0.0.0.0/0 → NAT) + associations
- 3 security groups: ALB (ports 80/443 from internet), App (port 3000 from ALB), DB (port 5432 from App)
- RDS PostgreSQL 16 (db.t4g.micro, single-AZ)
- ECR repository (mutable tags, lifecycle policy keeps 5 images)

**Kubernetes subnet tags:** the public and private subnets include
`kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` tags. These
are read by the AWS Load Balancer Controller to know where to place ALBs.
They're harmless when running ASG.

**Keep in mind:**

- The NAT Gateway is the most expensive resource (~$0.045/hr ≈ $32/month).
  Destroy it when not in use.
- RDS takes 5–10 minutes to create and 3–5 minutes to destroy.
- The App and ALB security groups are used only by the ASG path. When
  running EKS, they exist but aren't attached to anything (SGs are free).

---

## ASG resources

**What it creates:**

- IAM role + instance profile (ECR pull + SSM access)
- Launch template (Amazon Linux 2023, t3.micro, user data installs Docker and runs the container)
- Auto Scaling Group (min 2, max 4, across both private subnets)
- Target-tracking scaling policy (40% average CPU)
- Application Load Balancer (in both public subnets)
- Target group (health check on `/readyz`, port 3000)
- HTTP listener (port 80 → target group)

**Keep in mind:**

- The user data script runs on every boot: installs Docker, authenticates to
  ECR, pulls the image, runs the container with `DATABASE_URL` from the
  foundation's RDS.
- The ASG registers instances into the target group automatically. Once
  `/readyz` passes, the ALB starts routing traffic.
- t3.micro instances can spike CPU on boot, which may trigger a brief
  scale-up. This settles on its own.
- The ALB costs ~$0.022/hr (~$16/month). Include it in your teardown
  discipline.

---

## EKS resources

**What it creates:**

- EKS cluster (v1.36, managed control plane)
- Managed node group (t3.small, min 2 / max 4, across both private subnets)
- IAM roles for the control plane and worker nodes (created by the module)
- Security groups for cluster and node communication (created by the module)
- OIDC provider (enables pod-level IAM via IRSA)
- IAM role + policy for the AWS Load Balancer Controller (IRSA)
- RDS security group ingress rule (lets EKS nodes reach Postgres on port 5432)

**Keep in mind:**

- The EKS control plane costs ~$0.10/hr (~$72/month) even with zero pods.
  Destroy when not in use.
- Creating or destroying the cluster takes ~15 minutes each way.
- t3.small nodes provide ~11 pod IP slots each. Kubernetes system pods use
  ~3, leaving ~8 for your workload.
- The cluster uses the community module `terraform-aws-modules/eks/aws`
  (~> 20.0). It wires up ~15 IAM roles and policies behind the scenes.

### EKS deployment details

`make up-eks` handles everything below automatically. This section explains
what it does and how to run each step manually.

#### Step 2a — Cluster and nodes (Terraform)

`terraform -chdir=eks apply` creates the EKS cluster using the community
module (`terraform-aws-modules/eks/aws`). The module provisions the managed
control plane (AWS-hosted, outside your VPC), a managed node group (t3.small
EC2 instances in your private subnets), and ~15 IAM roles, policies, and
security groups for cluster-node communication. A standalone security group
rule lets the EKS nodes reach RDS on port 5432.

It also creates the IAM role for the AWS Load Balancer Controller via IRSA —
the OIDC provider the module sets up is what makes this possible.

The nodes use an EKS-optimized AMI that joins the cluster automatically on
boot — no user data script needed (unlike the ASG path). Nodes don't pull
your app image at boot; they sit idle until Kubernetes schedules pods onto
them.

After the cluster is up, `aws eks update-kubeconfig` writes the cluster
endpoint and auth details to `~/.kube/config` so `kubectl` and `helm` know
where to send commands.

```bash
# Manual equivalent
terraform -chdir=eks apply
aws eks update-kubeconfig \
  --region ap-southeast-1 \
  --name $(terraform -chdir=eks output -raw cluster_name)
kubectl get nodes    # 2 nodes in Ready state
```

#### Step 2b — Deploy the app (Kubernetes manifests)

Three Kubernetes objects, applied via `make deploy`:

**Secret** (`app-secrets`) — stores the `DATABASE_URL` from the foundation's
RDS. Created imperatively (not from a YAML file) so the connection string
never ends up in source control. The `--dry-run=client -o yaml | kubectl
apply` pattern makes it idempotent — works on first run and re-runs.

```bash
# Manual equivalent
kubectl create secret generic app-secrets \
  --from-literal=DATABASE_URL="$(terraform -chdir=foundation output -raw database_url)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Deployment** (`eks/k8s/deployment.yaml`) — declares "I want 2 replicas of
this container, with these health checks and resource limits." Kubernetes
reads this and creates pods on the nodes. Key settings:

- `replicas: 2` — same availability as the ASG's min=2 (once the HPA from
  Step 2d is in place, the HPA owns the replica count)
- `image` — your ECR image URL (injected by `make deploy` via sed, never hardcoded)
- `env.DATABASE_URL` — pulled from the Secret, not hardcoded
- `livenessProbe` → `/healthz` — is the process alive? If this fails,
  Kubernetes restarts the pod
- `readinessProbe` → `/readyz` — can it serve traffic? If this fails, the
  pod is removed from the Service but not killed
- `resources.requests` — tells the scheduler how much CPU/memory each pod
  needs, so it picks a node with room
- `strategy`, `terminationGracePeriodSeconds`, `lifecycle.preStop` — how pods
  are replaced without dropping requests (see Step 2e)

**Service** (`eks/k8s/service.yaml`) — gives the pods a stable internal address.
Pods get new IPs on every restart; the Service provides one fixed name
(`url-shortener`) that always routes to healthy, ready pods. Type is
`ClusterIP` (internal only). Port 80 on the Service maps to port 3000 on
the container.

**Verify and test (port-forward, no ALB needed):**

```bash
kubectl get pods                 # 2 pods, Running, 1/1 READY
kubectl get service              # url-shortener ClusterIP on port 80
kubectl logs <pod-name>          # check app logs if something is wrong

kubectl port-forward service/url-shortener 3000:80
# In another terminal:
curl -s http://localhost:3000/healthz
curl -s -X POST http://localhost:3000/shorten \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com"}'
```

**Troubleshooting:**

- `ImagePullBackOff` — ECR image not pushed. Run `make push-image`.
- `CrashLoopBackOff` — container starts then crashes. Check logs with
  `kubectl logs <pod-name>`. Usually a bad `DATABASE_URL` or RDS not
  reachable.
- `0/1 READY` — readiness probe failing. The pod is running but `/readyz`
  returns an error. Check that RDS is up and the security group rule exists.

#### Step 2c — AWS Load Balancer Controller + public ALB (Helm + Ingress)

Port-forward is useful for testing but not a real public endpoint. Step 2c
adds a proper internet-facing ALB managed by the AWS Load Balancer Controller
(LBC) — a pod running inside the cluster that watches for Ingress objects and
translates them into real AWS resources.

**Why a separate controller?** EKS only speaks Kubernetes. It has no built-in
ability to create AWS ALBs. The LBC is the bridge: it runs as a pod in
`kube-system`, holds an IAM role (via IRSA) scoped to exactly the permissions
it needs, and creates/manages ALBs on behalf of the cluster.

**IAM role (already in `eks/lb-controller.tf`):**

The LBC pod needs permission to call `elasticloadbalancing.*` and `ec2.*` APIs.
IRSA lets a specific Kubernetes ServiceAccount assume an IAM role — no static
credentials, no secrets to rotate. The trust policy locks the role to exactly
`system:serviceaccount:kube-system:aws-load-balancer-controller` — any other
pod is denied even if it has the same service account name in a different
namespace.

**Install the controller (Helm):**

Helm is a package manager for Kubernetes — like apt/npm but for cluster
resources. Instead of applying 8–10 YAML files manually, one `helm install`
renders and applies everything.

```bash
helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

CLUSTER_NAME=$(terraform -chdir=eks output -raw cluster_name)
LBC_ROLE_ARN=$(terraform -chdir=eks output -raw lbc_role_arn)

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${LBC_ROLE_ARN}"

# Verify — 2/2 READY after ~30 seconds
kubectl get deployment -n kube-system aws-load-balancer-controller
```

`helm upgrade --install` installs the release if it's missing and upgrades
it if it already exists — so re-running `make up-eks` on a live cluster
doesn't fail with "release already exists".

Helm uses the same `~/.kube/config` as kubectl to find the cluster. The
`--set clusterName` value is passed to the controller pod itself (for AWS
resource tagging), not used by Helm for routing.

**Apply the Ingress (`eks/k8s/ingress.yaml`):**

```bash
kubectl apply -f eks/k8s/ingress.yaml
```

The LBC sees the new Ingress object, calls the AWS API, and creates:

- An internet-facing ALB in the public subnets
- A target group pointing directly at pod IPs (`target-type: ip`)
- An HTTP listener on port 80

The ALB's DNS name is written back into the Ingress status. Retrieve it:

```bash
kubectl get ingress url-shortener --watch   # wait for ADDRESS to appear (~2 min)

ALB=$(kubectl get ingress url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://${ALB}/healthz
curl -s -X POST http://${ALB}/shorten \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com"}'
```

**`make up-eks` handles all of this automatically** — the Helm install is
baked into the target so a cold start produces a working public ALB with one
command.

**Troubleshooting:**

- `ADDRESS` never appears — check the LBC pod logs:
  `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`
  Common causes: IAM trust policy mismatch, missing subnet tags, LBC not ready.
- `2/2` not reached for the LBC deployment — the IRSA annotation or IAM role
  ARN may be wrong. Re-check `lbc_role_arn` output and the Helm install command.

#### Step 2d — Autoscaling with metrics-server + HPA

Up to now the pod count was fixed at 2. Step 2d makes it react to load:
pods scale between 2 and 6 based on CPU. The ASG also had a min and max,
but the difference is what moves the count — the HPA adds and removes pods
in response to the actual workload signal, within those bounds.

**The two pieces:**

- **metrics-server** (Helm, in `kube-system`) — collects CPU and memory
  usage from the kubelet on each node and makes it available through the
  Kubernetes API. It only answers questions; it never pushes or scales
  anything. On EKS it needs `--kubelet-insecure-tls` because kubelets use
  self-signed certificates.
- **HorizontalPodAutoscaler** (`eks/k8s/hpa.yaml`) — built into Kubernetes,
  so no extra controller is needed (unlike Ingress, which needed the LBC).
  About every 15 seconds it asks metrics-server for the pods' average CPU
  and adjusts the Deployment's replica count.

As with the LBC, nothing talks directly to anything else — metrics-server
and the HPA both go through the API server.

```yaml
# eks/k8s/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: url-shortener
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: url-shortener
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

**Install (manual equivalent of what `make up-eks` / `make deploy` do):**

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ || true
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set args[0]="--kubelet-insecure-tls"
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

kubectl apply -f eks/k8s/hpa.yaml

# Verify
kubectl top pods     # CPU/memory per pod (metrics-server works)
kubectl get hpa      # TARGETS shows cpu: ~5%/50% (not <unknown>)
```

**Deployment settings that matter for 2d:**

```yaml
resources:
  requests:
    cpu: "100m" # reserved per pod — and HPA's ruler (100m = 100%)
  limits:
    cpu: "250m" # hard cap per pod (¼ of one core)

livenessProbe:
  timeoutSeconds: 5 # tolerate a busy event loop without restarting the pod
readinessProbe:
  timeoutSeconds: 5 # tolerate a busy event loop without leaving the ALB
  failureThreshold: 3 # ~30s of failures before NotReady
```

Both probe timeouts default to **1 second**. Under load that was too short —
see "What went wrong along the way" below for how that caused 797 errors.

To apply a manifest change like this, `make deploy` is enough (it triggers a
rolling update). Check it landed:

```bash
kubectl get deploy url-shortener -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'
```

**Keep in mind:** `deployment.yaml` still sets `replicas: 2`. If the HPA has
scaled to, say, 6 and you run `make deploy`, the apply resets the count to 2
for a moment before the HPA scales back up. Harmless here, but in production
you'd remove `replicas` from the manifest once an HPA owns the count.

##### How the numbers work

**The three CPU numbers** (1000m = one full CPU core; a node usually has more
than one core):

| Setting        | Value     | What it means                                                                         |
| -------------- | --------- | ------------------------------------------------------------------------------------- |
| `limits.cpu`   | 250m      | The most a pod can ever use. Above this, Kubernetes throttles it.                     |
| `requests.cpu` | 100m      | What's reserved for the pod. Also HPA's ruler: an average of 100m reads as 100%.      |
| HPA target     | 50% → 50m | The average per pod HPA aims for. Above it, HPA scales up; below it, HPA scales down. |

A pod can use anything between 100m and 250m if the node has spare CPU — the
reservation is a floor, not a cap.

**One call to `/work?ms=400` maxes out the pod for 0.4 seconds.** The loop
never pauses (no database, no network, no timers), so it would take a whole
core if allowed. The 250m limit holds it to 250m. And the loop stops on the
clock, not when work is done, so it always lasts 0.4s. Afterwards the pod
drops to near zero until the next call. Evidence: busy pods showed 245–251%
in `kubectl get hpa`, i.e. right at the 250m limit.

Think of it as speed, time and distance:

|          | Analogy                 | Value                                         |
| -------- | ----------------------- | --------------------------------------------- |
| Speed    | how hard the pod works  | 250m                                          |
| Time     | how long one call lasts | 0.4s                                          |
| Distance | work done per call      | 250m × 0.4s = **100 m·s** (millicore-seconds) |

**From hey to calls per pod.** hey sets the total rate: workers × calls per
second per worker. The ALB spreads that evenly over the pods:

```
total calls/sec        = -c (workers) × -q (calls/sec per worker)
calls/sec per pod      = total calls/sec ÷ number of pods
```

**From calls per pod to the CPU HPA sees.** Each call per second adds
100 m·s of work every second, i.e. 100m to the pod's average CPU:

```
average CPU per pod = 100 m·s × calls/sec per pod
```

- **2.5 calls/sec per pod** → 2.5 × 100 = **250m** average. Way above the 50m
  target → HPA scales up. This is also the most a pod can do: 1s ÷ 0.4s = 2.5
  calls, or 250 m·s available ÷ 100 m·s per call = 2.5.
- **0.5 calls/sec per pod** → 0.5 × 100 = **50m** average. On target → HPA
  keeps the current pod count (2 at idle, since that's the minimum).
- **1 call/sec per pod** → 100m → reads as 100% in HPA.

Note that the two "100"s are a coincidence of the current settings: 100 m·s
per call comes from `ms=400` × the 250m limit, while 100m `requests.cpu` comes
from deployment.yaml. Change the call to `ms=200` and the cost per call halves
while the ruler stays 100m.

**Quick reference for this setup:**

|                     | Value                                                                  |
| ------------------- | ---------------------------------------------------------------------- |
| Max per pod         | 2.5 calls/sec (= 250m, pod never idle)                                 |
| HPA reading         | 1 call/sec per pod = 100%                                              |
| HPA adds pods above | ~0.5 calls/sec per pod (50%, plus HPA's built-in 10% tolerance → ~55%) |
| Pods HPA wants      | total calls/sec ÷ 0.5, clamped to 2–6                                  |
| 2 pods (min)        | at target at 1 call/sec total; full at 5 calls/sec                     |
| 6 pods (max)        | at target at 3 calls/sec total; full at 15 calls/sec                   |

**The 15-second window.** HPA checks about every 15 seconds and sees an
average, never individual call spikes. For steady load the window doesn't
matter — a steady pattern averages to the same number over 1 second or 15.
It matters when load changes:

- **Scale-up lag** = time for HPA to notice + time for new pods to start and
  pass health checks. Measured here: 2 → 6 pods in ~30–45 seconds.
- **Short bursts are diluted** — a 3-second burst inside a 15-second window
  may never cross 50m. Mostly intentional.

**What happens during the lag — the queue.** A pod serves one call at a
time. Calls that arrive while it's busy wait in line, so a call that needs
0.4s of work can take longer end to end:

```
total time per call = work (0.4s) + network (~0.03s) + waiting in line
```

| Calls arriving per pod           | Waiting                                      |
| -------------------------------- | -------------------------------------------- |
| well under 2.5/sec (20–60% busy) | rare and short                               |
| close to 2.5/sec (~90% busy)     | common, a few tenths of a second             |
| over 2.5/sec                     | the line grows every second and never clears |

Like a sink: the tap is calls arriving, the drain is 2.5 calls/sec per pod.
The HPA's job is to add drains before it overflows. During the lag, calls get
**slower**, not failed — they only fail if the wait exceeds a timeout (hey
gives up at 20s, the ALB at 60s) or if pods get so backed up they fail their
health checks.

**Why the target is 50%, not 100%.** The gap between the 50m target and the
250m limit is headroom: 2 pods at target handle 1 call/sec but can absorb up
to 5 calls/sec before queueing. That 5× buffer is what carries traffic
through the scale-up lag. To reduce lag risk further, teams raise
`minReplicas`, lower the target, make pods start faster, or scale ahead of
predictable peaks.

##### Load testing with hey

**Flags used:**

| Flag      | Meaning                                                           |
| --------- | ----------------------------------------------------------------- |
| `-z 180s` | run for this long                                                 |
| `-c 3`    | number of workers (concurrent callers)                            |
| `-q 1`    | calls per second **per worker** — not the total                   |
| `-o csv`  | optional: write every call (start offset, latency, status) to CSV |

Total rate = `-c` × `-q`. hey is **closed-loop**: each worker waits for its
response before sending the next call. If the server slows down, hey slows
down with it. Two consequences:

- Give it enough workers: workers needed ≥ rate × latency (Little's Law). With
  `-q 1`, each worker can tolerate up to 1s of latency before falling behind.
  More workers each sending more slowly hold a rate better than fewer workers
  sending faster.
- Always check **Requests/sec** in the summary — it's the rate actually
  delivered, which can be lower than what you asked for.

**Reading the output:** the response time histogram has one row per bucket
(upper bound, count). A healthy run is a tall first bucket and a quick
drop-off; a long, fat tail means calls were waiting in line. The status code
distribution tells you whether failures came from the pods or elsewhere — a
503 that returns in ~60ms never reached a pod (the ALB answered itself).

**Setup (every session):**

```bash
# 1. Set the ALB address IN THE TERMINAL THAT WILL RUN hey.
#    Shell variables don't carry between terminals, and the ALB address
#    changes every time the cluster is rebuilt.
ALB=$(kubectl get ingress url-shortener -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB
curl -s "http://$ALB/healthz"          # expect {"status":"ok"}

# 2. Watch terminals
kubectl get hpa -w
kubectl get pods -w
kubectl get endpoints url-shortener -w  # pod IPs the Service/ALB route to
while true; do kubectl top pods; sleep 5; done   # optional: CPU per pod

# 3. Start from baseline: 2 pods, cpu ~5%/50%
kubectl get hpa
```

**Test 1 — Clean scale-up, 2 → 6 pods (3 calls/sec)**

Goal: show HPA scaling without the lag causing slowdowns or failures. Pick a
load inside the safe window — above HPA's trigger for 2 pods (~1.1 calls/sec)
but below what 2 pods can absorb on their own while new pods start (5
calls/sec). 3 calls/sec gives each starting pod 1.5 calls/sec (150m, 60%
busy), and HPA wants 3 ÷ 0.5 = 6 pods.

```bash
kubectl patch hpa url-shortener -p '{"spec":{"minReplicas":2,"maxReplicas":6}}'   # normal settings
hey -z 180s -c 3 -q 1 "http://$ALB/work?ms=400"
```

Results:

|                      | Predicted | Actual                                 |
| -------------------- | --------- | -------------------------------------- |
| Requests/sec         | 3         | 2.99                                   |
| HPA early (2 pods)   | ~150%     | 119–180%                               |
| Pods                 | 2 → 6     | 2 → 4 → 6 within ~30–45s               |
| HPA settled (6 pods) | ~50%      | 60–67%                                 |
| Latency              | ~0.4–0.5s | median 0.54s, p99 1.06s, slowest 1.44s |
| Status               | all 200   | 537 × 200, 3 × 502                     |

- **Settled at ~63% instead of 50%** — the model only counts `/work` calls.
  Idle pods already sit at 4–6% (health probes, Node runtime, per-request
  HTTP handling). That everyday overhead sits on top of the 50% from calls.
  HPA wanted more than 6 pods but 6 is the max.
- **Tail up to 1.44s** — with 3 workers, at most 3 calls are in flight.
  Occasionally all 3 land on the same pod: the third waits 0.8s for the
  other two, then runs 0.4s → ~1.2–1.4s. Ordinary bunching, bounded, no
  backlog.
- **3 × 502 (0.6%)** — unrelated to scaling; see open items.

**Test 2 — Capacity of 6 pods (14 calls/sec, pod count locked)**

Goal: check the per-pod capacity without the scale-up lag muddying the
result. Lock the pod count at 6 first:

```bash
kubectl patch hpa url-shortener -p '{"spec":{"minReplicas":6}}'
kubectl get pods        # wait for 6 pods at 1/1 Running, then ~30s for ALB health checks

hey -z 60s -c 14 -q 1 "http://$ALB/work?ms=400"

kubectl patch hpa url-shortener -p '{"spec":{"minReplicas":2}}'   # revert
```

14 calls/sec ÷ 6 pods = 2.33 calls/sec per pod — just under the 2.5 ceiling
(~93% busy). Predicted HPA reading 233%.

|              | Result                                                         |
| ------------ | -------------------------------------------------------------- |
| Requests/sec | 13.70                                                          |
| Status       | 835 × 200, no errors                                           |
| Endpoints    | stayed at 6 throughout                                         |
| HPA          | ~240% per pod (≈ 240m, right at the limit)                     |
| Latency      | average 0.83s, p99 1.35s, slowest 1.55s — bounded, not growing |

6 pods hold 14 calls/sec. The ~0.4s average wait is the cost of running
pods at ~93% busy: calls often arrive while another is still running. The
over-capacity counterpart (20 calls/sec, expected to plateau at ~15) wasn't
run.

**What Step 2d proved:**

- Each pod handles ~2.5 calls/sec; each call per second adds ~100m to a pod's
  average CPU.
- HPA scales 2 → 6 in ~30–45 seconds when load arrives.
- Load inside the safe window (3 calls/sec) scales up with no slowdown and no
  failures.
- 6 pods hold 14 calls/sec with zero errors.

##### What went wrong along the way (and the fixes)

1. **Uncontrolled shell loop.** The first test fired `curl ... &` in a
   `while true` loop with no rate control. HPA scaled to 6 and nothing
   failed, but only because the loop stopped before the backlog caused
   timeouts. It proved HPA scales; it couldn't say anything about capacity.
   Fix: use hey with an explicit rate.

2. **797 × 503 from readiness probes.** At 20 calls/sec on 2 pods, each
   pod's event loop was blocked by ~2s of queued `/work` calls. The
   readiness probe (1s default timeout) waited in the same queue, timed out,
   and the pods were marked NotReady. The LBC removed their IPs from the ALB
   target group; with both pods removed the target group was empty and the
   ALB answered 503 itself in ~60ms (that's why half the responses were
   impossibly fast for a 400ms call). Removing one busy pod also pushes its
   traffic onto the others, so it cascades. Fix: readiness `timeoutSeconds: 5`
   and `failureThreshold: 3` → 503s went from 797 to 0. The proper fix is
   moving `/work` off the event loop (see open items).

3. **`-q` is per worker.** `hey -q 20 -c 10` allowed up to 200 calls/sec,
   not 20. The 19.4 calls/sec measured came from 10 workers ÷ 0.506s average
   latency — the workers were the limit, not `-q`.

4. **Mixing scale-up lag with capacity.** A run starting at 2 pods with 20
   workers delivered only 6.2 calls/sec: for much of the run only 2 pods (5
   calls/sec capacity) were up, latency climbed to ~3s, and closed-loop hey
   slowed down with it. It mostly measured how slowly HPA reacts. Fix:
   separate tests — one for scale-up (Test 1), one with the pod count locked
   for capacity (Test 2).

5. **Stale `$ALB`.** After a cluster rebuild, a terminal still held the old
   ALB address: 840 × "no such host", CPU never moved. Fix: re-set `ALB` in
   the terminal running hey and `echo` it before each run.

##### Open items

- **Occasional 502s (~0.5%)** — likely candidate: Node's keep-alive timeout
  (5s default) is shorter than the ALB's idle timeout (60s), so the ALB
  occasionally reuses a connection Node has just closed. Unconfirmed.
- **`/work` blocks the event loop.** The probe timeouts are a band-aid. The
  proper fix is running the burn in a `worker_thread` (with a fixed-size pool
  to cap memory). Note that this changes what the load test measures: the
  loop stops on wall-clock time, so with threads a pod would no longer have
  a 2.5 calls/sec ceiling. Pair it with a fixed-amount-of-work burn so CPU
  throttling shows up as latency.
- **Optional measurements:** 20 calls/sec with 6 pods locked (to confirm the
  ~15 calls/sec ceiling), and a scale-up run with `hey -o csv` to chart
  latency over time against pod count.

#### Step 2e — Zero-downtime rolling deploys (preStop + readiness gate)

**Goal:** replacing pods (a deploy, `kubectl rollout restart`, an HPA
scale-down) must not cause a single failed request.

**Why it fails without this.** Kubernetes and the ALB don't coordinate.
There are two timing gaps:

|                    | The gap                                                                                                                      | What users see                                                     |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **Stopping** a pod | SIGTERM arrives immediately; the app stops accepting connections while the ALB is still sending to it for a few more seconds | 502s (refused), 504s (ALB waits 10s for a pod that's already gone) |
| **Starting** a pod | Kubernetes counts a new pod Ready as soon as `/readyz` passes, before the ALB has health-checked it, and removes an old pod  | fewer (possibly zero) healthy targets behind the ALB for a moment  |

**How a pod gets terminated.** Something sends a delete request (a rollout,
an HPA scale-down, `kubectl delete pod`, a node drain). The API server
doesn't delete the pod; it writes `deletionTimestamp` onto the pod's record,
which is what "Terminating" means. Every component watching sees that and
does its own job at the same time:

- the endpoint controller removes the pod from the Service's list
- the LBC sees it leave → tells AWS to deregister the pod IP → the ALB marks
  it **draining** and stops sending new calls
- the kubelet on the pod's node runs preStop, then sends SIGTERM

The ALB knows nothing about Kubernetes — the **LBC is the messenger** in both
directions.

**Three different things can happen to a pod** — only the last one is 2e:

| Trigger                     | Result                                                        | Pod deleted? |
| --------------------------- | ------------------------------------------------------------- | ------------ |
| `/healthz` (liveness) fails | kubelet restarts the container                                | No           |
| `/readyz` (readiness) fails | pod taken out of the Service / ALB, added back when it passes | No           |
| delete request              | Terminating → preStop → SIGTERM → exit → gone                 | Yes          |

`/healthz` stays 200 during shutdown on purpose, so liveness never restarts
a pod that is draining.

**The fixes:**

- **Stopping — a race with a head start.** A `preStop` pause of 15s keeps the
  pod serving normally while the LBC and ALB catch up; only then does SIGTERM
  arrive. The kubelet and the LBC don't talk to each other — 15s is a safety
  margin over how long the LBC needs, not a calculated value.
- **Starting — a handshake.** A readiness gate adds a second item to the pod's
  Ready checklist that only the LBC can tick, once the ALB reports the pod
  healthy. Combined with `maxUnavailable: 0`, an old pod is only removed after
  its replacement is actually receiving traffic.

SIGTERM's job is to make the app stop accepting connections, finish in-flight
requests, close the DB pool and exit (`server.ts`). `/readyz` switching to 503
is a side effect — by then the ALB has already stopped sending.

**Changes:**

`eks/k8s/deployment.yaml`:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1 # start 1 new pod before removing an old one
      maxUnavailable: 0 # never fewer ready pods than the normal count
  template:
    spec:
      terminationGracePeriodSeconds: 45 # total budget, includes the preStop pause
      containers:
        - name: url-shortener
          lifecycle:
            preStop:
              sleep:
                seconds: 15 # built-in sleep action (no sleep binary needed)
```

Setting the strategy explicitly matters with the HPA: the default is 25%,
which rounds to `maxUnavailable: 0` at 2 pods but to 1 at 6 pods.

`eks/k8s/ingress.yaml` (annotations):

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /readyz
alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
```

The health check path is required: the LBC defaults to `/`, which this app
answers with 404 — the ALB would never mark pods healthy and the readiness
gate would block every rollout. The default deregistration delay is 300s;
30s still covers pause + drain (25s).

`Makefile` — first line of `deploy` (gates are only added to pods created
after the label exists):

```makefile
deploy:
	kubectl label namespace default elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite
	...
```

No app code changes — `server.ts` already shuts down gracefully.

**Timeline of one old pod, and the limits behind it:**

```
t=0s     Terminating → preStop starts; pod still serving
t≈1–2s   ALB marks it draining → no new calls
t≈2–3s   last in-flight calls finish → pod idle for the rest of the pause
t=15s    SIGTERM → nothing left to finish → app exits (~15–16s total)
```

| Limit                             | Value             | Covers                                                          |
| --------------------------------- | ----------------- | --------------------------------------------------------------- |
| preStop pause                     | 15s               | time for the ALB to stop sending                                |
| App drain (`SHUTDOWN_TIMEOUT_MS`) | 10s after SIGTERM | app forces its own exit if a request hangs                      |
| ALB deregistration delay          | 30s               | ≥ 15 + 10, so the ALB never cuts a request the app is finishing |
| `terminationGracePeriodSeconds`   | 45s               | Kubernetes SIGKILLs only if the app is still running            |

The extra time per rollout is about 15s total, not 15s per pod: each old
pod's pause overlaps with the next new pod starting, and HPA scale-downs
delete pods in parallel.

**Verify after `make deploy`:**

```bash
kubectl rollout status deployment/url-shortener
kubectl get pods -o wide        # READINESS GATES column shows 1/1
kubectl get deploy url-shortener -o jsonpath='{.spec.template.spec.containers[0].lifecycle}'
```

**Test — rollout under steady traffic:**

```bash
# Terminal 1
kubectl get pods -o wide -w | while read line; do echo "$(date +%T) $line"; done

# Terminal 2 (re-set $ALB in this terminal first): 50 calls/sec for 2 minutes
hey -z 120s -c 10 -q 5 "http://$ALB/healthz"

# Terminal 3, ~10s after hey starts
kubectl rollout restart deployment/url-shortener
kubectl rollout status deployment/url-shortener
```

Optional — watch the ALB's view of each pod IP (`initial` → `healthy` →
`draining` → gone):

```bash
export AWS_PAGER=""      # otherwise the CLI opens a pager and the loop stalls
TG_ARN=$(kubectl get targetgroupbinding -o jsonpath='{.items[0].spec.targetGroupARN}')
while true; do
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' --output text \
    | sed "s/^/$(date +%T) /"
  echo ---; sleep 1
done
```

**Results:**

|                                 | Before         | After                             |
| ------------------------------- | -------------- | --------------------------------- |
| 200                             | 4,857          | 5,745 (and 5,867 on a second run) |
| 502                             | 22             | 0                                 |
| 504                             | 15             | 0                                 |
| Slowest request                 | 10.1s          | 1.4s                              |
| Requests/sec (50 sent)          | 40.75          | 47.85                             |
| Old pod Terminating → Completed | almost instant | ~15–16s                           |

- **Before:** the 504s all took ~10.1s — the ALB's connect timeout to a pod
  IP that had already exited. Old pods started terminating the moment their
  replacement showed `1/1`.
- **After, stopping side:** the old pod's IP showed `draining` within ~1–2s
  of `Terminating` (one measurement), well inside the 15s pause. 15s is kept
  anyway: the LBC can be slower under load, and ALB nodes take a little time
  to apply a change after the API reports it.
- **After, starting side:** new pod container ready at 00:05:16, ALB `healthy`
  at 00:05:20, readiness gate `1/1` at 00:05:32, and the old pod went
  Terminating in that same second. The LBC checks target health
  periodically, so the gate ticks a few seconds after the ALB — on the safe
  side, it only slows each rollout step slightly.

#### Remaining EKS steps

None — Phase 2 (EKS) steps 2a–2e are complete. See the Step 2d open items
for optional follow-ups.

---

## Cost awareness

Always-on charges when the stack is running:

| Resource          | Hourly             | Monthly (24/7) | Notes                                   |
| ----------------- | ------------------ | -------------- | --------------------------------------- |
| NAT Gateway       | ~$0.045            | ~$32           | Foundation — always on when stack is up |
| RDS db.t4g.micro  | free tier eligible | —              | Foundation — check your account         |
| ALB               | ~$0.022            | ~$16           | ASG path and EKS path (LBC-managed)     |
| t3.micro × 2      | free tier eligible | —              | ASG path only                           |
| EKS control plane | ~$0.10             | ~$72           | EKS path only                           |
| t3.small × 2      | ~$0.026 each       | ~$38 total     | EKS path only                           |

**Bottom line:** destroy everything at the end of each session. The Makefile
targets handle the correct teardown order.
