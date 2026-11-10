# SOP: Deploying an EC2 Instance with the `ec2-asg` Module

**Repository:** `emzeka-star/platform-templates` → `modules/ec2-asg`
**Target account:** `288743750008` (lab), region `us-east-1`, CLI profile `infra`
**Environment:** Windows 11, PowerShell 5.1, VS Code
**Last updated:** 2026-09-08

---

## 1. Purpose and scope

This SOP covers deploying a single EC2 instance into an Auto Scaling Group using the
`ec2-asg` module from `platform-templates`.

**Important distinction:** this module creates a launch template and an Auto Scaling
Group, not a standalone instance. "One instance" means setting min/max/desired capacity
to 1. Consequences:

- There is no stable instance ID or IP to reference — the ASG may replace the instance
  at any time (health check failure, AZ rebalance, launch template change).
- Anything in `user_data` runs on every launch, including replacements. Bootstrap
  scripts must be idempotent.
- Do not store state on the instance's root volume. Treat it as disposable.

If you need a genuine pet instance with a fixed ID, this is the wrong module.

---

## 2. Prerequisites

| Requirement | Check |
|---|---|
| Terraform ≥ 1.6 | `terraform version` |
| AWS CLI v2 configured with the `infra` profile | `aws sts get-caller-identity` |
| Repo cloned to `C:\dev\platform-templates` | `Test-Path C:\dev\platform-templates\modules\ec2-asg` |
| S3 state bucket `emzeka-terraform-state-2026` exists | `aws s3 ls s3://emzeka-terraform-state-2026` |

**Every new PowerShell session** must set the profile before any Terraform or AWS CLI
command:

```powershell
$env:AWS_PROFILE = "infra"
aws sts get-caller-identity
```

Confirm the returned account is `288743750008`. Terraform will happily write state using
whatever credentials it finds; verifying up front is cheaper than unpicking state
written against the wrong account.

Never work from a OneDrive-synced path. All repos live under `C:\dev\`.

---

## 3. Create the environment directory

Root configurations live in `envs/<environment>/`. Never run `terraform apply` inside
`modules/` — modules are libraries, not deployables.

```powershell
New-Item -ItemType Directory -Force -Path C:\dev\platform-templates\envs\dev
cd C:\dev\platform-templates\envs\dev
code .
```

`-Force` creates missing parent directories. Note that `code <file>` will not create a
file that doesn't exist — open the folder and use the Explorer sidebar, or
`New-Item -ItemType File main.tf` first.

---

## 4. Enumerate the module's inputs

Module inputs change between versions. Read them from the source rather than assuming:

```powershell
Select-String -Path ..\..\modules\ec2-asg\variables.tf -Pattern '^variable'
```

For any variable whose purpose is unclear, read its description and validation rules:

```powershell
Select-String -Path ..\..\modules\ec2-asg\variables.tf -Pattern "<variable_name>" -Context 0,10
```

To distinguish required from optional inputs, look for `default`. A variable with no
`default` is required and `terraform validate` will reject the config without it.

### Verified inputs as of `main` (2026-09-08)

| Input | Required | Notes |
|---|---|---|
| `user_data` | Yes | **Plain string.** Must be non-empty. Module applies `base64encode()` internally (`main.tf:93`) — do not pre-encode. Validated against the 16 KB EC2 limit post-encoding. |
| `iam_instance_profile_name` | No | Profile **name**, not ARN. Attached via a `dynamic` block, so omitting it means no instance profile at all. Required for SSM Session Manager or any AWS API call from the instance. |

Other inputs used in the example below (`name`, `vpc_id`, `subnet_ids`,
`instance_type`, `min_size`, `max_size`, `desired_capacity`, `tags`) follow the
library's usual naming but were not individually verified — confirm against
`variables.tf` before first use.

---

## 5. Collect network IDs

```powershell
aws ec2 describe-vpcs --query "Vpcs[].{ID:VpcId,Default:IsDefault,CIDR:CidrBlock}" --output table
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" --query "Subnets[].{ID:SubnetId,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}" --output table
```

Select at least two subnets in **different availability zones** so the ASG can recover
if one AZ is impaired.

**Subnet choice determines whether SSM works.** The SSM agent must reach the SSM
endpoints:

- Public subnets with `MapPublicIpOnLaunch = True` — works with no extra infrastructure.
- Private subnets — require either a NAT gateway or VPC interface endpoints for `ssm`,
  `ssmmessages`, and `ec2messages`. Without one of these the instance boots, appears
  healthy, and never registers with Systems Manager.

---

## 6. Write the bootstrap script

Create `user_data.sh` in the environment directory:

```bash
#!/bin/bash
set -euo pipefail

dnf update -y
dnf install -y nginx
systemctl enable --now nginx
```

**Line endings must be LF, not CRLF.** VS Code on Windows defaults to CRLF; `file()`
reads the script verbatim and cloud-init fails on `#!/bin/bash^M`. The instance will
boot normally and the script will silently never run.

