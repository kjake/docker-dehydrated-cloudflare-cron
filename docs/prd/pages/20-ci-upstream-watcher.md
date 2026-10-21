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
check       resolve four upstream identities, compare to recorded state
  |
  +-- changed --> publish (reusable workflow)  --> record  (commit state file)
  |
  +-- unchanged -------------------------------> heartbeat (empty commit if quiet 50 days)
```

The four identities are deliberately heterogeneous, because the upstreams are:

| Input | Identity used | Why |
|---|---|---|
| `dehydrated-io/dehydrated` | default-branch commit sha, branch `master` | The Dockerfile clones the default branch. Its latest release is far older, so release tracking would misrepresent what is shipped |
| `SeattleDevs/letsencrypt-cloudflare-hook` | default-branch commit sha, branch `main` | The project publishes no releases at all, so commit tracking is the only option |
| `cgr.dev/chainguard/wolfi-base` | manifest digest | Referenced by bare name, with no version to compare |
| Wolfi packages | `packages_digest`: first 12 hex characters of the SHA-256 of the sorted `apk info -v` list after installing `RUNTIME_PACKAGES` into the base image at the resolved digest | Wolfi ships CVE fixes as package updates that need not move the base image digest |

The two upstreams use different default branch names. Neither is assumed.

## Variables

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `STATE_FILE` | workflow env | Yes | `.upstream-state.json` | Recorded state |
| `STATE_BRANCH` | workflow env | Yes | `upstream-state` | Branch the state file lives on, kept off the protected default branch |
| `BASE_IMAGE` | workflow env | Yes | `cgr.dev/chainguard/wolfi-base` | `.github/workflows/watch-upstream.yml:38`. Must match the `Dockerfile` `FROM` |
| `RUNTIME_PACKAGES` | workflow env | Yes | `curl openssl bash python-3 py3-pip supercronic tzdata` | `.github/workflows/watch-upstream.yml:42`. Must match the `Dockerfile` `apk add` minus `git`. Nothing enforces this |
| `GITHUB_TOKEN` | secret | Yes | provided | Used by `gh api` for the two commit lookups and for pushing |
| `DOCKER_USERNAME`, `DOCKER_PASSWORD` | secrets | Yes, for publishing | none | Not read here; inherited by the publish job |

Job outputs, consumed by the publish and record jobs:

| Output | Meaning |
|---|---|
| `changed` | `true` when the composite key differs from the recorded one |
| `dehydrated_revision`, `hook_revision`, `base_digest` | Three of the identities, passed to the build as args and recorded as labels |
| `packages_digest` | The fourth identity. Recorded in the state file and folded into `state_key`, but not passed to the build or recorded as a label |
| `python_version` | `3.<minor>`, parsed from the resolved `python-3.x` package name. Used only to announce a change; the job fails if no such package is found |
| `state_key` | First 12 hex characters of the SHA-256 of the four identities; becomes the immutable image tag |

## Runs

### Scheduled check, nothing changed

- Trigger: the 12 hour cron.
- Behavior: resolves the four identities, computes the composite key, finds it equal to the
  recorded one, and stops. No build, no publish.
- Output: `changed=false`. The heartbeat job then evaluates repository quietness.
- Cost: two API calls, one manifest inspection, one base image pull, and one throwaway
  `apk add` of the runtime packages.

### Scheduled check, upstream moved

- Trigger: any of the four identities differs.
- Behavior: the publish workflow is called with the first three identities and the composite key. On
  success, the state file is rewritten and committed.
- Ordering: state is recorded **only after** a successful publish. Recording earlier would mark a
  failed build as done and skip the retry. See
  [BL-CI-016](../../BUSINESS-LOGIC.md#bl-ci-016).
- No race with the default branch: state is written to a dedicated `upstream-state` branch,
  so a build running while `main` moves cannot conflict.

### Wolfi Python version changed

- Trigger: the Python minor version of the resolved `python-3.x` package differs from the recorded
  one (`.github/workflows/watch-upstream.yml:123-125`).
- Behavior: emits a `::notice::` naming both versions, then proceeds with the rebuild as normal.
- Why it is a notice and not a gate: the packages float by choice, so a major jump is expected
  to land. This makes it visible after the fact rather than silent.

### First run, no state file

- Behavior: treated as changed, so the first run always publishes and establishes the baseline.

### First run after the wolfi-base move

- Behavior: the recorded key was computed from three inputs and the new key from four, so they
  cannot match. The run is treated as changed and publishes, which re-establishes the baseline.

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
| `cgr.dev` registry | Network service | Reading the `wolfi-base` manifest digest and pulling it | Job fails; next run retries |
| Wolfi package repository | Network service | Resolving `RUNTIME_PACKAGES` for `packages_digest` | Job fails; next run retries |
| `.github/workflows/docker.yml` | Reusable workflow | Performs the actual build and push | State is not recorded, so the next run retries |
| `jq`, `sha256sum`, `gh`, `docker` | Runner tools | State handling and API access | Preinstalled on `ubuntu-latest` |
| Write access to `upstream-state` | Repository permission | State commit and keepalive | Without it the watcher rebuilds repeatedly, never recording success |

## Relationships

- Calls: [21-ci-image-publish.md](./21-ci-image-publish.md).
- Watches: the two upstream projects, the base image, and its runtime packages, listed in
  [01-container-image.md](./01-container-image.md).
- Writes: `.upstream-state.json`, described in
  [data-dictionary.md](../appendix/data-dictionary.md).
- Protects: itself, via the heartbeat.

## Business Rules

1. A rebuild happens when any of four upstream identities changes, checked every 12 hours. See
   [BL-CI-015](../../BUSINESS-LOGIC.md#bl-ci-015).
2. State is recorded only after a successful publish. See
   [BL-CI-016](../../BUSINESS-LOGIC.md#bl-ci-016).
3. The repository must not go 60 days without a commit, or the schedule is disabled. See
   [BL-CI-013](../../BUSINESS-LOGIC.md#bl-ci-013).
4. Given no state file, when the watcher runs, then it treats the state as changed and publishes.
   (`.github/workflows/watch-upstream.yml:111-119`, the `compare` step)
5. Given a Python version change in the resolved Wolfi packages, when the watcher runs, then it emits a notice
   naming both versions. (`.github/workflows/watch-upstream.yml:123-125`, the `compare` step)
6. Given a resolved package set with no `python-3.x` package, when the watcher runs, then the
   `check` job fails and nothing is published. (`.github/workflows/watch-upstream.yml:79-82`)
7. Given only a Wolfi package update with an unchanged base image digest, when the watcher runs,
   then `packages_digest` changes, so the key changes and the image is rebuilt. See
   [BL-CI-015](../../BUSINESS-LOGIC.md#bl-ci-015).
