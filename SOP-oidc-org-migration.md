# OIDC trust policy cutover for the org migration

## Why this is needed

The `github-actions-role` trust policy matches on the OIDC token's `sub`
claim, which embeds the full repository path:

```
repo:emzeka-star/terraform-projects:ref:refs/heads/main
```

After a transfer to an organisation, GitHub issues tokens with the new path.
The old condition no longer matches and every workflow fails with:

```
Error: Could not assume role with OIDC: Not authorized to perform
sts:AssumeRoleWithWebIdentity
```

The message names neither the repository nor the condition, which makes it a
slow diagnosis if you meet it unexpectedly.

Adding the org path in advance means both work simultaneously. Nothing breaks
at the moment of transfer, and the old entries can be removed afterwards at
leisure.

## Current state

Role: `github-actions-role` in account `288743750008`

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": [
    "repo:emzeka-star/terraform-projects:ref:refs/heads/main",
    "repo:emzeka-star/terraform-projects:environment:production"
  ]
}
```

Two entries: one for pushes to `main`, one for jobs running against the
`production` GitHub environment. Both need an org equivalent.

## Procedure

### 1. Back up the current policy

```powershell
aws iam get-role --role-name github-actions-role --profile infra `
  --query 'Role.AssumeRolePolicyDocument' --output json > trust-backup.json
```

Keep this until the migration is confirmed working. Restoring is
`update-assume-role-policy` with this file.

### 2. Substitute the org slug

`trust-policy-new.json` contains `REPLACE_ORG` in two places. Replace with the
actual GitHub org slug — the URL segment, lowercase:

```powershell
(Get-Content trust-policy-new.json) -replace 'REPLACE_ORG', '<org-slug>' |
  Set-Content trust-policy-new.json -Encoding utf8

Get-Content trust-policy-new.json
```

Read it back before applying. A typo in the org name produces a policy that
applies cleanly and then silently fails to match — the same failure mode as
the stray space in the repo name during the original setup.

### 3. Apply

```powershell
aws iam update-assume-role-policy --role-name github-actions-role `
  --policy-document file://trust-policy-new.json --profile infra
```

`file://` matters. Inline JSON on Windows requires escaping every quote and is
a reliable source of malformed-policy errors.

Note this command *replaces* the whole trust document rather than merging, so
the file must contain the old entries as well as the new ones.

### 4. Verify

```powershell
aws iam get-role --role-name github-actions-role --profile infra `
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

Four `sub` entries, spelled exactly as expected.

### 5. Confirm the existing pipeline still works

Trigger a workflow run before the migration. A successful run proves the added
entries did not disturb the working ones — which is the actual risk in this
change, since `update-assume-role-policy` overwrites rather than appends.

## After the transfer

Run the pipeline once from the org repo and confirm it authenticates. Then drop
the personal-account entries:

```powershell
# Edit trust-policy-new.json to remove the two emzeka-star lines, then
aws iam update-assume-role-policy --role-name github-actions-role `
  --policy-document file://trust-policy-new.json --profile infra
```

Leaving them costs nothing functionally, but they are stale trust — a repo of
that name recreated under the personal account would be able to assume the
role.

## Other repos

Each repository that assumes this role needs its own `sub` entries. Currently
only `terraform-projects` has a workflow.

If `platform-templates` or `ecs-lab` gain pipelines later, add them
explicitly rather than reaching for a wildcard:

```json
"repo:<org>/platform-templates:ref:refs/heads/main"
```

An org-wide wildcard is available:

```json
"repo:<org>/*:*"
```

It also means any repository any member creates can assume the role, including
one created next month by someone who has not thought about it. For a small
team standing up its first shared AWS account, explicit entries are worth the
maintenance.

## Related items the transfer also affects

**Actions secrets do not transfer.** Inventory the names now:

```powershell
# Repo settings > Secrets and variables > Actions
```

Fully OIDC-based pipelines may have none, which is the payoff for that work.

**Branch protection rules need recreating** in the org.

**Module source URLs** in `.tf` files still reference `emzeka-star`. GitHub
redirects transferred repositories so these keep resolving, but the redirect
is a dependency worth removing:

```powershell
Get-ChildItem C:\dev -Recurse -Filter *.tf -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\\.terraform\\' } |
  Select-String 'emzeka-star'
```

**The OIDC provider itself** does not change. It is account-scoped, not
repo-scoped, so no action needed there.
