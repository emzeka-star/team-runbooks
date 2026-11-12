# SOP: Pushing Changes to Git

**Environment:** Windows 11, PowerShell 5.1, VS Code
**Repositories:** cloned under `C:\dev\` (never OneDrive-synced paths)
**Remote:** GitHub, account `emzeka-star`, private repositories
**Last updated:** 2026-09-08

---

## 1. Purpose and scope

The routine for getting local changes into a GitHub repository, plus recovery steps for
the failures that come up most often. Covers both direct-to-`main` pushes (acceptable
for solo runbook and documentation repos) and branch-plus-PR (preferred once anyone
else is working in the same repo).

**Related:** `SOP-git-terraform-setup.md` covers first-time Git and Terraform
installation and configuration. This SOP assumes that setup is already done. If the two
documents disagree, the setup SOP is authoritative on installation and this one on
day-to-day workflow.

---

## 2. Prerequisites

| Requirement | Check |
|---|---|
| Git installed | `git --version` |
| Identity configured | `git config --global user.name` and `git config --global user.email` |
| Credential helper configured | `git config --global credential.helper` → expect `manager` |

If identity is unset, commits are rejected or attributed to the wrong author:

```powershell
git config --global user.name "Esther Mzeka"
git config --global user.email "emzeka@oasisfactory.com"
```

Authentication to private repos over HTTPS uses Git Credential Manager, which prompts
in a browser window on first push and caches thereafter. If you are ever prompted for a
password in the terminal, that is not your GitHub account password — GitHub removed
password authentication. Use a personal access token, or let Credential Manager handle
the browser flow.

---

## 3. Before you commit anything: check `.gitignore`

**Do this once per Terraform repository, before the first commit.** Terraform working
directories contain files that must never reach a remote, including a private one.

Confirm the repo has a `.gitignore` containing at minimum:

```
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
tfplan
.venv/
```

Two of these matter more than the rest:

- **`*.tfstate`** — state files contain resource attributes in plaintext, including
  generated passwords, connection strings, and secret values. A committed state file is
  a credential leak.
- **`*.tfvars`** — where secrets get passed in. Commit `.tfvars.example` with dummy
  values instead if the variables need documenting.

`.terraform.lock.hcl` is a genuine judgment call: commit it when you want provider
versions pinned identically across machines and CI, ignore it when you don't. Pick one
per repo and be consistent.

Check what would be committed before your first `git add`:

```powershell
git status --ignored
```

If a `.tfstate` file appears under tracked or untracked rather than ignored, fix
`.gitignore` before going further. See section 8 if one has already been committed.

---

## 4. Line endings

Windows checkouts default to CRLF. Terraform files tolerate it; shell scripts destined
for Linux instances do not — `#!/bin/bash^M` fails on the target with no useful error.

Add to the repo root `.gitattributes`:

```
* text=auto
*.sh text eol=lf
*.tf text eol=lf
```

Commit it like any other file. It applies from that point forward; already-committed
files keep their existing endings until rewritten.

---

## 5. The standard workflow

Run from the repository root.

### Step 1 — See where you are

```powershell
cd C:\dev\<repo-name>
git status
```

Read this before anything else. It tells you the current branch, whether the tree is
clean, and which files are modified, staged, or untracked.

### Step 2 — Pull first

```powershell
git pull
```

Pulling before you commit is cheaper than resolving a rejected push afterwards. If the
tree has uncommitted changes and the pull touches the same files, Git will refuse —
commit or stash first (`git stash`, then `git stash pop` after the pull).

### Step 3 — Review what changed

```powershell
git diff
```

For a file-name-only summary:

```powershell
git status --short
```

Never skip this on a repo containing infrastructure code. It is the last checkpoint
before a hardcoded account ID, password, or ARN becomes part of the permanent history.

### Step 4 — Stage

Specific files, which is the safer default:

```powershell
git add SOP-ec2-asg-deployment.md
```

Everything, once `.gitignore` is known good:

```powershell
git add .
```

Verify what is staged:

```powershell
git status
```

To unstage without losing the edit: `git restore --staged <file>`.

### Step 5 — Commit

```powershell
git commit -m "Add SOP for EC2 deployment via ec2-asg module"
```

Message conventions: imperative mood ("Add", "Fix", "Update", not "Added" or "Adding"),
under about 70 characters, describing *what changed and why* rather than restating the
filename. `git commit` with no `-m` opens an editor for a longer body when one
sentence is not enough.

One logical change per commit. Bundling an unrelated fix into a documentation commit
makes both harder to revert later.

