# Image Publish Pipeline

> Surface type: background job (GitHub Actions workflow)
> Address: workflow `Docker`, job `push`, file `.github/workflows/docker.yml`
> Triggers: called by the upstream watcher, plus every push to `main` (excluding docs and state), plus `workflow_dispatch`
> Consumed by: the watcher, the `main` branch, and every operator who pulls the image
> Auth or permissions: `contents: read`. Docker Hub credentials from the `DOCKER_USERNAME` and `DOCKER_PASSWORD` secrets, reaching this workflow via `secrets: inherit` when called.

## Overview

Builds and publishes the multi-platform image. This is how the repository delivers anything.

It no longer carries its own weekly schedule. That schedule rebuilt blindly whether or not anything
had changed and left no record of what it produced, and it was the workflow GitHub disabled for
inactivity. Scheduling now belongs to the watcher, which decides *whether* to build; this workflow
only knows *how*.

## Pipeline

```
1  actions/checkout@v7
2  docker/setup-qemu-action@v4          binfmt handlers for six foreign architectures
3  docker/setup-buildx-action@v4
4  docker/login-action@v4               Docker Hub
5  compute tags                         latest, plus u<state_key> when called by the watcher
6  docker/build-push-action@v7          7 platforms, push, upstream identities as build args
```

## Variables

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `IMAGE_NAME` | workflow env | Yes | `kjake/dehydrated-cloudflare-cron` | Publish target |
| `dehydrated_revision` | workflow_call input | No | `unknown` | Recorded as an OCI label |
| `hook_revision` | workflow_call input | No | `unknown` | Recorded as an OCI label |
| `base_digest` | workflow_call input | No | `unknown` | Recorded as an OCI label |
| `state_key` | workflow_call input | No | `''` | Becomes the immutable tag. Empty on a plain push, so only `latest` is published |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | secrets | Yes | none | Absent or wrong means step 4 fails and nothing is published |

Target platforms, unchanged: `linux/386`, `linux/amd64`, `linux/arm64/v8`, `linux/arm/v6`,
`linux/arm/v7`, `linux/ppc64le`, `linux/s390x`. `linux/mips64le` was added in commit a464077 and
removed in 9a4a1cd, and remains out.

## Runs

### Called by the watcher

- Trigger: `workflow_call` from `watch-upstream.yml` after it detects upstream movement.
- Behavior: builds all seven platforms, stamping the three upstream identities into the image as
  labels, and publishes `latest` plus `u<state_key>`.
- Success: the watcher then records the state. A failure leaves the state unrecorded, so the next
  watcher run retries rather than skipping.

### Push to main

- Trigger: a push to `main` that touches something other than `.upstream-state.json`, `docs/**`,
  `**.md`, or `LICENSE`.
- Behavior: identical build, but `state_key` is empty so only `latest` is published.
- Why the exclusions: the watcher commits the state file after a successful publish. Without
  `paths-ignore`, that commit would trigger another build, which would commit again, indefinitely.

### Tagging

- `latest` always.
- `u<state_key>` only when the watcher supplies one. The key is derived from **all three** upstream
  identities, not from dehydrated alone: a tag keyed on one input would be reused when only the
  base image moved, silently overwriting a previous build and destroying its rollback value. See
  [BL-CI-012](../../BUSINESS-LOGIC.md#bl-ci-012).

### Failure modes

- Docker Hub authentication failure at step 4.
- An upstream clone or PyPI failure inside the `Dockerfile`.
- A QEMU emulation failure on one of the six foreign architectures.

A single `build-push-action` invocation produces the whole manifest, so a failure on any one
platform means nothing is pushed at all.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| `actions/checkout@v7` | GitHub Action | Fetch the repository | Job fails |
| `docker/setup-qemu-action@v4` | GitHub Action | Emulation for foreign architectures | Those platforms fail to build |
| `docker/setup-buildx-action@v4` | GitHub Action | Multi-platform builder | Build cannot run |
| `docker/login-action@v4` | GitHub Action | Registry authentication | Cannot push |
| `docker/build-push-action@v7` | GitHub Action | Build and push the manifest | No publish |
| Docker Hub | Registry | Distribution | Previous `latest` remains |
| Everything the `Dockerfile` pulls | Network | Base image, both clones, PyPI | Build failure |

Actions are pinned to a major version and kept current by Dependabot.

## Relationships

- Called by: [20-ci-upstream-watcher.md](./20-ci-upstream-watcher.md).
- Builds: [01-container-image.md](./01-container-image.md).
- Distinct from: [23-ci-build-check.md](./23-ci-build-check.md), which builds on pull requests and
  never publishes, and [22-ci-vulnerability-scan.md](./22-ci-vulnerability-scan.md).
- Delivers to: operators described in
  [02-runtime-configuration.md](./02-runtime-configuration.md).

## Business Rules

1. Every published build carries `latest` plus an immutable tag derived from all three upstream
   identities. See [BL-CI-012](../../BUSINESS-LOGIC.md#bl-ci-012).
2. Registry credentials come only from repository secrets. See
   [BL-CI-004](../../BUSINESS-LOGIC.md#bl-ci-004).
3. The manifest covers exactly seven platforms. See
   [BL-CI-003](../../BUSINESS-LOGIC.md#bl-ci-003).
4. Given a push that touches only the state file or documentation, then no build runs.
   (`.github/workflows/docker.yml`, the `paths-ignore` list)
5. Given a build failure on any single platform, then nothing is pushed at all.
   (`.github/workflows/docker.yml`, the single `build-push-action` step)
6. Given a pull request, then no image is published: this workflow has no `pull_request` trigger.
   (`.github/workflows/docker.yml`, the `on:` block)
