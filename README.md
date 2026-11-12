# StreamingApp on Amazon EKS - Orchestration and Scaling

This repo is my fork of [UnpredictablePrashant/StreamingApp](https://github.com/UnpredictablePrashant/StreamingApp) (MERN microservices: React frontend + auth, streaming, admin and chat services + MongoDB). I containerised it, built a Jenkins CI/CD pipeline that pushes images to Amazon ECR, and deployed it on Amazon EKS with Helm, with CloudWatch monitoring and SNS notifications.

Everything runs in AWS account **099739121791**, region **ap-south-1 (Mumbai)**.

> All AWS resources were deleted after testing to avoid charges. The screenshots below were taken while the setup was running.
> The original application README is in [docs/APP_README.md](docs/APP_README.md).

---

## Architecture

![Architecture](docs/architecture.png)

Diagram source: [docs/architecture.drawio](docs/architecture.drawio)

**Request flow**

1. The user opens the load balancer URL. The `frontend` Service is `type: LoadBalancer`, so EKS creates an AWS load balancer in the public subnets.
2. The frontend pod runs nginx. It serves the React build and works as the gateway for the backends:

   | Path | Goes to |
   |---|---|
   | `/api/streaming/*` | streaming :3002 |
   | `/api/admin/*` | admin :3003 |
   | `/api/chat/*`, `/socket.io/*` (websocket) | chat :3004 |
   | `/api/*` (everything else) | auth :3001 |
   | `/` | React app |

   Because of this the React app is built with **relative URLs** (`/api`, `/api/admin` ...), so the same image works on any domain or load balancer without rebuilding.
3. All backends use MongoDB (StatefulSet with an encrypted EBS gp3 volume).
4. Streaming and admin read and write videos in a private S3 bucket. They get AWS credentials through **EKS Pod Identity** - there are no access keys anywhere.

**CI/CD flow**

Developer pushes to GitHub → Jenkins notices the commit (polls every 2 min) → builds 5 images → pushes to ECR (tag = git commit) → `helm upgrade --install` on EKS → SNS email with the result.

---

## Repository changes

```
backend/*/Dockerfile          multi-stage builds, Node 20, npm ci --omit=dev, non-root user
backend/*/.dockerignore
backend/*/db.js, util/conn.js  stop printing the MongoDB password in logs
frontend/Dockerfile           relative API URLs, nginx-unprivileged (non-root, port 8080)
frontend/nginx/default.conf.template   gateway config (routes /api/* to the services)
helm/streamingapp/            Helm chart for the whole stack
infra/eksctl/cluster.yaml     EKS cluster definition
infra/k8s/cluster-setup.yaml  namespace + gp3 StorageClass (cluster-wide, applied once)
jenkins/                      Jenkins image, plugins, Configuration as Code, EC2 user data
Jenkinsfile                   CI/CD pipeline
docs/                         architecture diagram, screenshots, original README
```

---

## Step 1 - Version control

- Forked the main repo to `rajeshnegd939/StreamingApp`.
- The original repo is added as `upstream`, so updates can be pulled any time:

```bash
git remote add upstream https://github.com/UnpredictablePrashant/StreamingApp.git
git fetch upstream
git merge upstream/main      # then push to my fork
```

![Git remotes](docs/screenshots/01-git-remotes-upstream-sync.png)

## Step 2 - Containerise and push to ECR

The repo already had basic Dockerfiles. I changed them to:

| Change | Why |
|---|---|
| Multi-stage build (deps stage with python3/make/g++, then a clean runtime stage) | `bcrypt` in the auth service needs build tools, but they should not be in the final image |
| `npm ci --omit=dev` | exact versions from package-lock, no `nodemon` in production |
| `node:20-alpine` instead of 18 | Node 18 is end of life |
| `USER node`, `/app` owned by node | containers do not run as root |
| Each service builds from its own folder | the services do not share code, so a smaller build context |
| Frontend on `nginxinc/nginx-unprivileged` + gateway config | non-root nginx, React routes work on refresh, one entry point for all APIs |

Five ECR repositories were created with **scan on push**, AES256 encryption and a lifecycle rule that keeps the last 10 images:
`streamingapp/frontend`, `auth-service`, `streaming-service`, `admin-service`, `chat-service`.

![ECR](docs/screenshots/02-ecr-repositories.png)

## Step 3 - AWS CLI

AWS CLI v2 configured for account 099739121791 and region ap-south-1. The Jenkinsfile also checks the account ID before doing anything, so a wrong account stops the build.

## Step 4 - CI with Jenkins

### Jenkins server

- EC2 **t3.medium**, Amazon Linux 2023, in the default VPC.
- [jenkins/ec2-user-data.sh](jenkins/ec2-user-data.sh) installs Docker, clones this repo, builds the Jenkins image from [jenkins/Dockerfile](jenkins/Dockerfile) and starts it.
- The Jenkins image contains docker CLI, AWS CLI, kubectl and helm. Builds use the host Docker daemon through the mounted socket.
- **Plugins** ([plugins.txt](jenkins/plugins.txt)) are installed at image build time.
- **Configuration as Code** ([casc.yaml](jenkins/casc.yaml)) creates the admin user and the `streamingapp-ci-cd` pipeline job, so nothing is clicked in the UI.
- The admin password is stored as a **SecureString in SSM Parameter Store** and read at boot.
- **No AWS keys in Jenkins.** The EC2 instance role `streamingapp-jenkins-role` has ECR push, `eks:DescribeCluster` on this cluster, `ssm:GetParameter` on the Jenkins parameter and `sns:Publish` on the deployments topic. IMDSv2 hop limit is 2 so the Jenkins container can use the role.
- The role has an **EKS access entry with `AmazonEKSAdminPolicy` scoped to the `streamingapp` namespace only**. Jenkins can deploy the app but cannot touch the rest of the cluster.
- Security group: port 8080 only from my IP, no SSH port (Session Manager can be used instead).

![Jenkins IAM and EKS access](docs/screenshots/15-jenkins-iam-eks-access.png)

### Pipeline ([Jenkinsfile](Jenkinsfile))

| Stage | What it does |
|---|---|
| Checkout | gets the commit, image tag = short commit id |
| Check AWS account | fails if the account is not 099739121791 |
| Login to ECR | `aws ecr get-login-password` |
| Build and push images | 5 images, tagged with the commit and `latest` |
| Deploy to EKS (Helm) | `helm lint`, `helm upgrade --install --wait`, then shows the deployed objects |
| post | SNS email for success or failure, prune old images |

**Automatic trigger:** the job polls GitHub every 2 minutes (`pollSCM`) and also accepts the GitHub webhook trigger. Build #2, #3 and #4 were started by commits ("Started by an SCM change").

![Jenkins dashboard](docs/screenshots/20-jenkins-dashboard.png)
![Pipeline stage view](docs/screenshots/21-jenkins-pipeline-job.png)
![Build 4](docs/screenshots/22-jenkins-build-4.png)
![Build 4 console - started by SCM change](docs/screenshots/23-jenkins-build-4-console.png)
![Build 4 - deploy stage](docs/screenshots/25-jenkins-build-4-deploy-stage.png)
![Build 2 - SCM trigger](docs/screenshots/24-jenkins-build-2-scm-trigger.png)

## Step 5 - Kubernetes on EKS with Helm

### Cluster ([infra/eksctl/cluster.yaml](infra/eksctl/cluster.yaml))

```bash
eksctl create cluster -f infra/eksctl/cluster.yaml
kubectl apply -f infra/k8s/cluster-setup.yaml
```

- New VPC `10.20.0.0/16`, 2 AZs, one NAT gateway
- Managed node group: 2-3 x t3.medium in **private subnets** (no public IPs)
- Add-ons: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, **metrics-server** (for HPA), **aws-ebs-csi-driver** (MongoDB disk), **amazon-cloudwatch-observability** (Container Insights)
- Control plane logs (api, audit, authenticator) to CloudWatch, 7 days

![EKS cluster](docs/screenshots/10-eks-cluster.png)

### Helm chart ([helm/streamingapp](helm/streamingapp))

| Template | Creates |
|---|---|
| `secret.yaml` | MongoDB root + app passwords and JWT secret. Random on first install, kept the same on upgrades (`lookup`) |
| `mongodb.yaml` | headless Service + StatefulSet + 5Gi gp3 PVC; an init script creates an app user with `readWrite` on the `streamingapp` database only |
| `backend.yaml` | Deployment + Service for auth, streaming, admin, chat (loop over `values.yaml`), readiness/liveness probes, resource limits, non-root |
| `frontend.yaml` | nginx gateway Deployment + `LoadBalancer` Service |
| `hpa.yaml` | HorizontalPodAutoscalers: frontend 2-3, auth 1-3, streaming 2-4 (CPU 70%) |
| `serviceaccount.yaml` | `streamingapp-s3` service account, linked to an IAM role through Pod Identity |

The public URL is not hard-coded: the chart reads the load balancer hostname from the frontend Service (`lookup`) and passes it to the backends (`CLIENT_URLS`, `STREAMING_PUBLIC_URL`).

S3 access: IAM role `streamingapp-s3-pod-role` (Get/Put/Delete on `streamingapp-media-099739121791/*`, List on the bucket) + Pod Identity association for `streamingapp/streamingapp-s3`.

![Helm release](docs/screenshots/13-helm-release.png)
![Workloads](docs/screenshots/11-k8s-workloads.png)
![Pods](docs/screenshots/12-k8s-pods.png)
![Pod Identity and S3](docs/screenshots/14-pod-identity-s3.png)

### Scaling test

A busybox pod sent requests to the streaming service in 8 parallel loops. CPU went to ~265% of the request, and the HPA scaled streaming from **2 to 4 pods**:

![HPA scale out](docs/screenshots/16-hpa-scale-out.png)

## Step 6 - Monitoring and logging

- **Container Insights** (CloudWatch observability add-on) collects node, pod and namespace metrics.
- **Fluent Bit** (part of the same add-on) sends all container logs to `/aws/containerinsights/streamingapp-eks/application`. Control plane logs go to `/aws/eks/streamingapp-eks/cluster`.
- **Alarms** to SNS topic `streamingapp-alerts` (email):

| Alarm | Condition |
|---|---|
| `streamingapp-node-cpu-high` | node CPU > 80% for 10 min |
| `streamingapp-pods-down` | fewer than 7 running pods in `streamingapp` for 3 min |
| `streamingapp-node-failed` | any failed node |

![Alarms](docs/screenshots/40-cloudwatch-alarms.png)
![Log groups](docs/screenshots/41-cloudwatch-log-groups.png)
![App logs in CloudWatch](docs/screenshots/42-cloudwatch-app-logs.png)
![Container Insights metrics](docs/screenshots/43-container-insights-metrics.png)

## Step 8 - Final validation

Tested through the load balancer:

| Check | Result |
|---|---|
| React app, `/healthz` | 200 |
| Register + login (auth) | works, JWT returned |
| Admin API with an admin user | works (user promoted to `admin` in MongoDB, there is no API for that) |
| Upload video + thumbnail (admin → S3 through Pod Identity) | 14.9 MB video and thumbnail stored in S3 |
| Video list (streaming) | returns the video with load balancer URLs |
| Stream with HTTP Range | `206 Partial Content`, `video/mp4` |
| Chat history + socket.io handshake | works, websocket upgrade offered |
| HPA | scaled 2 → 4 under load |

![Landing](docs/screenshots/30-app-landing.png)
![Register](docs/screenshots/31-app-register.png)
![Login](docs/screenshots/32-app-login.png)
![Browse](docs/screenshots/33-app-browse.png)
![Video details](docs/screenshots/34-app-video-details.png)
![Player with live chat](docs/screenshots/35-app-player-chat.png)
![Admin dashboard](docs/screenshots/36-app-admin-dashboard.png)

## Step 9 (bonus) - ChatOps

- SNS topic `streamingapp-deployments`: the Jenkinsfile publishes **deploy SUCCESS / FAILED** with the build number, commit and link.
- SNS topic `streamingapp-alerts`: CloudWatch alarm notifications.
- Both are delivered by **email**. Slack/Teams/Telegram was not connected (it needs a workspace or bot token); it can be added later with AWS Chatbot or a Lambda subscribed to the same topics.

![SNS](docs/screenshots/44-sns-topics.png)

---

## Security summary

- No AWS access keys in containers or Jenkins: EC2 instance role, EKS Pod Identity, EKS access entries
- Jenkins can deploy only inside the `streamingapp` namespace
- Worker nodes in private subnets; Jenkins UI open only to my IP; no SSH port
- All containers run as non-root
- Secrets in a Kubernetes Secret (random, not in Git); Jenkins password in SSM SecureString
- MongoDB app user limited to its own database; EBS volume and S3 bucket encrypted; S3 public access blocked
- ECR scan on push
- Removed MongoDB passwords from the application logs (the original code printed the full connection string)

## Problems I faced

1. **Build #1: Helm timed out, every backend crashed.** MongoDB never became Ready. Its readiness probe (`mongosh ping`) timed out after the default 1 s, and a headless Service does not publish DNS for pods that are not Ready, so `mongodb-0.mongodb` did not resolve. Fix: probe timeout 10 s and `publishNotReadyAddresses: true`.
2. **MongoDB still not Ready, backends got "Authentication failed".** The probe error said "AWS XRay Sampler enabled". The CloudWatch add-on auto-instruments every pod with OpenTelemetry, including `mongosh` (a Node.js tool), which made it hang. Because of that the init script that creates the app user also failed. Fix: turned off `autoMonitor.monitorAllServices` in the add-on, added opt-out annotations to the pods, and recreated MongoDB with an empty volume so the init script ran again.
3. **StatefulSet did not roll out the fix.** A pod that was never Ready blocks the StatefulSet rolling update, so I deleted the pod by hand.
4. **Build #2 failed: "another operation is in progress".** I was running `helm upgrade` from my laptop at the same time as Jenkins. After that only Jenkins deployed.
5. **Admin service crashed with `EACCES: mkdir /app/tmp-uploads`.** With `USER node` the `/app` folder was still owned by root. Fix: `chown node:node /app` in the Dockerfiles.
6. **Passwords in logs.** The auth service logged `mongodb://user:password@...`, which ended up in CloudWatch. Fixed in all four services.
7. **Jenkins not reachable.** My home IP changed, and the security group allowed only the old IP. Updated the rule.

## Cleanup

```bash
helm uninstall streamingapp -n streamingapp          # removes the load balancer
eksctl delete cluster -f infra/eksctl/cluster.yaml --disable-nodegroup-eviction
# plus: Jenkins EC2 + security group + IAM role, ECR repositories, S3 bucket,
# SNS topics, CloudWatch alarms and log groups, SSM parameter, S3 pod role
```

## What could be improved

- HTTPS: AWS Load Balancer Controller with an ALB Ingress and an ACM certificate
- MongoDB as a replica set (or Amazon DocumentDB / Atlas) for high availability and backups
- GitHub webhook instead of polling (needs Jenkins reachable from GitHub, e.g. behind an ALB)
- Fail the pipeline on critical ECR scan findings
- Slack/Telegram notifications through AWS Chatbot or a Lambda
- Cluster Autoscaler or Karpenter so nodes scale together with the pods
