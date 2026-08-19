# SOP: Containerised application on ECS Fargate behind an ALB

**Repository:** `team-runbooks`
**Applies to:** Windows 11 / PowerShell 5.1+, Terraform ≥ 1.6, AWS account `288743750008` (`us-east-1`)
**Related SOPs:** *PostgreSQL on ECS Fargate with EFS*, *Git and Terraform workstation setup on Windows*
**Last validated:** 19 August 2026 against `ecs-lab` at commit `575f654`

---

## 1. Purpose and scope

Takes an application from source code to a working HTTP endpoint on AWS
Fargate: build a container image, store it in ECR, and run it as an ECS
service behind an Application Load Balancer.

Covers a stateless HTTP application. A stateful workload requiring persistent
storage is covered by the *PostgreSQL on ECS Fargate with EFS* SOP; the two
can coexist in one cluster.

Out of scope: TLS certificates and custom domains, CI/CD, autoscaling,
service-to-service networking.

---

## 2. Architecture

```
Internet
   │
   ▼
ALB :80                    public subnets  (10.20.0.0/24, 10.20.1.0/24)
   │  target group, target_type = "ip"
   │  health check GET /health, expect 200
   ▼
App tasks :8000            private subnets (10.20.10.0/24, 10.20.11.0/24)
   │                       assign_public_ip = false
   ▼
NAT gateway ──▶ ECR, CloudWatch Logs
```

Tasks hold no public IP. Inbound reaches them only via the ALB, because the
task security group admits port 8000 from the ALB's security group rather than
from a CIDR range. Outbound egress via NAT is required for the image pull and
log writes.

---

## 3. Prerequisites

| Requirement | Verify |
|---|---|
| Docker Desktop running, Linux engine | `docker info --format '{{.ServerVersion}}'` |
| Valid AWS credentials | `aws sts get-caller-identity --profile infra` |
| Repo cloned under `C:\dev\` | Never a OneDrive-synced path — silent zero-byte writes |
| Provider pinned to a profile | `profile = "infra"` in the provider block |

The provider `profile` argument is preferable to relying on
`$env:AWS_PROFILE`, which does not persist between PowerShell sessions and is
the usual cause of `InvalidClientTokenId` from Terraform.

---

## 4. Part one — ECR repository

Add `ecr.tf` to the root module.

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the most recent 20 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

Then:

```powershell
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### Design decisions

**`IMMUTABLE` tags.** A mutable `:latest` means the code a task runs depends on
when it started, so two tasks in one service can differ. Immutable tags make
rollback a matter of pointing the task definition at an earlier tag.

**Two lifecycle rules.** BuildKit writes untagged attestation manifests
alongside each push. Under a single `imageCountMoreThan` rule these occupy
slots, so a repository set to keep ten images can start expiring real ones
after four or five pushes. Rule 1 sweeps untagged images by age; rule 2 then
counts something close to actual releases. AWS requires the `tagStatus = "any"`
rule to carry the highest `rulePriority`, hence the ordering.

**`force_delete` left at default (false).** A `terraform destroy` that would
discard pushed images fails rather than proceeding. See §9.

---

## 5. Part two — build and push

### 5.1 Application files

Directory layout keeps the Docker context separate from the Terraform:

```
C:\dev\<project>\
  *.tf
  app\
    app.py
    Dockerfile
    requirements.txt
    .dockerignore
```

Create dotfiles with `New-Item` first — VS Code refuses to open a
non-existent path beginning with a dot:

```powershell
mkdir app; cd app
New-Item .dockerignore -ItemType File
code .
```

**`Dockerfile`:**

```dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN useradd --create-home --shell /bin/false appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
```

Three points: a production WSGI server rather than the framework's development
server; a non-root `USER`; and `COPY requirements.txt` before `COPY app.py`, so
layer caching means a code edit does not reinstall dependencies.

**`.dockerignore`** must exclude the Terraform directory, or every build ships
provider binaries to the daemon:

```
.git
__pycache__
*.pyc
.venv
*.tf
.terraform
tfplan
```

The application must expose a health endpoint returning HTTP 200. The ALB
target group depends on it; without one, targets never become healthy.

### 5.2 Build and test locally

```powershell
docker build --platform linux/amd64 --provenance=false -t ecslab-app:v0.1.0 .
docker image inspect ecslab-app:v0.1.0 --format '{{.Architecture}}'   # expect amd64
```

`--platform linux/amd64` is required. Fargate task definitions default to
`X86_64`; an image built on an ARM host without it passes the pull and then
fails at start with `exec format error`.

`--provenance=false` suppresses the untagged attestation manifests.

Test before pushing — an immutable repository will not accept a corrected
image under the same tag:

```powershell
docker run --rm -p 8000:8000 ecslab-app:v0.1.0
```

