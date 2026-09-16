# Dependency Automation

> Surface type: background job (GitHub Actions workflow plus Dependabot configuration)
> Address: `.github/dependabot.yml`, and workflow `Dependabot auto-merge` in `.github/workflows/dependabot-automerge.yml`
> Schedule: Dependabot checks weekly; the automerge workflow runs on every pull request
> Consumed by: Dependabot, and GitHub's merge machinery
> Auth or permissions: `contents: write`, `pull-requests: write`. Workflows triggered by Dependabot receive a read-only token by default, which this block lifts.

## Overview

Keeps GitHub Actions current without requiring anyone to approve pull requests. Updates are
grouped into a single pull request and merged automatically once the build check passes.

The scope is narrow by necessity. Dependabot has no ecosystem that can read a `git clone` inside a
Dockerfile `RUN` line, so it cannot see either upstream project; those are handled by the watcher.
The base image tag carries no version to bump. Actions are the only dependency here Dependabot can
meaningfully track, and they are also where the rot was: every action was behind, several by four
major versions, which is the most likely cause of the SARIF upload failing from 2026-04 onward.

## Structure

```
.github/dependabot.yml
  package-ecosystem: github-actions      the only ecosystem that applies here
  schedule: weekly
  groups: { actions: { patterns: ["*"] } }   one PR for all action bumps

.github/workflows/dependabot-automerge.yml
  on: pull_request
  if: github.actor == 'dependabot[bot]'
  dependabot/fetch-metadata@v3
  gh pr merge --auto --squash
```

## Fields

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `package-ecosystem` | Dependabot config | Yes | `github-actions` | The only applicable ecosystem. See Overview |
| `schedule.interval` | Dependabot config | Yes | `weekly` | Enough for actions, which move slowly |
| `groups.actions.patterns` | Dependabot config | No | `["*"]` | Collapses all bumps into one pull request |
| `GH_TOKEN` | secret | Yes | `GITHUB_TOKEN` | Used by `gh pr merge` |
| `PR_URL` | env | Yes | from the event | Passed through `env:` rather than interpolated into the shell |

## Runs

### Weekly update

- Trigger: Dependabot's weekly schedule.
- Behavior: one grouped pull request for all outdated actions.
- Then: the automerge workflow enables auto-merge, the build check runs, and the pull request
  merges itself once the check passes.
- Operator involvement: none.

### An update that breaks the build

- Behavior: the build check fails, so auto-merge never completes and the pull request stays open.
- This is the intended outcome and the reason the gate exists.

### A non-Dependabot pull request

- Behavior: the `github.actor` condition is false and the job does not run. Auto-merge is never
  enabled for human pull requests.

### Security note

The workflow uses `on: pull_request`, not `pull_request_target`, so a pull request from a fork
receives a read-only token and cannot merge itself. All event data reaches the shell through
`env:` rather than direct interpolation, which is what prevents script injection from
attacker-controlled fields.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| `dependabot/fetch-metadata@v3` | GitHub Action | Reads update metadata | Job fails; pull request stays open |
| `gh` CLI | Runner tool | Enables auto-merge | Pull request stays open |
| `build` check from `build-check.yml` | Required status check | The safety gate | **Without it, pull requests merge immediately, unreviewed** |
| `allow_auto_merge` repository setting | Repository setting | Prerequisite for `--auto` | `gh pr merge --auto` fails |

## Relationships

- Gated by: [23-ci-build-check.md](./23-ci-build-check.md).
- Maintains: the action versions used by every workflow in this repository.
- Complements: [20-ci-upstream-watcher.md](./20-ci-upstream-watcher.md), which covers what
  Dependabot structurally cannot see.

## Business Rules

1. Dependabot tracks GitHub Actions only, grouped, auto-merged, and this is safe only because the
   build check is required. See [BL-CI-011](../../BUSINESS-LOGIC.md#bl-ci-011).
2. Given a pull request not opened by Dependabot, when the workflow runs, then it takes no action.
   (`.github/workflows/dependabot-automerge.yml`, the `if` condition)
3. Given `allow_auto_merge` disabled on the repository, then `gh pr merge --auto` fails and
   nothing merges. (repository setting, not visible in this checkout)
4. Event data is passed through `env:`, never interpolated into a `run:` block.
   (`.github/workflows/dependabot-automerge.yml`, the `Enable auto-merge` step)
