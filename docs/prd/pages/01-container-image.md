# Container Image

> Surface type: infrastructure as code (container image)
> Address: `kjake/dehydrated-cloudflare-cron:latest`
> Source: `Dockerfile`
> Consumed by: operators running `docker create` / `docker run`, per `README.md:34-40` and `README.md:50-56`
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
| Base | `Dockerfile:1` | `cgr.dev/chainguard/wolfi-base`, bare name, no tag or digest. Provides `apk` and busybox. No Python, and busybox has no `crond`. See [BL-IMG-016](../../BUSINESS-LOGIC.md#bl-img-016) |
| Label | `Dockerfile` | `maintainer=kjake` |
| Labels | `Dockerfile:10-19` `ARG`/`LABEL` | OCI metadata plus the three upstream identities the watcher observed. See [BL-IMG-015](../../BUSINESS-LOGIC.md#bl-img-015) |
| Script install | `Dockerfile:21-22` `COPY` | Repo files `dehydrated` and `healthcheck` copied in. `COPY`, not `ADD` |
| Packages | `Dockerfile:28` `RUN` | `curl`, `openssl`, `bash`, `git`, `python-3`, `py3-pip`, `supercronic` installed, all unpinned so each rebuild gets Wolfi's latest fixes |
| ACME client | `Dockerfile:30` | `git clone` of `dehydrated-io/dehydrated` into `/dehydrated`, default branch, unpinned |
| Hook directory | `Dockerfile:32` | `/dehydrated/hooks` created |
| Hook | `Dockerfile:33` | `git clone` of `SeattleDevs/letsencrypt-cloudflare-hook` into `/dehydrated/hooks/cloudflare`, default branch, unpinned |
| Python deps | `Dockerfile:34` | `pip3 install -r hooks/cloudflare/requirements.txt` into the system site-packages (`/usr/lib/python3.<minor>/site-packages`) |
| Build tool removal | `Dockerfile:39` | `apk del git py3-pip`. No `git` and no `pip3` at runtime. See [BL-IMG-017](../../BUSINESS-LOGIC.md#bl-img-017) |
| Cleanup | `Dockerfile:40` | `/var/cache/apk/*`, `/tmp/*`, `/var/tmp/`, `~/.cache/pip` removed |
| Script mode | `Dockerfile:41` | `/etc/periodic/daily/dehydrated` and `/usr/local/bin/healthcheck` made executable |
| Schedule | `Dockerfile:42-43` | `/etc/crontabs/dehydrated` written with `0 2 * * * /etc/periodic/daily/dehydrated`. See [BL-IMG-018](../../BUSINESS-LOGIC.md#bl-img-018) |
| Domains file | `Dockerfile:44` | `/dehydrated/domains.txt` created empty |
| Build info | `Dockerfile:35-38` `RUN` | `/etc/dehydrated-build-info` records the commits actually cloned |
| Health | `Dockerfile:49-50` `HEALTHCHECK` | Runs `/usr/local/bin/healthcheck` every 6h after a 5m start period |
| Command | `Dockerfile:55` `CMD` | `["/bin/bash","-c","/etc/periodic/daily/dehydrated; exec supercronic /etc/crontabs/dehydrated"]` (exec form) |
| Volumes | `Dockerfile:57`, `Dockerfile:62` `VOLUME` | `/dehydrated/certs` **and** `/dehydrated/accounts` |

Resulting filesystem layout that matters at runtime:

```
/dehydrated/                     upstream ACME client checkout, working directory of the job
  dehydrated                     upstream client executable
  domains.txt                    empty at build; replaced by a bind mount in domains-file mode
  hooks/cloudflare/hook.py       DNS-01 hook invoked with -k
  accounts/                      ACME account key, now a declared volume
  certs/                         declared volume, certificate output
/etc/periodic/daily/dehydrated   this repo's renewal script (historical path; nothing runs the directory)
/etc/crontabs/dehydrated         the daily schedule, read by supercronic
/usr/local/bin/healthcheck       reports the last run's outcome to Docker
/etc/dehydrated-build-info       upstream commits this image was built from
/run/dehydrated.status           last run outcome, written each run
```

## Variables

The image declares no `ENV`. Every input is supplied at container
create time and is documented in
[02-runtime-configuration.md](./02-runtime-configuration.md). The three build `ARG`s below only
label the image; none of the upstream sources is parameterized.

| Name | Type | Required | Default | Allowed values | Notes |
|---|---|---|---|---|---|
| `DEHYDRATED_REVISION` | string | No | `unknown` | a commit sha | Recorded as a label. Supplied by the watcher |
| `HOOK_REVISION` | string | No | `unknown` | a commit sha | Recorded as a label. Supplied by the watcher |
| `BASE_DIGEST` | string | No | `unknown` | `sha256:...` | Recorded as a label. Supplied by the watcher |
| (image env) | none | n/a | n/a | n/a | The `Dockerfile` declares no `ENV`. `CF_*` variables reach the process from `docker create -e` only |

## Plan and apply

### Building the image

- Trigger: `docker build .` locally, or `docker/build-push-action` in CI
  (`.github/workflows/docker.yml:84-85`, `.github/workflows/anchore.yml:32-33`).
- Preconditions: network access to `cgr.dev` for the base image, to the Wolfi package
  repository, to GitHub for both clones, and to PyPI for the hook requirements.
- What happens: the single `RUN` at `Dockerfile` executes the whole assembly in one
  layer, so a failure at any point fails the build with no partial layer cached.
- Output: an image whose content depends on the date, because every source is unpinned: the
  base image, its packages, and both clones. See [BL-IMG-016](../../BUSINESS-LOGIC.md#bl-img-016),
  [BL-IMG-004](../../BUSINESS-LOGIC.md#bl-img-004),
  [BL-IMG-005](../../BUSINESS-LOGIC.md#bl-img-005).
- Failure modes: an upstream repository rename or deletion breaks `Dockerfile:30` or
  `Dockerfile:33`; a PyPI resolution failure breaks `Dockerfile:34`; a Wolfi package
  rename (for example `python-3` or `supercronic`) breaks `Dockerfile:28`; a Wolfi Python build
  that adopts PEP 668 marking would break `Dockerfile:34` with
  `externally-managed-environment` (the 2026-10-21 build with Python 3.13 did not hit this).
  All surface as a non-zero `docker build`.
- Multi-platform: the published build covers `linux/amd64` and `linux/arm64`, the only
  platforms wolfi-base is published for (`.github/workflows/docker.yml:88`). The `arm64` half runs
  under QEMU emulation (`.github/workflows/docker.yml:56-57`).

### Starting a container

- Trigger: `docker start`, `README.md:61`.
- What happens: the renewal script runs synchronously to completion, then
  `exec supercronic /etc/crontabs/dehydrated` replaces the shell so `supercronic` becomes PID 1. The separator is `;`, not `&&`, so the
  scheduler starts regardless of how the first run went.
- Success signal: the container stays up with `supercronic` in the foreground, and reports a health
  status once the first run has recorded one.
- Failure signal: not the exit status. A failed renewal leaves the container running and
  `unhealthy`. See [BL-IMG-019](../../BUSINESS-LOGIC.md#bl-img-019) and
  [BL-IMG-014](../../BUSINESS-LOGIC.md#bl-img-014).
- Signal handling: `exec` makes `supercronic` PID 1, so `docker stop` delivers SIGTERM to it
  directly rather than to a wrapper shell, and it reaps child processes.

### Recreating a container

- Trigger: `docker rm` followed by `docker create`.
- What happens: certificates survive if the certs volume is bound or reused. The account key
  now survives too, because `/dehydrated/accounts` is a declared volume, so a recreate no
  longer spends a new-account registration. Bind it explicitly to survive `docker rm -v`.
  See [BL-IMG-013](../../BUSINESS-LOGIC.md#bl-img-013).
- Edge case: with no `-v` for certs, `Dockerfile:57` gives an anonymous volume. It survives
  restart, survives `docker rm`, and is destroyed by `docker rm -v`.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| `cgr.dev/chainguard/wolfi-base` | Base image | `apk`, busybox, the user and group database | Build fails if unpullable. Published for `amd64` and `arm64` only |
| Wolfi package repository | Build-time packages | `curl`, `openssl`, `bash`, `python-3`, `supercronic`, plus `git` and `py3-pip` for the build | Build fails if a package is renamed or removed |
| `dehydrated-io/dehydrated` | Build-time git clone | The ACME client itself | Build fails if the repo or default branch is unavailable |
| `SeattleDevs/letsencrypt-cloudflare-hook` | Build-time git clone | DNS-01 challenge solving against CloudFlare | Build fails if unavailable |
| PyPI (via hook `requirements.txt`) | Build-time packages | Hook runtime dependencies | Build fails on resolution error |
| `bash` | Runtime binary | The renewal script's interpreter (`dehydrated`) | Without it the script cannot execute. Installed at `Dockerfile:28` |
| `python-3` | Runtime | Interpreter for the hook | Without it every DNS-01 challenge fails. Installed at `Dockerfile:28` |
| `curl`, `openssl` | Runtime binaries | Used by the upstream ACME client | Installed at `Dockerfile:28`. Their exact use is UNKNOWN-external |
| `supercronic` | Runtime daemon | Runs `/etc/crontabs/dehydrated` as PID 1 | If absent, `exec supercronic` at `Dockerfile:55` fails and the container exits after the first run. The build check runs `supercronic -test` to catch this |
| CloudFlare DNS API, ACME provider | Network services | Contacted by the hook and the client, never by this repo's code | Renewal fails; the script still exits 0, see [BL-RENEW-007](../../BUSINESS-LOGIC.md#bl-renew-007) |

## Relationships

- Invoked by: an operator via `docker create` / `docker start` (`README.md:34-40`,
  `README.md:50-56`, `README.md:61`); by the CI publish job which builds and pushes it
  (`.github/workflows/docker.yml:84-94`); by the CI scan job which builds it locally
  (`.github/workflows/anchore.yml:32-37`).
- Invokes: the renewal job at `Dockerfile:55` and, daily, through `/etc/crontabs/dehydrated`. See
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
   `/etc/dehydrated-build-info`, and the watcher rebuilds when any of them, or the resolved
   package set, moves. See
   [BL-IMG-016](../../BUSINESS-LOGIC.md#bl-img-016),
   [BL-IMG-015](../../BUSINESS-LOGIC.md#bl-img-015),
   [BL-CI-015](../../BUSINESS-LOGIC.md#bl-ci-015).
2. A freshly built image always contains an empty `/dehydrated/domains.txt`, so
   domains-file mode works without a mount and simply issues nothing.
   See [BL-IMG-007](../../BUSINESS-LOGIC.md#bl-img-007).
3. The container always becomes a scheduled service, regardless of the first run's outcome.
   See [BL-IMG-019](../../BUSINESS-LOGIC.md#bl-img-019).
4. Both certificates and the ACME account persist by default. See
   [BL-IMG-010](../../BUSINESS-LOGIC.md#bl-img-010) and
   [BL-IMG-013](../../BUSINESS-LOGIC.md#bl-img-013).
6. A failed renewal is visible as a Docker health status rather than as an exit code. See
   [BL-IMG-014](../../BUSINESS-LOGIC.md#bl-img-014).
5. Given a built image, when `command -v git` or `command -v pip3` is run inside it, then it
   fails, because both are installed and removed within one layer. See
   [BL-IMG-017](../../BUSINESS-LOGIC.md#bl-img-017).
7. Given a built image, when the container starts, then the daily run is scheduled for 02:00 UTC
   whatever `TZ` is set to, because the image has no time zone data. See
   [BL-RENEW-011](../../BUSINESS-LOGIC.md#bl-renew-011).
