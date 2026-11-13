# SOP: Git and Terraform Workstation Setup

| | |
|---|---|
| **Owner** | Platform Engineering |
| **Audience** | New engineers joining infrastructure work |
| **Platform** | Windows 10/11, PowerShell 5.1+ |
| **Last updated** | 2026-08-18 |
| **Time required** | 45–60 minutes |

---

## 1. Before you start

You need:

- [ ] A GitHub account with access to the organisation's repositories
- [ ] An AWS account and the ability to create an IAM user, **or** credentials issued to you
- [ ] Local administrator rights (for installers)

---

## 2. Working directory convention

**All repositories live under `C:\dev\`.**

Do not clone into `C:\Users\<name>\`, Documents, Desktop, or any OneDrive-synced
location.

**Reason:** OneDrive holds file locks while syncing. Terraform and Git both
write many small files quickly, and a locked file produces a **silently
truncated or zero-byte write** rather than an error. This has caused real data
loss — files that appear created but contain nothing.

```powershell
New-Item -ItemType Directory -Force -Path C:\dev
```

If OneDrive has redirected your user folders, `C:\Users\<name>\Documents` may be
synced without you having chosen it. When in doubt, use `C:\dev`.

---

## 3. Install tooling

```powershell
winget install --id Git.Git
winget install --id Hashicorp.Terraform
winget install --id Amazon.AWSCLI
winget install --id Amazon.SessionManagerPlugin
winget install --id GitHub.cli
winget install --id Microsoft.VisualStudioCode
```

**Close and reopen PowerShell after installing.** PowerShell reads `PATH` once
at startup, so newly installed commands are not found in an existing window.
"Not recognized as the name of a cmdlet" immediately after an install almost
always means this.

Verify:

```powershell
git --version
terraform version
aws --version
gh --version
```

---

## 4. Configure Git

### 4.1 Identity

```powershell
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
git config --global pull.rebase false
```

### 4.2 Line endings

Windows uses CRLF; Linux CI runners use LF. Without configuration, every file
edited on Windows produces a diff showing every line changed.

```powershell
git config --global core.autocrlf true
```

Additionally, **each repository should carry a `.gitattributes`** so behaviour
does not depend on individual machine settings:

```
* text=auto eol=lf
*.tf text eol=lf
*.md text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
*.sh text eol=lf
*.ps1 text eol=crlf
```

The `warning: LF will be replaced by CRLF` message on `git add` is
informational, not an error.

### 4.3 Authenticate

```powershell
gh auth login
```

Choose **GitHub.com**, **HTTPS**, then authenticate in the browser. This also
configures Git Credential Manager, so `git push` and Terraform's private module
fetches both work without prompting.

Verify:

```powershell
gh auth status
```

---

## 5. Configure AWS credentials

### 5.1 Never use root access keys

Root keys cannot be restricted by any policy, do not appear in most security
tooling, and grant the ability to close the account. If any exist, **delete
them** — do not rotate them.

Console → account menu → **Security credentials** → **Access keys** → Delete.

### 5.2 Create an IAM user key

Create or use an IAM user with appropriate permissions, then generate an access
key. When prompted:

- **Use case:** Command Line Interface (CLI)
- **Description tag:** identify the machine and date, e.g.
  `Local CLI - Windows workstation HOSTNAME - created 2026-08-18`

A description that identifies the machine is what lets you delete a key
confidently later. "my key" or "terraform" does not.

One key per machine. A lost laptop is then one specific key to revoke.

### 5.3 Configure a named profile

**Use named profiles, never the default.** With no default profile, a command
run without `--profile` fails loudly instead of quietly hitting the wrong
account.

```powershell
aws configure --profile <profile-name>
```

Supply: access key ID, secret access key, region (`us-east-1`), output format
(`json`).

**The secret is never echoed and must never be pasted anywhere except this
prompt.** If a secret is exposed — in a chat window, a screenshot, a commit, a
log — delete the key immediately and issue a new one. Rotation is cheap;
assuming nobody noticed is not.

### 5.4 Verify

```powershell
aws sts get-caller-identity --profile <profile-name>
```

Confirm the account ID is correct and the ARN shows an IAM **user**, not
`:root`. If multiple accounts are in play, check this before every session —
the same command run against the wrong account is how orphaned resources
happen.

### 5.5 Terraform reads AWS_PROFILE

Terraform ignores `--profile`. Set the environment variable:

```powershell
$env:AWS_PROFILE = "<profile-name>"
```

**This does not persist across windows.** `InvalidClientTokenId` from any
Terraform command is nearly always this variable being unset in a new window.

To set it permanently:

```powershell
notepad $PROFILE
```

Add `$env:AWS_PROFILE = "<profile-name>"` and save. Be aware this makes that
profile the default for every AWS command in every window, which removes the
protection of having to state the account explicitly.

---

## 6. Repository conventions

### 6.1 Separation of concerns

| Repository | Contains |
|---|---|
| `terraform-projects` | Environment configurations — the deployed stacks |
| `platform-templates` | Reusable, versioned Terraform modules |
| `team-runbooks` | Documentation, SOPs, operational procedure |

Keep documentation out of infrastructure repositories. A doc edit should never
trigger an infrastructure pipeline.

### 6.2 Every Terraform repository needs this `.gitignore`

```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!example.tfvars
.terraform.lock.hcl
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
```

**Why each matters:**

- `*.tfstate` — contains every resource attribute in plaintext, including
  generated passwords. Committing state is a credential leak.
- `*.tfvars` — typically holds environment-specific and sensitive values.
- `.terraform/` — downloaded providers and modules; large and machine-specific.
- `.terraform.lock.hcl` — **exclude in module repositories** (the caller pins
  versions), **include in environment repositories** (reproducible provider
  versions).

Add `.gitignore` in the **first commit**, before any `terraform init`. A state
file committed once remains in history even after deletion.

### 6.3 Verify writes before committing

Because of the silent-write failure mode described in section 2:

```powershell
Get-ChildItem -Recurse -File | Select-Object FullName, Length
```

Any unexpected `Length 0` means the write did not land.

---

## 7. Terraform: remote state

**Never use local state for shared infrastructure.** Local state cannot be
shared, has no locking, and is lost with the machine.

```hcl
terraform {
  backend "s3" {
    bucket       = "<state-bucket>"
    key          = "<environment>/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
```

**Requirements on the bucket:**

- [ ] **Versioning enabled** — this is the only recovery path if state is
      corrupted or truncated. Without it, recovery means `terraform import` for
      every resource, one at a time.
- [ ] Encryption enabled
- [ ] Public access blocked

```powershell
aws s3api get-bucket-versioning --bucket <state-bucket> --profile <profile>
aws s3api put-bucket-versioning --bucket <state-bucket> `
  --versioning-configuration Status=Enabled --profile <profile>
```

`use_lockfile = true` prevents two concurrent applies, which is the classic
state-corruption path.

### 7.1 One state key per environment

Each environment gets its own `key`. This is what isolates environments — not
the directory name, not the repository.

Two configurations sharing a key will each plan to destroy the other's
resources.

**Before the first apply in any new environment, confirm the key:**

```powershell
Select-String -Path backend.tf -Pattern "key"
```

---

## 8. Terraform: module versioning

Modules are consumed by Git reference and **must be pinned to a tag**:

```hcl
module "vpc" {
  source = "git::https://github.com/<org>/platform-templates.git//modules/vpc?ref=v0.3.0"
  # ...
}
```

Never track `main`. A caller on `main` picks up whatever was pushed last,
including unfinished work.

**Publishing a module version:**

```powershell
terraform validate
git add -A
git commit -m "feat: <description>"
git push
git tag -a v0.3.0 -m "<description>"
git push origin v0.3.0
```

**Tag immutability.** Before anything consumes a version, a mistagged release
can be moved. Once a caller has pinned it, cut a new patch version instead —
moving a tag silently changes code for anyone who already fetched it.

Module `source` cannot use variables. Version bumps are literal edits, then:

```powershell
terraform init -upgrade
```

Check the init output states the expected ref. A stale ref is a common cause of
"I fixed that already" confusion.

---

## 9. Daily workflow

```powershell
cd C:\dev\<repo>
$env:AWS_PROFILE = "<profile>"

git pull
git checkout -b <branch-name>

# make changes

terraform fmt
terraform validate
terraform plan
```

### 9.1 Plan review is the safety mechanism

`terraform plan` never modifies infrastructure. Reading it carefully is what
prevents bad outcomes.

**Stop and investigate if the plan shows:**

- Any `destroy` on a resource you intended to keep
- `must be replaced` on a stateful resource (database, volume, subnet with
  dependents)
- Resources belonging to a different environment
- A resource count far from expectation

A rename in configuration reads as destroy-and-recreate. Use a `moved` block or
`terraform state mv` to preserve the resource instead.

### 9.2 Commit and open a pull request

```powershell
git add -A
git status
git commit -m "feat: <description>"
git push -u origin <branch-name>
gh pr create --fill
```

Review `git status` before committing. Nothing under `.terraform/` and no
`.tfstate` or `.tfvars` file should appear.

---

## 10. Troubleshooting

### `not a git repository`

You are outside the repository. `cd` into the cloned directory. To run Git
against a repo from elsewhere: `git -C C:\dev\<repo> status`.

### `'gh' is not recognized` (or `terraform`, `aws`) after installing

`PATH` is stale in the current window. Close and reopen PowerShell.

### `Repository not found` on push to a private repository

GitHub returns this both when a repository does not exist and when credentials
lack access. Check in order:

1. Open the URL in a browser — a 404 while signed in means it was never created
2. `git remote -v` — verify the URL character by character
3. `gh auth status` — confirm authentication

### `InvalidClientTokenId` from Terraform

`AWS_PROFILE` unset in this window, or the referenced key was deleted. Set the
variable and verify with `aws sts get-caller-identity`.

### Credentials point at the wrong account

```powershell
aws configure list
aws sts get-caller-identity --profile <profile>
```

Remove any `[default]` block from `%USERPROFILE%\.aws\credentials` so
unqualified commands fail rather than silently targeting the wrong account.

### Files created but empty, or edits that disappear

Almost certainly the OneDrive lock described in section 2. Move the repository
to `C:\dev\` and verify with
`Get-ChildItem -Recurse -File | Select-Object FullName, Length`.

### Diff shows every line changed on a file you barely edited

Line-ending conversion. Add `.gitattributes` per section 4.2.

### `terraform init` fails on a private module

Git credentials are not configured for the module repository. Run
`gh auth login`, then confirm with `git ls-remote <module-repo-url>`.

---

## 11. Checklist

- [ ] `C:\dev\` created, no repositories under OneDrive-synced paths
- [ ] Git, Terraform, AWS CLI, Session Manager plugin, `gh` all installed and
      on `PATH`
- [ ] Git identity and line-ending configuration set
- [ ] `gh auth status` reports authenticated
- [ ] No root access keys exist in any account
- [ ] Named AWS profile configured; `[default]` removed
- [ ] `aws sts get-caller-identity` shows the correct account and an IAM user
- [ ] `AWS_PROFILE` set in the working session
- [ ] State bucket has versioning enabled
- [ ] `.gitignore` present before the first `terraform init`
- [ ] Module sources pinned to tags, not `main`