Fix per file via the `CRLF` indicator in the VS Code status bar (bottom right). Fix
permanently by adding to the repo root `.gitattributes`:

```
*.sh text eol=lf
```

**Keep the script under 16 KB.** For larger payloads, upload to S3 and reduce
`user_data` to a fetch-and-execute stub — this also requires S3 read permissions on the
instance role.

---

## 7. Write the root configuration

Create `main.tf`:

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket = "emzeka-terraform-state-2026"
    key    = "dev/ec2-asg/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_iam_role" "instance" {
  name = "dev-app-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "dev-app-instance-profile"
  role = aws_iam_role.instance.name
}

module "app_asg" {
  source = "../../modules/ec2-asg"

  name          = "dev-app"
  vpc_id        = "vpc-REPLACE"
  subnet_ids    = ["subnet-REPLACE-A", "subnet-REPLACE-B"]
  instance_type = "t3.micro"

  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  user_data                 = file("${path.module}/user_data.sh")
  iam_instance_profile_name = aws_iam_instance_profile.instance.name

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
```

### Conventions

- **State key:** one key per environment — `dev/ec2-asg/terraform.tfstate`. Never share
  a key across environments.
- **Instance profile reference:** pass `aws_iam_instance_profile.instance.name`, not
  the role name. Passing the role name produces a config that applies cleanly and then
  fails at instance launch.
- **Module source pinning:** a relative path (`../../modules/ec2-asg`) is correct when
  the root config lives in the same repo, and tracks your working tree. When calling
  from a *different* repo, pin to a tag:
  `source = "git::https://github.com/emzeka-star/platform-templates.git//modules/ec2-asg?ref=v1.2.0"`
  The `source` value must be a literal string — no interpolation is permitted.

---

## 8. Deploy

```powershell
$env:AWS_PROFILE = "infra"
cd C:\dev\platform-templates\envs\dev

terraform init
terraform fmt
terraform validate
terraform plan -out=tfplan
```

Review the plan before applying. Confirm:

- Resource count matches expectation (launch template, ASG, IAM role/profile/attachment,
  plus any security group the module creates).
- No unexpected deletions.
- Subnet and VPC IDs are the real ones, not placeholders.

```powershell
terraform apply tfplan
```

`terraform validate` reports missing required arguments in batches — expect to iterate
if the module gained inputs since this SOP was written.

---

## 9. Verify

```powershell
# ASG reports the expected capacity
aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?contains(AutoScalingGroupName,'dev-app')].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:length(Instances)}" --output table

# Instance is running and passing health checks
aws ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=*dev-app*" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,IP:PublicIpAddress,State:State.Name}" --output table

# Instance has registered with Systems Manager
aws ssm describe-instance-information --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,Platform:PlatformName}" --output table
```

Connect and confirm the bootstrap ran:

```powershell
aws ssm start-session --target <instance-id>
```

Inside the session:

```bash
sudo cat /var/log/cloud-init-output.log
systemctl status nginx
```

`cloud-init-output.log` is the first place to look when `user_data` appears not to have
run. CRLF line endings and double base64 encoding both show up here.

If the instance does not appear in `describe-instance-information`, work through:
missing instance profile → missing `AmazonSSMManagedInstanceCore` policy → no network
route to the SSM endpoints → AMI without the agent preinstalled.

---

## 10. Teardown

```powershell
$env:AWS_PROFILE = "infra"
cd C:\dev\platform-templates\envs\dev
terraform destroy
```

Confirm no orphaned resources remain — ASG-managed instances occasionally outlive a
failed destroy:

```powershell
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value}" --output table
```

Lab instances left running are the main source of unexpected cost. Destroy at the end
of each working session unless the environment is deliberately persistent.

---

## 11. Known failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `New-Item: Could not find a part of the path` | `New-Item` defaults to a file and won't create parents | Add `-ItemType Directory -Force` |
| VS Code: "Path does not exist" | `code <file>` cannot create files | `New-Item -ItemType File <name>` first, or `code .` |
| `Missing required argument "user_data"` | Variable has no default | Pass a non-empty plain string |
| Instance boots, `user_data` never ran | CRLF line endings, or pre-encoded input | Save as LF; pass raw text — the module encodes |
| Instance never appears in SSM | No instance profile, or no route to SSM endpoints | Attach profile; use public subnet or add VPC endpoints |
| Launch fails after a clean apply | Role name passed instead of profile name | Use `aws_iam_instance_profile.<n>.name` |
| Terraform uses wrong AWS account | `AWS_PROFILE` not set in this session | `$env:AWS_PROFILE = "infra"` then re-verify with `sts get-caller-identity` |
| Multi-line file written by `Add-Content` is truncated | Known PowerShell 5.1 behaviour | Author `.tf` and `.sh` files in VS Code, not via `Add-Content` |

---

## 12. Maintenance

Re-verify section 4 against `modules/ec2-asg/variables.tf` whenever the module is
updated, and update the verified-inputs table. When a new library tag is cut, note the
tag alongside it so cross-repo callers know which version this SOP describes.
