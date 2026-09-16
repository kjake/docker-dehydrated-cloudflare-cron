# Upstream Watcher

> Surface type: background job (GitHub Actions workflow)
> Address: workflow `Watch upstreams`, file `.github/workflows/watch-upstream.yml`
> Schedule: `0 */12 * * *` (every 12 hours UTC), plus `workflow_dispatch`
> Consumed by: the GitHub Actions scheduler. It in turn calls the publish workflow.
> Auth or permissions: `contents: write`, to commit the state file and the keepalive. Docker Hub secrets reach the publish job via `secrets: inherit`.

## Overview

This is the mechanism that keeps the published image current, and the reason nothing in this
repository needs pinning. Everything the image contains is cloned or pulled unpinned at build
time, so without something watching, the repository has no idea whether `latest` is fresh or
years stale.

It replaced a blind weekly rebuild. That design had three faults: it rebuilt whether or not
anything had changed, it recorded nothing about what it produced, and being schedule-driven in a
quiet repository it was eventually disabled by GitHub for inactivity, which froze the published
image for roughly 4.5 months while critical CVEs accumulated. This workflow addresses all three.

## Pipeline

```
check       resolve three upstream identities, compare to recorded state
  |
  +-- changed --> publish (reusable workflow)  --> record  (commit state file)
  |
  +-- unchanged -------------------------------> heartbeat (empty commit if quiet 50 days)
```

The three identities are deliberately heterogeneous, because the upstreams are:

| Input | Identity used | Why |
|---|---|---|
| `dehydrated-io/dehydrated` | default-branch commit sha, branch `master` | The Dockerfile clones the default branch. Its latest release is far older, so release tracking would misrepresent what is shipped |
| `SeattleDevs/letsencrypt-cloudflare-hook` | default-branch commit sha, branch `main` | The project publishes no releases at all, so commit tracking is the only option |
| `python:alpine` | manifest digest | The tag carries no version to compare |

The two upstreams use different default branch names. Neither is assumed.

## Variables

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `STATE_FILE` | workflow env | Yes | `.upstream-state.json` | Recorded state |
| `STATE_BRANCH` | workflow env | Yes | `upstream-state` | Branch the state file lives on, kept off the protected default branch |
| `GITHUB_TOKEN` | secret | Yes | provided | Used by `gh api` for the two commit lookups and for pushing |
| `DOCKER_USERNAME`, `DOCKER_PASSWORD` | secrets | Yes, for publishing | none | Not read here; inherited by the publish job |

Job outputs, consumed by the publish and record jobs:

| Output | Meaning |
|---|---|
| `changed` | `true` when the composite key differs from the recorded one |
| `dehydrated_revision`, `hook_revision`, `base_digest` | The three identities, passed to the build as args and recorded as labels |
| `python_version` | Used to detect and announce a base image Python change |
| `state_key` | First 12 hex characters of the SHA-256 of the three identities; becomes the immutable image tag |

## Runs

### Scheduled check, nothing changed

- Trigger: the 12 hour cron.
- Behavior: resolves the three identities, computes the composite key, finds it equal to the
  recorded one, and stops. No build, no publish.
- Output: `changed=false`. The heartbeat job then evaluates repository quietness.
- Cost: two API calls, one manifest inspection, and one small image pull.

### Scheduled check, upstream moved

- Trigger: any of the three identities differs.
- Behavior: the publish workflow is called with the three identities and the composite key. On
  success, the state file is rewritten and committed.
- Ordering: state is recorded **only after** a successful publish. Recording earlier would mark a
  failed build as done and skip the retry. See
  [BL-CI-010](../../BUSINESS-LOGIC.md#bl-ci-010).
- No race with the default branch: state is written to a dedicated `upstream-state` branch,
  so a build running while `main` moves cannot conflict.

### Base image Python version changed

- Trigger: the resolved Python version differs from the recorded one.
- Behavior: emits a `::notice::` naming both versions, then proceeds with the rebuild as normal.
- Why it is a notice and not a gate: the base image floats by choice, so a major jump is expected
  to land. This makes it visible after the fact rather than silent.

### First run, no state file

- Behavior: treated as changed, so the first run always publishes and establishes the baseline.

### Quiet repository

- Trigger: no upstream movement, and the last commit is at least 50 days old.
- Behavior: pushes an empty commit.
- Why: GitHub disables scheduled workflows in public repositories after 60 days without
  repository activity. Without this, a long quiet period disables the very workflow that would
  otherwise rebuild the image, which is exactly how this repository's CI died. See
  [BL-CI-013](../../BUSINESS-LOGIC.md#bl-ci-013).
- Note: the threshold is 50 rather than 59 to leave room for missed runs.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| GitHub API | Network service | Resolving both upstream commits | Job fails; next run retries |
| Docker Hub registry | Network service | Reading the `python:alpine` manifest digest | Job fails; next run retries |
| `.github/workflows/docker.yml` | Reusable workflow | Performs the actual build and push | State is not recorded, so the next run retries |
| `jq`, `sha256sum`, `gh` | Runner tools | State handling and API access | Preinstalled on `ubuntu-latest` |
| Write access to `upstream-state` | Repository permission | State commit and keepalive | Without it the watcher rebuilds repeatedly, never recording success |

## Relationships

- Calls: [21-ci-image-publish.md](./21-ci-image-publish.md).
- Watches: the two upstream projects and the base image listed in
  [01-container-image.md](./01-container-image.md).
- Writes: `.upstream-state.json`, described in
  [data-dictionary.md](../appendix/data-dictionary.md).
- Protects: itself, via the heartbeat.

## Business Rules

1. A rebuild happens when any of three upstream identities changes, checked every 12 hours. See
   [BL-CI-009](../../BUSINESS-LOGIC.md#bl-ci-009).
2. State is recorded only after a successful publish. See
   [BL-CI-010](../../BUSINESS-LOGIC.md#bl-ci-010).
3. The repository must not go 60 days without a commit, or the schedule is disabled. See
   [BL-CI-013](../../BUSINESS-LOGIC.md#bl-ci-013).
4. Given no state file, when the watcher runs, then it treats the state as changed and publishes.
   (`.github/workflows/watch-upstream.yml`, the `compare` step)
5. Given a Python version change in the base image, when the watcher runs, then it emits a notice
   naming both versions. (`.github/workflows/watch-upstream.yml`, the `compare` step)
