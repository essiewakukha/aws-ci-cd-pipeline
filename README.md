# AWS CI/CD Capstone — myapp

A Node.js/Express "Hello from CI/CD" application deployed through a fully automated, end-to-end CI/CD pipeline on AWS:

**GitHub → CodePipeline → CodeBuild → Amazon ECR → Manual Approval → CodeDeploy (Blue/Green) → Amazon ECS Fargate behind an Application Load Balancer**, with CloudWatch + SNS monitoring.


---

## Live Application

```
http://myapp-alb-1916222490.us-east-1.elb.amazonaws.com
```

```bash
curl http://myapp-alb-1916222490.us-east-1.elb.amazonaws.com
# → Hello from AWS CI/CD Capstone Project!
```

---

## Architecture Overview

| Stage | Service | What it does |
|---|---|---|
| Source | GitHub + CodeStar (CodeConnections) | Triggers the pipeline on every push to `main` |
| Build | AWS CodeBuild | Installs dependencies, runs Jest/Supertest unit tests, builds the Docker image, pushes it to ECR, emits `imageDetail.json` |
| Approval | CodePipeline Manual Approval | Human gate before production deployment |
| Deploy | AWS CodeDeploy → Amazon ECS (Fargate) | Blue/Green deployment: spins up the new task set in the "green" target group, health-checks it, then shifts ALB traffic over and retires the old "blue" task set |
| Monitoring | CloudWatch Alarms + SNS | Alerts on high CPU and on the ECS service losing all running tasks |

---

## Repository Structure

```
aws-ci-cd-pipeline/
├── src/
│   └── app.js                # Express app ("/" and "/health" routes)
├── tests/
│   └── app.test.js           # Jest + Supertest unit tests
├── package.json
├── package-lock.json
├── Dockerfile                 # Pulls base image from ECR Public to avoid Docker Hub rate limits
├── buildspec.yml              # CodeBuild instructions
├── appspec.yml                 # CodeDeploy ECS Blue/Green spec
├── taskdef.json                # ECS task definition template (<IMAGE1_NAME> placeholder)
├── pipeline-diagram.png/.svg
└── README.md
```

---

## AWS Resources Provisioned

**Networking**
- Default VPC, 2 subnets across AZs (`us-east-1a`, `us-east-1c`)
- Security groups: `myapp-alb-sg` (public, port 80), `myapp-ecs-sg` (port 3000, ALB-only)

**Compute**
- ECS Cluster: `myapp-cluster` (Fargate)
- ECS Service: `myapp-service` (deployment controller: `CODE_DEPLOY`)
- Task Definition: `myapp-task`

**Load Balancing**
- Application Load Balancer: `myapp-alb`
- Target Groups: `myapp-tg-blue`, `myapp-tg-green` (health check path `/`)
- Listener on port 80

**Container Registry**
- ECR repository: `myapp-repo`

**CI/CD**
- CodeBuild project: `myapp-build`
- CodeDeploy application: `myapp-app`, deployment group: `myapp-dg` (Blue/Green, `CodeDeployDefault.ECSAllAtOnce`)
- CodePipeline: `myapp-pipeline` (Source → Build → Approval → Deploy)
- GitHub connection via CodeConnections (CodeStar)

**IAM Roles**
- `ecsTaskExecutionRole` — lets ECS pull from ECR and write logs
- `codebuild-myapp-service-role` — ECR push/pull, CloudWatch Logs, S3 artifacts
- `codedeploy-myapp-service-role` — manages ECS Blue/Green deployments
- `codepipeline-myapp-service-role` — orchestrates Source/Build/Approval/Deploy, with scoped `iam:PassRole` permissions for the ECS execution role and CodeDeploy role

**Monitoring**
- SNS topic: `myapp-alerts` (email subscription confirmed)
- CloudWatch Alarms:
  - `myapp-ecs-high-cpu` — `CPUUtilization > 80%` for 3 consecutive periods
  - `myapp-ecs-no-running-tasks` — `RunningTaskCount < 1` for 2 consecutive periods (requires Container Insights, enabled on `myapp-cluster`)

---

## How a Deployment Works

1. A commit is pushed to `main` on GitHub.
2. CodePipeline's **Source** stage detects the change via the CodeConnections webhook and pulls the repo.
3. **Build** stage runs in CodeBuild:
   - `npm ci` / `npm install`, then `npm test` (Jest + Supertest)
   - Logs in to ECR (token derived via STS, no hardcoded account ID)
   - Builds the Docker image, tags it with the short commit SHA and `latest`
   - Pushes both tags to ECR
   - Writes `imageDetail.json` (consumed by the Deploy stage to substitute the real image URI into `taskdef.json`)