The terminal will appear to hang after gunicorn logs "Booting worker". This is
correct; a server process prints nothing further until a request arrives. From
a second terminal:

```powershell
curl.exe http://localhost:8000/health
```

### 5.3 Push

```powershell
$Account  = "288743750008"
$Region   = "us-east-1"
$Registry = "$Account.dkr.ecr.$Region.amazonaws.com"
$Uri      = "$Registry/ecslab-app"
$Tag      = "v0.1.0"

aws ecr get-login-password --region $Region --profile infra |
  docker login --username AWS --password-stdin $Registry

docker tag "ecslab-app:$Tag" "${Uri}:${Tag}"
docker push "${Uri}:${Tag}"

aws ecr describe-images --repository-name ecslab-app --image-ids imageTag=$Tag `
  --profile infra --output table
```

Confirm the digest reported by `docker push` matches the local build. The ECR
login token expires after 12 hours, so `get-login-password` runs once per
session.

---

## 6. Part three — deploy

### 6.1 Load balancer

```hcl
module "alb" {
  source = "git::https://github.com/emzeka-star/platform-templates.git//modules/alb?ref=v0.5.2"

  name       = "${local.name}-app"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnet_ids

  target_type     = "ip"
  target_port     = var.app_port
  target_protocol = "HTTP"

