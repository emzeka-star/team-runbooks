# Deploying a Neon-backed application to Fargate

Builds a Flask application that connects to Neon serverless Postgres, stores
the image in the existing ECR repository (`ecslab-app`), and runs it as a
Fargate service behind the ALB.

---

## 0. Prerequisites

- A Neon project with a database, and its connection string to hand
- Docker Desktop running
- `aws sts get-caller-identity --profile infra` returns account `288743750008`

Get the connection string from the Neon console: Project → Connection Details.
Select the **Pooled connection** option — the host will contain `-pooler`.

```
postgresql://user:password@ep-xxx-pooler.us-east-2.aws.neon.tech/dbname?sslmode=require
```

Use the pooled endpoint rather than the direct one. Each Fargate task holds
its own connection pool, and task counts change with deployments and scaling;
the pooler absorbs that. `sslmode=require` is mandatory — Neon refuses
plaintext connections.

---

## 1. Store the connection string

Created outside Terraform on purpose. A secret created with
`aws_secretsmanager_secret_version` has its plaintext value written into
Terraform state, and state is a file in S3 that more people can read than
should see a database password.

```powershell
aws secretsmanager create-secret `
  --name ecslab-dev-neon-url `
  --description "Neon Postgres connection string for ecslab-dev" `
  --secret-string "postgresql://user:password@ep-xxx-pooler.REGION.aws.neon.tech/dbname?sslmode=require" `
  --profile infra
```

Verify without printing the value:

```powershell
aws secretsmanager describe-secret --secret-id ecslab-dev-neon-url --profile infra `
  --query '{Name:Name,Arn:ARN}' --output table
```

**Note:** the string appears in your PowerShell history. Clear it if that
matters:

```powershell
Clear-History
Remove-Item (Get-PSReadlineOption).HistorySavePath
```

---

## 2. Application files

Place under `C:\dev\ecs-lab\neon-app\`:

```
neon-app\
  app.py
  Dockerfile
  requirements.txt
  .dockerignore
```

Create the dotfile first — VS Code will not open a non-existent path starting
with a dot:

```powershell
cd C:\dev\ecs-lab
mkdir neon-app; cd neon-app
New-Item .dockerignore -ItemType File
code .
```

### Endpoint design

| Path | Touches DB | Purpose |
|------|-----------|---------|
| `/health` | No | ALB target group health check |
| `/ready` | Yes | Manual or deployment-gate connectivity check |
| `/` | No | Version and hostname |
| `/items` | Yes | GET and POST, demonstrates persistence |

`/health` deliberately does not query the database. If it did, a Neon cold
start or a brief network blip would fail health checks and ECS would kill and
replace otherwise-healthy tasks in a loop — a failure that looks like an
application crash but is caused by the health check itself.

---

## 3. Build and test locally

```powershell
cd C:\dev\ecs-lab\neon-app
docker build --platform linux/amd64 --provenance=false -t ecslab-neon-app:v0.2.0 .
docker image inspect ecslab-neon-app:v0.2.0 --format '{{.Architecture}}'
```

Expect `amd64`.

Test against the real Neon database before pushing. An immutable repository
will not accept a corrected image under the same tag.

```powershell
$NeonUrl = Read-Host "Neon connection string" -AsSecureString
$Plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($NeonUrl))

docker run --rm -p 8000:8000 -e DATABASE_URL="$Plain" -e APP_VERSION=v0.2.0 ecslab-neon-app:v0.2.0
```

`Read-Host -AsSecureString` keeps the connection string out of your shell
history.

From a second terminal:

```powershell
curl.exe http://localhost:8000/health     # {"status":"ok"}
curl.exe http://localhost:8000/ready      # Postgres version — proves connectivity
curl.exe http://localhost:8000/items      # {"count":0,"items":[]}

curl.exe -X POST http://localhost:8000/items `
  -H "Content-Type: application/json" -d '{\"name\":\"first item\"}'

curl.exe http://localhost:8000/items      # now contains the row
```

If `/ready` returns 503, the detail field carries the real error. Common
causes: `sslmode=require` missing, wrong password, or the Neon project
suspended and slow to wake.

---

## 4. Push to ECR

```powershell
$Account  = "288743750008"
$Region   = "us-east-1"
$Registry = "$Account.dkr.ecr.$Region.amazonaws.com"
$Uri      = "$Registry/ecslab-app"
$Tag      = "v0.2.0"