4. **Approval** stage pauses the pipeline until a human reviews and approves in the console.
5. **Deploy** stage hands `taskdef.json`, `appspec.yml`, and the new image URI to CodeDeploy, which:
   - Registers a new ECS task definition revision with the real image
   - Launches the new task set behind the **green** target group
   - Health-checks it against the ALB
   - Shifts live traffic from **blue → green**
   - Terminates the old blue task set after a 5-minute bake time

---

## Local Development

```bash
npm install
npm test            # run unit tests
npm start            # runs on http://localhost:3000
```

### Local Docker test

```bash
docker build -t myapp .
docker run -p 8080:3000 myapp
curl http://localhost:8080
```

---

## Key Issues Hit & Fixed During Build-Out

This is a record of real problems encountered while building this out — useful context for anyone reproducing the setup:

| Issue | Root Cause | Fix |
|---|---|---|
| `npm install` failed in Docker with `ENOENT package.json` | `package.json` lived inside `src/` while the Dockerfile copied from repo root | Moved `package.json`/`package-lock.json` to repo root; updated Dockerfile and `main`/`start` script paths |
| `Cannot find module 'express'` at container runtime | Stale image layer / empty `package-lock.json` meant `npm install` had nothing to install | Regenerated `package-lock.json` via `npm install` |
| ALB target health checks failing (404) | Health check path was `/health`, which didn't exist on the deployed app version | Changed target group health check path to `/` |
| `docker push` returned empty `list-images` initially | ECR auth token had gone stale between login and push | Re-ran `aws ecr get-login-password` immediately before pushing |
| CodeBuild `PRE_BUILD` failure: `aws ecr get-login` | That command is deprecated and removed from the AWS CLI | Switched to `aws ecr get-login-password \| docker login` |
| CodeBuild `INSTALL` failure: `npm ci` lockfile error | `package-lock.json` was empty/missing in the repo | Regenerated and committed a valid lockfile |
| `docker build` failed: `429 Too Many Requests` from Docker Hub | CodeBuild's IP shares Docker Hub's anonymous pull rate limit | Changed `FROM node:16` to `FROM public.ecr.aws/docker/library/node:18-slim` (ECR Public mirror, no rate limit) |
| CodeDeploy: `does not match any of the missing containers` | `taskdef.json`'s `Image1ContainerName` field was set to the literal container name instead of the placeholder text | Set `Image1ContainerName` back to `IMAGE1_NAME`, matching the `<IMAGE1_NAME>` placeholder in `taskdef.json` |
| Same error persisted after the fix above | Repo's `taskdef.json` still had the original spec's `<REPOSITORY_URI>:latest` placeholder instead of `<IMAGE1_NAME>` | Rewrote `taskdef.json` to use `<IMAGE1_NAME>` as the image placeholder |
| `ecs:RegisterTaskDefinition` access denied for CodePipeline role | `codepipeline-myapp-service-role` lacked ECS permissions and PassRole rights | Attached `AmazonECS_FullAccess` and a scoped `iam:PassRole` policy for `ecsTaskExecutionRole` and `codedeploy-myapp-service-role` |
| `CreateDeploymentGroup`: cross-account pass role error | Shell variables (`$ACCOUNT_ID`, `$LISTENER_ARN`) were empty in a fresh terminal session, producing malformed ARNs | Re-exported all required environment variables before retrying |
| `SubscriptionRequiredException` on `CreateApplication` (CodeDeploy) | AWS Free Plan account hadn't yet verified a payment method, which gates access to certain services | Added and verified a payment method in Billing console |

---

## Monitoring & Alerts

- SNS topic `myapp-alerts` has a confirmed email subscription.
- Two CloudWatch alarms route to that topic:
  - High CPU utilization on the ECS service
  - ECS service dropping to zero running tasks
- Container Insights is enabled on `myapp-cluster` so task-count metrics are available to the alarm.

---

## Notes on Placeholders

- `taskdef.json` → `<IMAGE1_NAME>` is replaced automatically by CodePipeline's Deploy action using the image URI from `imageDetail.json`. Do not hardcode a real image URI here.
- `appspec.yml` → `<TASK_DEFINITION>` is filled in automatically by CodeDeploy with the newly registered task definition ARN.
- `buildspec.yml` derives the AWS account ID via `aws sts get-caller-identity` at build time — no account ID needs to be configured manually in the CodeBuild project.

---

## Triggering a New Deployment

```bash
git add .
git commit -m "your change"
git push
```

CodePipeline picks up the push automatically. Approve the **Approval** stage in the console when prompted, and CodeDeploy will perform a zero-downtime Blue/Green shift to the new version.

Members: Esther Wakukha, Joy Muthoka, Felicity Mwende, Leon Mwai
