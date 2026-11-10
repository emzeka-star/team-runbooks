# SOP: PostgreSQL on ECS Fargate with EFS

| | |
|---|---|
| **Owner** | Platform Engineering |
| **Applies to** | `platform-templates//modules/ecs-postgres` |
| **Module version** | v0.5.2 |
| **Environments** | Development and learning only |
| **Last updated** | 2026-08-18 |
| **Verified against** | AWS provider 5.100.0, Terraform 1.6+, postgres:16.4-alpine |

---

## 1. Scope and limitations

This SOP covers a single-writer PostgreSQL container on ECS Fargate with its
data directory on Amazon EFS.

**Approved uses:** development databases, learning environments, throwaway test
fixtures, workloads where total data loss is acceptable.

**Not approved for production.** Specifically absent:

| Capability | Managed service | This module |
|---|---|---|
| Point-in-time recovery | Yes | No |
| Automated failover | Yes | No |
| Read replicas | Yes | No |
| Zero-downtime patching | Yes | No — every deploy stops the database |
| Consistent snapshots | Yes | No — file-level copy only |
| Major version upgrade path | Managed | Manual dump and restore |

For production, use RDS, Aurora, or a managed provider such as Neon.

---

## 2. Architecture

```
VPC
├── public subnets  ──> IGW, NAT gateway
└── private subnets ──> Fargate task (postgres:16.4-alpine, awsvpc ENI)
                        │
                        ├── EFS access point (uid/gid 999, 0700)
                        │     └── /postgres  ──mounted at──> /var/lib/postgresql/data
                        │                                     PGDATA = .../pgdata
                        └── Secrets Manager (superuser password)
```

**Key design decisions and why they are non-negotiable:**

| Setting | Value | Reason |
|---|---|---|
| `desired_count` | 1 | Two Postgres processes on one data directory corrupts it |
| `deployment_minimum_healthy_percent` | 0 | Forces old task to stop before replacement starts |
| `deployment_maximum_percent` | 100 | Same — prevents overlapping tasks |
| Container `user` | `999:999` | Entrypoint skips its `chown` step; access point squashes root |
| `PGDATA` | `.../data/pgdata` | `initdb` refuses a directory containing `lost+found` |
| Access point permissions | `0700`, uid/gid 999 | Postgres rejects looser permissions on its data directory |
| Password source | Secrets Manager `secrets` block | Environment variables are readable via `DescribeTaskDefinition` |
| `assign_public_ip` | `false` | Database is never internet-reachable |

---

## 3. Prerequisites

- [ ] Terraform 1.6 or later
- [ ] AWS CLI v2 with a named profile for the target account
- [ ] Session Manager plugin (`winget install --id Amazon.SessionManagerPlugin`)
- [ ] Git credentials for the private `platform-templates` repo
- [ ] S3 state bucket with **versioning enabled**
- [ ] A VPC with private subnets and NAT egress (image pull requires it)

**Set the profile before every Terraform command.** Terraform reads
`AWS_PROFILE`, not `--profile`:

```powershell
$env:AWS_PROFILE = "infra"
aws sts get-caller-identity --profile infra
```

Confirm the account ID matches the target. `InvalidClientTokenId` on any
Terraform command almost always means this variable is unset in the current
window.

---

## 4. Deploy

### 4.1 Confirm state isolation

Before the first apply, verify the backend key does not collide with another
environment:

```powershell
Select-String -Path backend.tf -Pattern "key"
```

Each environment must have its own key. Two directories sharing a key will
each plan to destroy the other's resources.

### 4.2 Initialize and plan

```powershell
cd <environment-directory>
$env:AWS_PROFILE = "infra"

terraform init
terraform plan
```

**Plan review checklist — do not apply until all four pass:**

- [ ] Summary reads `N to add, 0 to change, 0 to destroy`
- [ ] Every resource name carries the expected environment prefix
- [ ] No resource belonging to another environment appears
- [ ] Resource count is roughly as expected (~33 for VPC + cluster + database)

Any `destroy` line on a first apply means the backend key is wrong. Stop.

### 4.3 Apply

```powershell
terraform apply
```

Allow 5–7 minutes. NAT gateway (~2 min) and EFS mount targets are the slow
resources.

### 4.4 Verify

```powershell
aws logs tail /ecs/<name>-postgres --follow --profile infra
```

Success is this line:

```
database system is ready to accept connections
```

That single line confirms the EFS mount succeeded, access point permissions
were accepted, `initdb` completed, and the password was injected.

Then confirm the service is stable:

```powershell
aws ecs describe-services --cluster <cluster> --services <service> `
  --query 'services[0].{running:runningCount,desired:desiredCount,events:events[0:3].message}' `
  --output json --profile infra
```

Expect `running: 1`, `desired: 1`, and `has reached a steady state`.

---

## 5. Connect

No bastion and no public exposure. Access is via `execute-command`.

```powershell
$TASK = aws ecs list-tasks --cluster <cluster> --service-name <service> `
  --query 'taskArns[0]' --output text --profile infra
$TASK

aws ecs execute-command --cluster <cluster> --task $TASK `
  --container postgres --interactive `
  --command "psql -U postgres -d app" --profile infra
```

Print `$TASK` before using it. An empty variable produces
`argument --task: expected one argument`.

**Retrieve the password** (for an application or external client):

```powershell
aws secretsmanager get-secret-value --secret-id <secret-name> `
  --query SecretString --output text --profile infra
```

