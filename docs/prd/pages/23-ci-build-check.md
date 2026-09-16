# Build Check

> Surface type: background job (GitHub Actions workflow)
> Address: workflow `Build check`, job `build`, file `.github/workflows/build-check.yml`
> Schedule: every pull request targeting `main`
> Consumed by: GitHub's merge gating, and by the Dependabot automerge workflow
> Auth or permissions: `contents: read`. No secrets; it never pushes.

## Overview

The required status check on `main`, and this repository's only automated test suite.

It exists for two reasons. It is what makes Dependabot auto-merge safe: without a required check
that can actually fail, `gh pr merge --auto` finds a pull request immediately mergeable and merges
it on the spot, unreviewed and unbuilt. And it encodes the behaviours most likely to regress,
including the two that were real defects before this change.

It is deliberately separate from the vulnerability scan workflow, which also builds the image. That
one's SARIF upload can fail for reasons unrelated to this repository, and it has been doing so
since 2026-04; requiring it would block every merge for the wrong reason.

## Pipeline

```
1  actions/checkout@v7
2  docker/setup-buildx-action@v4
3  docker/build-push-action@v7        push: false, load: true, single platform
4  smoke test the image
5  renewal script fails soft without credentials     regression test
6  CF_HOST forms resolve correctly                   regression test
```

Single platform on purpose: this gates correctness, not portability, and emulating seven
architectures would make every pull request slow.

## Variables

| Name | Type | Required | Default | Notes |
|---|---|---|---|---|
| `tags` | action input | Yes | `dehydrated-cloudflare-cron:pr` | Local only; never pushed |
| `push` | action input | Yes | `false` | This workflow has no registry credentials |
| `load` | action input | Yes | `true` | Required so the test steps can run the image |

## Runs

### Step 4, smoke test

Asserts the image is structurally sound:

| Assertion | Why it matters |
|---|---|
| both scripts exist and are executable | a `chmod` regression would break the container silently |
| `/dehydrated/domains.txt` exists and is empty | domains-file mode depends on it |
| upstream client and hook are present | proves both clones succeeded |
| `crond` and `bash` present | the container command needs both |
| `git` **absent** | proves the build-time tool was removed |
| `/etc/dehydrated-build-info` readable | proves provenance recording works |
| health check exits non-zero with no status file | the initial state must be unhealthy, not healthy |

### Step 5, fail-soft regression

Runs the renewal script with no credentials and asserts three things: exit status 0, a `FAIL`
status recorded, and the preflight error message present.

This is the regression test for the defect where the script's exit status was incidentally that of
a trailing `find`, which combined with the old `&&` container command to kill the container
whenever `certs` did not exist. See [BL-RENEW-007](../../BUSINESS-LOGIC.md#bl-renew-007) and
[BL-RENEW-008](../../BUSINESS-LOGIC.md#bl-renew-008).

### Step 6, CF_HOST forms

Asserts all three forms produce the expected argument list:

| Input | Expected | Guards against |
|---|---|---|
| `a.tld -d b.tld` | `-d a.tld -d b.tld` | breaking the documented legacy form when "fixing" the quoting |
| `a.tld b.tld` | `-d a.tld -d b.tld` | the new list form regressing |
| `*.example.com` | `-d *.example.com` | pathname expansion eating wildcard certificates |

The third is the regression test for globbing, which was a latent defect: the splitting is
deliberately unquoted, which also enables globbing unless disabled. See
[BL-RENEW-010](../../BUSINESS-LOGIC.md#bl-renew-010).

### Failure

Any step failing fails the job, which fails the required check, which blocks the merge. This is
the entire safety mechanism for automerge.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| `actions/checkout@v7` | GitHub Action | Fetch the repository | Job fails |
| `docker/setup-buildx-action@v4` | GitHub Action | Builder | Build cannot run |
| `docker/build-push-action@v7` | GitHub Action | Build and load the image | Nothing to test |
| Everything the `Dockerfile` pulls | Network | Base image, both clones, PyPI | Build failure, which correctly blocks the merge |
| A branch ruleset requiring this check | Repository setting | Makes the check binding | **Without it, automerge merges unreviewed and unbuilt** |

## Relationships

- Gates: [24-ci-dependency-automation.md](./24-ci-dependency-automation.md).
- Builds: [01-container-image.md](./01-container-image.md), single platform, never pushed.
- Tests: [03-certificate-renewal-job.md](./03-certificate-renewal-job.md) and
  [02-runtime-configuration.md](./02-runtime-configuration.md).
- Distinct from: [22-ci-vulnerability-scan.md](./22-ci-vulnerability-scan.md), which also builds
  but is not a merge gate.

## Business Rules

1. Automerge is safe only while this check is required on `main`. See
   [BL-CI-011](../../BUSINESS-LOGIC.md#bl-ci-011).
2. Given a pull request that breaks the Docker build, when this workflow runs, then the job fails
   and the merge is blocked. (`.github/workflows/build-check.yml`, the `Build image` step)
3. Given the renewal script run without credentials, then it exits 0 and records `FAIL`. See
   [BL-RENEW-006](../../BUSINESS-LOGIC.md#bl-renew-006).
4. Given `CF_HOST='*.example.com'` with matching files present, then the wildcard survives intact.
   See [BL-RENEW-010](../../BUSINESS-LOGIC.md#bl-renew-010).
5. Given a built image, then `git` is absent from it. See
   [BL-IMG-002](../../BUSINESS-LOGIC.md#bl-img-002).