  health_check_path    = "/health"
  health_check_matcher = "200"
  deregistration_delay = 15
}
```

> **`target_type = "ip"` is mandatory for Fargate.** The module defaults to
> `"instance"`, which is correct for EC2 Auto Scaling Groups. With the default
> in place, Fargate targets never register, every request returns 503, and no
> error message names the cause. This is the single most likely failure in this
> procedure.

`deregistration_delay` is lowered from 60 because Fargate task replacement is
fast and there are no long-lived connections to drain.

### 6.2 Security groups

Ingress references the ALB's security group ID, not a CIDR. This is what makes
the tasks unreachable from anywhere else in the VPC.

```hcl
resource "aws_security_group" "app_task" {
  name_prefix = "${local.name}-app-task-sg-"
  description = "Application task"
  vpc_id      = module.vpc.vpc_id

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app_task.id
  referenced_security_group_id = module.alb.security_group_id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app_task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

Egress must remain open: the task pulls its image from ECR and writes to
CloudWatch Logs, both over the NAT gateway.

### 6.3 IAM — two roles, distinct purposes

| Role | Assumed by | Needs |
|---|---|---|
| Execution | ECS agent | `AmazonECSTaskExecutionRolePolicy` — image pull, log writes |
| Task | The application process | Only what the app calls; often nothing |

A missing managed policy on the **execution** role produces
`CannotPullContainerError` with no indication that IAM is the cause. Attaching
it to the task role instead does not help.

### 6.4 Task definition

```hcl
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.app_execution.arn
  task_role_arn            = aws_iam_role.app_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
    essential = true

    portMappings = [{ containerPort = var.app_port, protocol = "tcp" }]

    environment = [
      { name = "APP_VERSION", value = var.app_image_tag }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}
```

Fargate accepts only specific CPU/memory pairings. 256 CPU permits 512, 1024
or 2048 MiB. An invalid combination fails at apply, not at plan.

Surfacing the image tag as an environment variable gives a cheap way to
confirm which build is running — the deployed app can report its own version.

### 6.5 Service

```hcl
resource "aws_ecs_service" "app" {
  name            = "${local.name}-app"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnet_ids
    security_groups  = [aws_security_group.app_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = module.alb.target_group_arn
    container_name   = "app"
    container_port   = var.app_port
  }

  health_check_grace_period_seconds = 30

  depends_on = [module.alb]
}
```

`health_check_grace_period_seconds` gives the container time to boot before ALB
health checks count against it. Without it, a slow-starting task is killed and
replaced in a loop that resembles a crash.

---

## 7. Ordering constraint

```
apply ECR  →  build and push  →  apply the service
```

A service whose task definition names a tag that does not exist cycles tasks
through `CannotPullContainerError` indefinitely rather than failing outright.
Where one root module holds both, target the repository first:

```powershell
terraform apply -target=aws_ecr_repository.app
```

---

## 8. Verification

Allow 60–90 seconds after apply. The ALB provisions in 3–4 minutes and the
target must pass two health checks 30 seconds apart.

```powershell
terraform output app_url
curl.exe (terraform output -raw app_health_url)
```

A healthy response confirms the whole path. Note in particular that the
hostname the app reports should be a private address (`ip-10-20-x-x`),
confirming the task holds no public IP.

```powershell
# Target health — first place to look on a 503
aws elbv2 describe-target-health --target-group-arn <arn> --profile infra --output table

# Service counts. Note --services, plural. --service-name belongs to list-tasks.
aws ecs describe-services --cluster ecslab-dev --services ecslab-dev-app `
  --query 'services[0].{running:runningCount,desired:desiredCount,status:status}' --profile infra

# Service events are more informative than logs for startup failures
aws ecs describe-services --cluster ecslab-dev --services ecslab-dev-app `
  --query 'services[0].events[:5]' --profile infra

aws logs tail /ecs/ecslab-dev-app --follow --profile infra
```

Add `--output table` to avoid the Windows pager.

---

## 9. Teardown

```powershell
terraform destroy
```

This **fails by design** while the ECR repository holds images:

```
RepositoryNotEmptyException: ... cannot be deleted because it still contains images
```

To remove the billable resources and retain the image:

```powershell
terraform destroy -target=module.alb -target=aws_ecs_service.app `
  -target=module.postgres -target=module.vpc -target=aws_ecs_cluster.this
```

Confirm nothing is left billing:

```powershell
terraform state list

aws ec2 describe-nat-gateways --profile infra `
  --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output table

# Unattached Elastic IPs bill separately
aws ec2 describe-addresses --profile infra `
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table
```

Both should return empty. An orphaned Elastic IP is released with
`aws ec2 release-address --allocation-id <id>`.

### Running cost

| Resource | Approx. monthly |
|---|---|
| NAT gateway | $32 (hourly, regardless of traffic) |
| Application Load Balancer | $16 |
| Fargate task, 256/512 | $9 |
| ECR storage | negligible |

Roughly $2.50/day with a Postgres task also running. Destroy at the end of a
working session.

---

## 10. Troubleshooting

### `failed to connect to the docker API at npipe:...dockerDesktopLinuxEngine`

Docker Desktop is not running. The named pipe does not exist until the WSL2
backend is up; wait for the status bar to read "Engine running".

### `InvalidClientTokenId`

The access key ID no longer exists in IAM. Establish where the credential comes
from before changing anything:

```powershell
aws configure list
```

The `Type` column is the point. `env` means environment variables are in play
and override the credentials file, so editing the file appears to do nothing.

Do not leave a stale `[default]` profile in `~\.aws\credentials`. Every command
omitting `--profile` then fails with this error, pointing away from the real
cause.

If Terraform reports this while the CLI works, the provider `profile` argument
is missing.

### `Reference to undeclared input variable`

A variable name mismatch between config and `variables.tf`. Enumerate what
actually exists:

```powershell
Select-String -Path variables.tf -Pattern 'variable "'
```

Two variables meaning one thing is a live hazard: a config using
`var.project_name` (`ecslab`) alongside a module using `var.project`
(`ecs-lab`) produces `ecslab-app` in AWS while pushes target `ecs-lab-app`.
Consolidate on one name.

### 503 from the ALB

In order of likelihood:

1. `target_type` is `instance` rather than `ip`. Target group shows no
   registered targets.
2. Health check path or matcher wrong — `Target.ResponseCodeMismatch`.
3. Task security group does not admit the ALB security group —
   `Target.Timeout`.
4. Tasks still starting. Wait 90 seconds before investigating.

### `CannotPullContainerError`

1. Execution role missing `AmazonECSTaskExecutionRolePolicy`.
2. No egress from the private subnet. Requires a NAT gateway, or the four VPC
   endpoints `ecr.api`, `ecr.dkr`, `logs` (interface) and `s3` (gateway). The
   S3 gateway endpoint is needed because layers are stored in S3, and is the
   one most often omitted.
3. The tag genuinely does not exist in the repository.

### `exec format error`

Architecture mismatch. Rebuild with `--platform linux/amd64`.

### PowerShell here-strings hang

The closing `'@` must begin at column one with no leading whitespace. Pasting a
multi-line block into the console often breaks this and PowerShell waits for
the string to close, showing a `>>` continuation prompt. Ctrl+C to escape.

For file content, prefer VS Code, or the `Set-Content` array form:

```powershell
Set-Content requirements.txt -Encoding utf8 -Value @(
  'flask==3.0.3'
  'gunicorn==22.0.0'
)
```

Use single-quoted here-strings (`@'` … `'@`) when content contains `${...}`, or
PowerShell will interpolate Terraform syntax as its own variables.

### Console shows nothing

The region selector is sticky per browser session. Resources in `us-east-1` are
invisible while the console sits in another region, and the page reads "No
repositories were found" rather than mentioning regions.

---

## 11. Follow-up items

| Item | Rationale |
|---|---|
| TLS via ACM certificate | `certificate_arn` on the `alb` module adds a 443 listener and redirects 80. Needs a domain. |
| Build/push in GitHub Actions | SHA-tagged images built in CI tie a deployment to a commit. |
| Reconsider `alb` module `target_type` default | `"instance"` is a silent failure for Fargate consumers. Document prominently or change. |
| Wire app to Postgres | Pass the app security group to the `ecs-postgres` module's `allowed_security_group_ids`. |
