# Container Image

> Surface type: infrastructure as code (container image)
> Address: `kjake/dehydrated-cloudflare-cron:latest`
> Source: `Dockerfile`
> Consumed by: operators running `docker create` / `docker run`, per `README.md:5-11` and `README.md:20-26`
> Auth or permissions: none to pull (public image). The container runs as root: no `USER` directive appears anywhere in `Dockerfile`, which is what allows the recursive `chown` at `dehydrated` to succeed.

## Overview

This is the deliverable of the repository. It is a self-contained certificate renewal
appliance: an operator supplies CloudFlare credentials and a volume, and the image handles
ACME account registration, DNS-01 challenge solving, certificate issuance, daily renewal,
and file permission normalization without further interaction.

The image is assembled rather than authored. Its two functional components, the ACME client
and the CloudFlare hook, are cloned from GitHub during the build. What this repository
contributes is the assembly: which packages are present, where the components live, what
the container does when it starts, and which path persists.

## Resources

What the build creates, in the order the `Dockerfile` creates it.

| Layer step | Source | Result |
|---|---|---|
| Base | `Dockerfile` | `python:alpine`, floating tag. Provides `python3`, `pip3`, busybox (including `crond` and the `/etc/periodic/*` convention) |
| Label | `Dockerfile` | `maintainer=kjake` |
| Labels | `Dockerfile` `ARG`/`LABEL` | OCI metadata plus the three upstream identities the watcher observed. See [BL-IMG-015](../../BUSINESS-LOGIC.md#bl-img-015) |
| Script install | `Dockerfile` `COPY` | Repo files `dehydrated` and `healthcheck` copied in. `COPY`, not `ADD` |
| Packages | `Dockerfile` `RUN` | `curl`, `openssl`, `bash`, `git` installed. The former no-op `apk add` with no packages is gone |
| ACME client | `Dockerfile` | `git clone` of `dehydrated-io/dehydrated` into `/dehydrated`, default branch, unpinned |
| Hook directory | `Dockerfile` | `/dehydrated/hooks` created |
| Hook | `Dockerfile` | `git clone` of `SeattleDevs/letsencrypt-cloudflare-hook` into `/dehydrated/hooks/cloudflare`, default branch, unpinned |
| Python deps | `Dockerfile` | `pip3 install -r hooks/cloudflare/requirements.txt` into global site-packages |
| Build tool removal | `Dockerfile` | `apk del git`. No `git` binary at runtime |
| Cleanup | `Dockerfile` | `/var/cache/apk/*`, `/tmp/*`, `/var/tmp/`, `~/.cache/pip` removed |
| Script mode | `Dockerfile` | `/etc/periodic/daily/dehydrated` made executable |
| Domains file | `Dockerfile` | `/dehydrated/domains.txt` created empty |
| Build info | `Dockerfile` `RUN` | `/etc/dehydrated-build-info` records the commits actually cloned |
| Health | `Dockerfile` `HEALTHCHECK` | Runs `/usr/local/bin/healthcheck` every 6h after a 5m start period |
| Command | `Dockerfile` `CMD` | `["/bin/bash","-c","/etc/periodic/daily/dehydrated; exec crond -f"]` (exec form) |
| Volumes | `Dockerfile` `VOLUME` | `/dehydrated/certs` **and** `/dehydrated/accounts` |

Resulting filesystem layout that matters at runtime:

```
/dehydrated/                     upstream ACME client checkout, working directory of the job
  dehydrated                     upstream client executable
  domains.txt                    empty at build; replaced by a bind mount in domains-file mode
  hooks/cloudflare/hook.py       DNS-01 hook invoked with -k
  accounts/                      ACME account key, now a declared volume
  certs/                         declared volume, certificate output
/etc/periodic/daily/dehydrated   this repo's renewal script
/usr/local/bin/healthcheck       reports the last run's outcome to Docker
/etc/dehydrated-build-info       upstream commits this image was built from
/run/dehydrated.status           last run outcome, written each run
```

## Variables

The image itself declares no `ARG` and no `ENV`. Every input is supplied at container
create time and is documented in
[02-runtime-configuration.md](./02-runtime-configuration.md). The build-time inputs are the
three upstream sources, none of which is parameterized.

| Name | Type | Required | Default | Allowed values | Notes |
|---|---|---|---|---|---|
| `DEHYDRATED_REVISION` | string | No | `unknown` | a commit sha | Recorded as a label. Supplied by the watcher |
| `HOOK_REVISION` | string | No | `unknown` | a commit sha | Recorded as a label. Supplied by the watcher |
| `BASE_DIGEST` | string | No | `unknown` | `sha256:...` | Recorded as a label. Supplied by the watcher |
| (image env) | none | n/a | n/a | n/a | The `Dockerfile` declares no `ENV`. `CF_*` variables reach the process from `docker create -e` only |

## Plan and apply

### Building the image

- Trigger: `docker build .` locally, or `docker/build-push-action` in CI
  (`.github/workflows/docker.yml:31`, `.github/workflows/anchore.yml:27`).
- Preconditions: network access to Docker Hub for `python:alpine`, to GitHub for both
  clones, and to PyPI for the hook requirements.
- What happens: the single `RUN` at `Dockerfile` executes the whole assembly in one
  layer, so a failure at any point fails the build with no partial layer cached.
- Output: an image whose content depends on the date, because three of the four sources are
  unpinned. See [BL-IMG-001](../../BUSINESS-LOGIC.md#bl-img-001),
  [BL-IMG-004](../../BUSINESS-LOGIC.md#bl-img-004),
  [BL-IMG-005](../../BUSINESS-LOGIC.md#bl-img-005).
- Failure modes: an upstream repository rename or deletion breaks `Dockerfile` or
  `Dockerfile`; a PyPI resolution failure breaks `Dockerfile`; a base image that
  adopts PEP 668 marking would break `Dockerfile` with
  `externally-managed-environment`. All surface as a non-zero `docker build`.
- Multi-platform: the published build runs under QEMU emulation for the non-native
  platforms (`.github/workflows/docker.yml:21-22`), which is why the `pip3` step is the
  slowest part of the release job.

### Starting a container

- Trigger: `docker start`, `README.md:31`.
- What happens: the renewal script runs synchronously to completion, then `exec crond -f`
  replaces the shell so `crond` becomes PID 1. The separator is `;`, not `&&`, so the
  scheduler starts regardless of how the first run went.
- Success signal: the container stays up with `crond` in the foreground, and reports a health
  status once the first run has recorded one.
- Failure signal: not the exit status. A failed renewal leaves the container running and
  `unhealthy`. See [BL-IMG-012](../../BUSINESS-LOGIC.md#bl-img-012) and
  [BL-IMG-014](../../BUSINESS-LOGIC.md#bl-img-014).
- Signal handling: `exec` makes `crond` PID 1, so `docker stop` delivers SIGTERM to it
  directly rather than to a wrapper shell.

### Recreating a container

- Trigger: `docker rm` followed by `docker create`.
- What happens: certificates survive if the certs volume is bound or reused. The account key
  now survives too, because `/dehydrated/accounts` is a declared volume, so a recreate no
  longer spends a new-account registration. Bind it explicitly to survive `docker rm -v`.
  See [BL-IMG-013](../../BUSINESS-LOGIC.md#bl-img-013).
- Edge case: with no `-v` for certs, `Dockerfile` gives an anonymous volume. It survives
  restart, survives `docker rm`, and is destroyed by `docker rm -v`.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| `python:alpine` | Base image | Python runtime for the hook, busybox `crond`, `/etc/periodic/daily` convention | Build fails if unpullable. A base image change can silently alter the daily cron time |
| `dehydrated-io/dehydrated` | Build-time git clone | The ACME client itself | Build fails if the repo or default branch is unavailable |
| `SeattleDevs/letsencrypt-cloudflare-hook` | Build-time git clone | DNS-01 challenge solving against CloudFlare | Build fails if unavailable |
| PyPI (via hook `requirements.txt`) | Build-time packages | Hook runtime dependencies | Build fails on resolution error |
| `bash` | Runtime binary | The renewal script's interpreter (`dehydrated`) | Without it the script cannot execute. Installed at `Dockerfile` |
| `curl`, `openssl` | Runtime binaries | Used by the upstream ACME client | Installed at `Dockerfile`. Their exact use is UNKNOWN-external |
| busybox `crond` | Runtime daemon | Runs `/etc/periodic/daily` | If absent from the base image, `crond -f` at `Dockerfile` fails and the container exits after the first run |
| CloudFlare DNS API, ACME provider | Network services | Contacted by the hook and the client, never by this repo's code | Renewal fails; the script still exits 0, see [BL-RENEW-004](../../BUSINESS-LOGIC.md#bl-renew-004) |

## Relationships

- Invoked by: an operator via `docker create` / `docker start` (`README.md:5-11`,
  `README.md:20-26`, `README.md:31`); by the CI publish job which builds and pushes it
  (`.github/workflows/docker.yml:30-35`); by the CI scan job which builds it locally
  (`.github/workflows/anchore.yml:26-31`).
- Invokes: the renewal job at `Dockerfile`. See
  [03-certificate-renewal-job.md](./03-certificate-renewal-job.md).
- Shares state or data with: any other container mounting the same certs volume. That
  sharing is the reason for the permission rules in
  [BL-CERT-001](../../BUSINESS-LOGIC.md#bl-cert-001) through
  [BL-CERT-003](../../BUSINESS-LOGIC.md#bl-cert-003).
- Configured by: [02-runtime-configuration.md](./02-runtime-configuration.md).
- Published by: [21-ci-image-publish.md](./21-ci-image-publish.md).
- Scanned by: [22-ci-vulnerability-scan.md](./22-ci-vulnerability-scan.md).
- Naming collision: this repo's script file is named `dehydrated` and so is the cloned
  upstream executable. They occupy different paths and do not conflict functionally.

## Business Rules

Full rule text and citations live in
[BUSINESS-LOGIC.md](../../BUSINESS-LOGIC.md). Summarized here in product terms:

1. The image is not reproducible from this repository: base image and both components float,
   deliberately. What went into a given build is recorded in its labels and in
   `/etc/dehydrated-build-info`, and the watcher rebuilds when any of the three moves. See
   [BL-IMG-001](../../BUSINESS-LOGIC.md#bl-img-001),
   [BL-IMG-015](../../BUSINESS-LOGIC.md#bl-img-015),
   [BL-CI-009](../../BUSINESS-LOGIC.md#bl-ci-009).
2. A freshly built image always contains an empty `/dehydrated/domains.txt`, so
   domains-file mode works without a mount and simply issues nothing.
   See [BL-IMG-007](../../BUSINESS-LOGIC.md#bl-img-007).
3. The container always becomes a scheduled service, regardless of the first run's outcome.
   See [BL-IMG-012](../../BUSINESS-LOGIC.md#bl-img-012).
4. Both certificates and the ACME account persist by default. See
   [BL-IMG-010](../../BUSINESS-LOGIC.md#bl-img-010) and
   [BL-IMG-013](../../BUSINESS-LOGIC.md#bl-img-013).
6. A failed renewal is visible as a Docker health status rather than as an exit code. See
   [BL-IMG-014](../../BUSINESS-LOGIC.md#bl-img-014).
5. Given a built image, when `command -v git` is run inside it, then it fails, because git
   is installed and removed within one layer. See
   [BL-IMG-002](../../BUSINESS-LOGIC.md#bl-img-002).