### Step 6 — Push

```powershell
git push
```

First push of a new local branch needs the upstream set:

```powershell
git push -u origin <branch-name>
```

### Step 7 — Confirm

```powershell
git log --oneline -3
git status
```

`git status` should report the branch up to date with `origin/<branch>` and a clean
tree. Anything else means the push did not fully land.

---

## 6. Branch and pull request workflow

Use this once anyone else works in the repo, or for changes you want reviewed before
they hit `main`.

```powershell
git checkout main
git pull
git checkout -b docs/ec2-asg-sop
# ... make changes ...
git add .
git commit -m "Add SOP for EC2 deployment via ec2-asg module"
git push -u origin docs/ec2-asg-sop
```

The push output includes a URL for opening the pull request. After it merges:

```powershell
git checkout main
git pull
git branch -d docs/ec2-asg-sop
```

Branch naming: `docs/`, `feat/`, `fix/`, `chore/` prefix plus a short hyphenated
description.

---

## 7. Working through VS Code instead

The Source Control panel (`Ctrl+Shift+G`) covers the same workflow: `+` to stage,
message box plus `Ctrl+Enter` to commit, sync button to push. Clicking a modified file
opens a side-by-side diff, which is easier to review carefully than terminal output.

Mixing VS Code and the terminal in the same repo is fine — they operate on the same
Git state. Use whichever suits the step: VS Code for reviewing diffs, terminal for
anything involving rebase or history rewriting.

---

## 8. Recovery from common failures

### Push rejected — "Updates were rejected because the remote contains work that you do not have locally"

Someone pushed since your last pull, or you pushed from another machine.

```powershell
git pull --rebase
git push
```

`--rebase` replays your commits on top of the remote history rather than creating a
merge commit. If conflicts surface, resolve them, then `git add <file>` and
`git rebase --continue`. To back out entirely: `git rebase --abort`.

### Wrong commit message, not yet pushed

```powershell
git commit --amend -m "Corrected message"
```

**Only before pushing.** Amending an already-pushed commit rewrites history and
requires a force push, which is disruptive on any shared branch.

### Forgot a file in the last commit, not yet pushed

```powershell
git add <forgotten-file>
git commit --amend --no-edit
```

### Committed something that should be ignored

Remove from tracking, keep the local file:

```powershell
git rm --cached <file>
```

Add the pattern to `.gitignore`, then commit both changes. Note this only stops future
tracking — the file's contents remain in history.

### Committed a secret or a state file

Treat the secret as compromised regardless of what you do to the history. Rotate it
first: new password, new access key, new token. Removing it from Git history does not
un-expose it, and rewriting history on a pushed branch is invasive.

For state files specifically, rotate every credential the state contained, then remove
the file from tracking per above.

### Merge conflict

Git marks conflicting regions in the affected files. Open each, choose the correct
content, delete the `<<<<<<<`, `=======`, and `>>>>>>>` markers, then:

```powershell
git add <resolved-file>
git commit
```

VS Code's merge editor handles this more comfortably than editing markers by hand.

### Discard local changes to a file

```powershell
git restore <file>
```

Irreversible — the edit is gone.

### "Detached HEAD"

You checked out a commit rather than a branch. Return with:

```powershell
git checkout main
```

Any commits made while detached are not on a branch; `git log --oneline` before
switching if you need their hashes.

### File too large

GitHub rejects files over 100 MB and warns above 50 MB. Terraform provider binaries
under `.terraform/` are the usual cause — confirm `.gitignore` covers it. If such a
file is already committed, it must be removed from history before the push will
succeed.

---

## 9. Quick reference

```powershell
git status                      # where am I, what changed
git pull                        # get remote changes first
git diff                        # review before staging
git add <file>                  # stage specific file
git commit -m "message"         # commit staged changes
git push                        # send to remote
git log --oneline -5            # recent history
git restore --staged <file>     # unstage, keep edit
git restore <file>              # discard edit (irreversible)
git stash / git stash pop       # park changes temporarily
git checkout -b <branch>        # new branch
```

---

## 10. Habits worth keeping

- `git status` before and after every operation until the workflow is automatic.
- Pull before starting work, not just before pushing.
- Commit at logical checkpoints rather than at end of day — small commits are far
  easier to review and revert.
- Never `git add .` in a repo whose `.gitignore` you have not read.
- Never force push to `main`.
- Push at end of session. Uncommitted work on one machine is invisible from anywhere
  else and unprotected against local disk failure.