---

## 6. Verify persistence after a change

Run this after any module change that replaces the task definition. It is the
only way to confirm the data directory survived.

```sql
CREATE TABLE persistence_check (id serial primary key, note text);
INSERT INTO persistence_check (note) VALUES ('before restart');
```

Exit, then force replacement:

```powershell
aws ecs update-service --cluster <cluster> --service <service> `
  --force-new-deployment --profile infra
```

`runningCount` will drop to **0** before the new task starts. This is expected
and correct — it is the single-writer guarantee, not a fault.

Reconnect using the **new** task ID and confirm:

```sql
SELECT * FROM persistence_check;
```

The row must still be present. If the table is missing, the task mounted a
different directory or a fresh file system — stop and investigate before
writing any real data.

---

## 7. Backups

`enable_efs_backup = true` schedules AWS Backup daily. **This is a file-level
copy taken without quiescing the database.** A restore behaves like recovery
from an unclean shutdown; Postgres usually replays its WAL successfully, but
this is not equivalent to a managed snapshot.

For anything you would be unhappy to lose, take logical dumps:

```powershell
aws ecs execute-command --cluster <cluster> --task $TASK `
  --container postgres --interactive `
  --command "pg_dump -U postgres -d app -F c -f /tmp/app.dump" --profile infra
```

`/tmp` inside the container is ephemeral. Either write the dump to the EFS
mount, or run `pg_dump` from a machine with network access to the task.

---

## 8. Teardown

```powershell
$env:AWS_PROFILE = "infra"
terraform destroy
```

Confirm the destroy count matches what was created. **The EFS file system and
all data are deleted.**

If destroy fails on the file system, mount targets are still detaching. Wait
60 seconds and re-run.

**Destroy when not in use.** Approximate `us-east-1` running cost:

| Item | Monthly |
|---|---|
| NAT gateway (hourly, regardless of traffic) | ~$33 |
| Fargate 0.5 vCPU / 2 GB, always on | ~$21 |
| Secrets Manager secret | ~$0.40 |
| EFS, logs, NAT data processing | a few dollars |
| **Total** | **~$55–60** |

The NAT gateway is the largest line and bills whether or not traffic flows.

---

## 9. Troubleshooting

### `chown: /var/lib/postgresql/data/pgdata: Operation not permitted`

Container is running as root. The EFS access point squashes all operations to
uid/gid 999, so root's `chown` fails.

**Fix:** set `user = "999:999"` in the container definition. The official
entrypoint skips its `chown`/`gosu` branch when not running as root.

### `Invalid for_each argument` at plan time

A `for_each` keyed on subnet IDs when the VPC is created in the same apply.
Keys must be known at plan time.

**Fix:** use `count` with `var.subnet_ids[count.index]`.

### `InvalidClientTokenId` on any Terraform command

`AWS_PROFILE` is unset in the current window, or the referenced access key was
deleted.

**Fix:** `$env:AWS_PROFILE = "infra"`, then verify with
`aws sts get-caller-identity --profile infra`. Note the variable does not
persist across windows.

### Task crash-loops with no Postgres output

Check service events first:

```powershell
aws ecs describe-services --cluster <cluster> --services <service> `
  --query 'services[0].events[0:5].message' --output json --profile infra
```

| Event mentions | Cause |
|---|---|
| `CannotPullContainerError` | No NAT egress from the private subnets |
| Timeout mounting EFS | EFS security group missing 2049 from the task SG |
| `ResourceInitializationError` on secrets | Execution role lacks `secretsmanager:GetSecretValue` |

### `TargetNotConnectedError` on execute-command

SSM agent has not registered yet. Wait 30 seconds and retry. If persistent,
confirm `enable_execute_command = true` and that the task role holds the
`ssmmessages:*` permissions.

### `initdb: directory exists but is not empty`

A previous failed run left artifacts in `pgdata`. Delete the directory via a
one-off task with the same mount, or destroy and recreate the file system.

### Container will not start after changing `postgres_image`

A major version bump cannot read an older data directory in place.

**Fix:** `pg_dump` on the old version, destroy, redeploy on the new version,
restore.

---

## 10. Known gaps

**No stable address.** Every task replacement assigns a new private IP. An
application cannot hardcode the address. Requires ECS Service Connect or Cloud
Map, which this module does not yet support — it needs a `service_registries`
block.

**No ingress by default.** `allowed_security_group_ids` is empty, so nothing
reaches port 5432. Pass the application's security group to grant access.

**Password is in Terraform state.** `random_password` results are stored in
plaintext. The state backend must be encrypted with restricted access.

**EFS is not ideal storage for Postgres.** NFS provides weaker `fsync` and
file-locking guarantees than block storage. Adequate at low write volume;
expect poor latency under sustained writes well before correctness problems
appear.

**Burst credits.** `bursting` throughput accrues credits proportional to stored
data. A near-empty database earns few, so write bursts can throttle hard.
Switch to `elastic` if that occurs.

---

## 11. Change log

| Version | Change |
|---|---|
| v0.5.0 | Initial module |
| v0.5.1 | `count` instead of `for_each` for mount targets |
| v0.5.2 | Container runs as `999:999` to avoid `chown` EPERM |