aws ecr get-login-password --region $Region --profile infra |
  docker login --username AWS --password-stdin $Registry

docker tag "ecslab-neon-app:$Tag" "${Uri}:${Tag}"
docker push "${Uri}:${Tag}"

aws ecr describe-images --repository-name ecslab-app --image-ids imageTag=$Tag `
  --profile infra --output table
```

Reusing the existing `ecslab-app` repository is fine — different tags, one
repository. Create a second repository only if the applications have different
access requirements or lifecycle policies.

---

## 5. Deploy

Add `neon.tf` to `C:\dev\ecs-lab\`, and these variables to `variables.tf`:

```hcl
variable "neon_secret_name" {
  description = "Name of the Secrets Manager secret holding the Neon connection string. Created outside Terraform so the value never enters state."
  type        = string
  default     = "ecslab-dev-neon-url"
}

variable "neon_app_image_tag" {
  description = "Image tag to deploy. Must already be pushed."
  type        = string
  default     = "v0.2.0"
}
```

Then:

```powershell
cd C:\dev\ecs-lab
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

---

## 6. Verify

```powershell
curl.exe (terraform output -raw app_health_url)

$Url = terraform output -raw app_url
curl.exe "$Url/ready"
curl.exe "$Url/items"

curl.exe -X POST "$Url/items" -H "Content-Type: application/json" -d '{\"name\":\"from fargate\"}'
```

To prove the data genuinely lives in Neon rather than in the container, force
a task replacement and read the items back:

```powershell
aws ecs update-service --cluster ecslab-dev --service ecslab-dev-neon-app `
  --force-new-deployment --profile infra

# wait for the new task, then
curl.exe "$Url/items"
```

The rows survive. That is the practical difference from the EFS-backed
Postgres service — the state is outside the cluster entirely.

---

## 7. Troubleshooting

### `/ready` returns 503, `/health` returns 200

The container is running and the database is not reachable. This separation is
the point of the two endpoints. Check the detail field, then:

```powershell
aws logs tail /ecs/ecslab-dev-neon-app --follow --profile infra
```

| Detail contains | Cause |
|---|---|
| `SSL connection has been closed` / `server does not support SSL` | `sslmode=require` missing from the connection string |
| `password authentication failed` | Wrong credentials, or the secret holds a stale string |
| `timeout expired` | No egress. Confirm the NAT gateway exists and private route tables point at it |
| `could not translate host name` | Typo in the host, or DNS resolution failing |
| `too many connections` | Direct endpoint in use instead of pooled, or too many workers x pool size |

### Tasks cycle without ever becoming healthy

Check whether the ALB health check path is `/health` and not `/ready`. Pointing
it at a database-dependent endpoint makes any database hiccup look like an
application crash.

```powershell
aws elbv2 describe-target-health --target-group-arn <arn> --profile infra --output table
```

### `ResourceNotFoundException` on the secret at apply

The secret does not exist yet. Step 1 must precede the first apply — the data
source is a lookup, not a create.

### First request after idle is slow

Expected. A Neon project that has scaled to zero takes roughly half a second
to a few seconds to wake. The pool `timeout=15` and gunicorn `--timeout 30`
accommodate this.

### Secret updated but the task still uses the old value

Secrets are read once at task start. Force a new deployment:

```powershell
aws ecs update-service --cluster ecslab-dev --service ecslab-dev-neon-app `
  --force-new-deployment --profile infra
```

---

## 8. Neon-specific considerations

**IP allowlist.** On paid Neon plans, restrict access to the NAT gateway's
Elastic IP:

```powershell
terraform output nat_public_ips
```

That IP changes when the NAT gateway is destroyed and recreated, which
`terraform destroy` does — the allowlist needs updating after each teardown
and rebuild.

**Connection budget.** Total connections are `task_count x workers x
pool_max_size`. At the defaults that is `1 x 2 x 3 = 6`. Scaling to 4 tasks
makes it 24. Raise worker count and pool size deliberately, and prefer the
pooled endpoint.

**Branching.** Neon branches give an isolated copy of the database. A
per-environment branch, with its own connection string in its own secret, is
a cleaner separation than sharing one database across `dev` and `prod`.

**This does not replace the EFS-backed Postgres service.** The two are
alternatives: Neon removes the operational burden and the EFS module keeps
data inside your VPC. Running both in one cluster is fine for comparison, but
pick one per real environment.
