# dehydrated-cloudflare-cron - Business Logic

> Generated: 2026-09-16 from commit 9a4a1cd, revised the same day for the
> reliability, permission, and CI changes.
> Scope: rules and invariants enforced by this repository. Behavior owned by the two
> externally cloned projects (dehydrated-io/dehydrated and SeattleDevs/letsencrypt-cloudflare-hook)
> is out of scope and is marked UNKNOWN-external where it affects a rule.
> Companion: [docs/prd/](./prd/) describes the product surfaces that apply these rules.
> Maintenance: this file is generated once, then maintained by hand. Update it with the
> code, not on the next regeneration.

## Domain vocabulary

| Term | Meaning in this system | Backed by |
|---|---|---|
| Image | The published container `kjake/dehydrated-cloudflare-cron:latest` that operators pull | `Dockerfile`, `.github/workflows/docker.yml:34` |
| Renewal script | `/etc/periodic/daily/dehydrated` inside the image, the repo file `dehydrated` | `Dockerfile` |
| dehydrated | The upstream ACME client cloned to `/dehydrated` at build time | `Dockerfile` |
| Hook | The CloudFlare DNS-01 hook cloned to `/dehydrated/hooks/cloudflare` | `Dockerfile` |
| Single-domain mode | `CF_HOST` is set, domains come from the environment | `dehydrated` |
| Domains-file mode | `CF_HOST` is unset or empty, domains come from `/dehydrated/domains.txt` | `dehydrated` |
| Certificate store | `/dehydrated/certs`, the only declared volume | `Dockerfile` |

## Invariants

These must hold at all times, independent of any single run.

1. The ACME challenge type is always `dns-01` and the hook is always
   `hooks/cloudflare/hook.py`. Neither is configurable at runtime.
   (`dehydrated`, `dehydrated`)
2. Exactly one path is declared as a volume: `/dehydrated/certs`. Every other path in the
   image, including the ACME account directory, is container-local and is lost when the
   container is recreated. (`Dockerfile`)
3. `/dehydrated/domains.txt` always exists in a freshly built image, as an empty file.
   (`Dockerfile`)
4. The renewal script never sets `set -e`, so no command failure inside it aborts the run.
   (`dehydrated`)
5. After every run of the renewal script, every file under `certs` is readable by all
   users and every directory under `certs` is traversable by all users.
   (`dehydrated`, `dehydrated`)
6. The image contains no `git` binary at runtime: git is installed for the build clones
   and deleted in the same layer. (`Dockerfile`, `Dockerfile`)

## Rules by area

## Image build

### BL-IMG-001

**Rule:** The base image is the floating tag `python:alpine`, not a pinned digest or version.
**Enforced:** `Dockerfile`.
**Consequence:** Python version, Alpine version, and the busybox cron configuration can
change between two builds of an unchanged repository.
**Test:** build twice against different `python:alpine` pushes, assert the resulting
`python3 --version` may differ with no repo change.

### BL-IMG-002

**Rule:** The runtime package set is exactly `curl`, `openssl`, `bash`. `git` is installed
for the build and removed before the layer is committed.
**Enforced:** `Dockerfile` installs `curl openssl bash git`; `Dockerfile` runs `apk del git`.
**Test:** `docker run --rm IMAGE sh -c 'command -v bash curl openssl'` succeeds and
`command -v git` fails.

### BL-IMG-003

> **RETIRED 2026-09-16.** The no-op `apk add` was removed from `Dockerfile`. Superseded by nothing; the behaviour simply no longer exists.
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** `apk add --update --no-cache` at `Dockerfile:5` names no packages and installs
nothing. It is a no-op retained in the build chain.
**Enforced:** `Dockerfile:5`.
**Note:** recorded under Known inconsistencies. Not a functional rule, documented so a
future reader does not assume it installs a hidden dependency.

### BL-IMG-004

**Rule:** The ACME client is cloned from the default branch of
`https://github.com/dehydrated-io/dehydrated` at build time, with no tag, branch, or commit pin.
**Enforced:** `Dockerfile`.
**Consequence:** the client version in the image is whatever upstream HEAD was on the build date.
Builds are not reproducible from this repository alone.
**Test:** two builds on different dates can contain different `dehydrated` versions.

### BL-IMG-005

**Rule:** The CloudFlare hook is cloned from the default branch of
`https://github.com/SeattleDevs/letsencrypt-cloudflare-hook` into `/dehydrated/hooks/cloudflare`,
with no pin.
**Enforced:** `Dockerfile` creates `hooks`, `Dockerfile` clones into `hooks/cloudflare`.
**Consequence:** same non-reproducibility as [BL-IMG-004](#bl-img-004).

### BL-IMG-006

**Rule:** The hook's Python dependencies are installed into the image's global site-packages
from the hook's own `requirements.txt`. No virtualenv is used and no dependency is pinned
by this repository.
**Enforced:** `Dockerfile`.
**Test:** the dependency set is defined externally; assert only that
`pip3 show` lists packages not named anywhere in this repo.

### BL-IMG-007

**Rule:** `/dehydrated/domains.txt` is created as an empty file during the build.
**Enforced:** `Dockerfile`.
**Why it matters:** in single-domain mode the file still exists and is still read by the
ACME client, contributing zero domains, so the `-d` argument is the only source of domains.
In domains-file mode the operator replaces this file with a bind mount.
**Test:** `docker run --rm IMAGE sh -c 'test -f /dehydrated/domains.txt && wc -c < /dehydrated/domains.txt'`
returns 0 bytes.

### BL-IMG-008

**Rule:** The renewal script is installed at `/etc/periodic/daily/dehydrated` and made executable.
**Enforced:** `Dockerfile` copies it, `Dockerfile` runs `chmod +x`.
**Why it matters:** the path, not a crontab entry in this repo, is what schedules the job.
The base image's busybox cron configuration is what runs `/etc/periodic/daily`.
See [BL-RENEW-005](#bl-renew-005).

### BL-IMG-009

> **RETIRED 2026-09-16.** The container command now uses `;` and `exec`, so `crond` starts regardless of the first run. See [BL-IMG-012](#bl-img-012).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** The container command is `/etc/periodic/daily/dehydrated && crond -f`. The cron
daemon starts only if the first, synchronous run of the renewal script exits zero.
**Enforced:** `Dockerfile:18`.
**On violation:** if the first run exits non-zero, `crond` is never started and the
container exits with that status. No daily renewals occur.
**Test:** force the script to exit non-zero (see [BL-RENEW-004](#bl-renew-004) for what
controls its exit status), start the container, assert it exits and no `crond` process ran.

### BL-IMG-010

**Rule:** `/dehydrated/certs` is declared as a volume. With no explicit bind mount, Docker
creates an anonymous volume for it.
**Enforced:** `Dockerfile`.
**Consequence:** certificates survive a container restart even when the operator forgets
`-v`, but an anonymous volume is not discoverable by path and is removed by `docker rm -v`.

### BL-IMG-011

> **RETIRED 2026-09-16.** `/dehydrated/accounts` is now a declared volume. See [BL-IMG-013](#bl-img-013).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** The ACME account directory is not declared as a volume and is not persisted.
**Enforced:** `Dockerfile:20` declares exactly one `VOLUME`, and it is `/dehydrated/certs`.
**Consequence:** recreating the container discards the ACME account key, so
[BL-RENEW-002](#bl-renew-002) performs a fresh registration against the ACME provider on
the first run of every new container. This consumes new-account rate limit against the provider.
**Test:** create, run, remove, and recreate the container; assert `/dehydrated/accounts`
is empty in the new container before the first run.

### BL-IMG-012

**Rule:** The container command is `/etc/periodic/daily/dehydrated; exec crond -f` in exec form.
`crond` starts regardless of the first run's outcome, and becomes PID 1.
**Enforced:** `Dockerfile`, the `CMD` line.
**Supersedes:** [BL-IMG-009](#bl-img-009), where `&&` meant a failed first run left the container
with no scheduler and no daily renewals.
**Second effect:** `exec` makes `crond` PID 1, so `docker stop` delivers SIGTERM to it directly
instead of to a wrapper shell.
**Test:** start a container whose first run fails; assert it stays up and `crond` is running.

### BL-IMG-013

**Rule:** `/dehydrated/accounts` is a declared volume.
**Enforced:** `Dockerfile`, the second `VOLUME` line.
**Supersedes:** [BL-IMG-011](#bl-img-011).
**Why:** without it the ACME account key was discarded on every `docker rm`, forcing a genuine new
registration against the CA's new-account rate limit each time the container was recreated.
**Test:** recreate a container with the accounts volume bound; assert no new registration occurs.

### BL-IMG-014

**Rule:** The image declares a `HEALTHCHECK` running `/usr/local/bin/healthcheck` every 6 hours,
after a 5 minute start period.
**Enforced:** `Dockerfile`, the `HEALTHCHECK` line; `healthcheck` script.
**Why:** the renewal script exits 0 even on failure ([BL-RENEW-007](#bl-renew-007)), so the
container's exit status cannot signal trouble. The health status is the signal instead.
**Test:** after a failed run, `docker inspect --format '{{.State.Health.Status}}'` reports
`unhealthy` while the container is still running.

### BL-IMG-015

**Rule:** Every image records the upstream commits it was built from, both as OCI labels and in
`/etc/dehydrated-build-info`.
**Enforced:** `Dockerfile`, the `ARG`/`LABEL` block and the `printf` inside the build `RUN`.
**Why two places:** the labels carry what the watcher observed when it decided to build; the file
records what `git clone` actually fetched. They differ only if upstream moved mid-build, and the
next watcher run reconciles that.
**Test:** `docker run --rm IMAGE cat /etc/dehydrated-build-info` prints three key=value lines.

## Runtime configuration

### BL-CFG-001

**Rule:** When `CF_HOST` is unset or set to the empty string, the renewal script runs the
ACME client with no `-d` argument, so the domain list comes from `/dehydrated/domains.txt`.
**Enforced:** `dehydrated` takes the then-branch, `dehydrated` runs the client without `-d`.
**Verified:** `[ -z $CF_HOST ]` with `CF_HOST` unset expands to the single argument `-z`,
which `test` evaluates as a non-empty string and returns 0.
**Test:** run with `CF_HOST` absent, assert the client is invoked without `-d`.

### BL-CFG-002

**Rule:** When `CF_HOST` is a single token with no whitespace, the renewal script runs the
ACME client with `-d <that token>`.
**Enforced:** `dehydrated` takes the else-branch, `dehydrated`.
**Test:** `CF_HOST=host.domain.tld`, assert the client receives `-d host.domain.tld`.

### BL-CFG-003

> **RETIRED 2026-09-16.** The branch test is now quoted, so no `[: too many arguments` is emitted. The legacy value form still works. See [BL-CFG-006](#bl-cfg-006).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** When `CF_HOST` contains whitespace, the unquoted expansion at `dehydrated:7`
passes more than four arguments to `test`, which fails with `[: too many arguments` on
stderr and returns status 2. The non-zero status selects the else-branch, and the unquoted
expansion at `dehydrated:10` then word-splits `CF_HOST` into the argument list.
**Enforced:** `dehydrated:7` (unquoted `$CF_HOST` inside `[ -z ... ]`), `dehydrated:10`
(unquoted `$CF_HOST` after `-d`).
**Why it matters:** this is the mechanism behind the multi-domain form documented at
`README.md:15`. The documented value `CF_HOST='host1.domain.tld -d host2.domain.tld'`
becomes the arguments `-d host1.domain.tld -d host2.domain.tld`. The feature works, and it
prints one `[: too many arguments` error to stderr on every run.
**Verified:** reproduced with GNU bash 3.2.57. The container runs Alpine bash, installed at
`Dockerfile:6`. See the verification caveat in
[open-questions.md](./prd/appendix/open-questions.md).
**Test:** `CF_HOST='a.tld -d b.tld'`, assert stderr contains `too many arguments` and the
client receives `-d a.tld -d b.tld`.

### BL-CFG-004

> **CORRECTED 2026-09-16.** The original rule was written before the hook's token support was
> known, and stated that `CF_EMAIL`/`CF_KEY` were the credentials and that nothing in this
> repository read them. Both halves are now out of date: `CF_API_TOKEN` is the preferred
> credential ([BL-CFG-005](#bl-cfg-005)), and the renewal script now reads all three names in its
> preflight ([BL-RENEW-006](#bl-renew-006)). It still does not read their *values* for any purpose
> other than checking presence, and still never sends them anywhere.

**Rule:** `CF_EMAIL` and `CF_KEY` are not read by any file in this repository. They are
consumed by the external hook process.
**Enforced:** absence. No file in this checkout references either name except the usage
examples at `README.md:7` and `README.md:8`.
**Consequence:** the validation, error messages, and failure behavior for missing or wrong
CloudFlare credentials are UNKNOWN-external, owned by
`SeattleDevs/letsencrypt-cloudflare-hook`.
**Test:** `grep -r CF_EMAIL` over the repo matches only `README.md`.

### BL-CFG-005

**Rule:** `CF_API_TOKEN` is the preferred credential. It and the `CF_EMAIL`/`CF_KEY` pair are
mutually exclusive: the hook reads the token first and only falls back to the pair when the token
is unset.
**Enforced:** the hook's own credential block (external); the preflight in `dehydrated`.
**Consequences:** `CF_EMAIL` is not required alongside a token, and `CF_KEY` must be a Global API
Key, not a scoped token. `CF_API_TOKEN` accepts several whitespace-separated tokens, each tried
until one can resolve the zone.
**Minimum token scope:** `Zone -> DNS -> Edit` and `Zone -> Zone -> Read`. The second is required
because the hook resolves the zone ID via `GET /zones?name=`; CloudFlare's `Edit zone DNS`
template omits it.
**Test:** run with only `CF_API_TOKEN` set and assert issuance succeeds.

### BL-CFG-006

**Rule:** `CF_HOST` accepts two forms. A value containing ` -d ` is treated as the legacy form and
expanded unquoted so its embedded flags split into the argument list. Any other non-empty value is
treated as a space-separated list of hostnames, each turned into its own `-d` pair.
**Enforced:** `dehydrated`, the `case` on `" ${CF_HOST} "`.
**Supersedes:** [BL-CFG-003](#bl-cfg-003). The branch test is now quoted, so the legacy form no
longer emits `[: too many arguments` on every run, while still producing an identical argument list.
**Test:** `CF_HOST='a.tld -d b.tld'` and `CF_HOST='a.tld b.tld'` must both yield
`-d a.tld -d b.tld`.

### BL-CFG-007

**Rule:** Ownership of the certificate store is set by `PUID` and `PGID`, defaulting to `nobody`
and `nogroup`.
**Enforced:** `dehydrated`, the `PUID`/`PGID` defaults and the `chown`.
**Supersedes:** [BL-CERT-001](#bl-cert-001). The defaults reproduce the previous behaviour exactly.
**Note on the defaults:** Alpine's `nogroup` is GID 65533 while `nobody`'s own primary group is GID
65534, so the default pair is deliberately mismatched for backwards compatibility. On Debian
`nogroup` is 65534, which is why this looks correct at a glance and is not.
**Why it exists:** once private keys became group-readable only
([BL-CERT-004](#bl-cert-004)), group membership decides who can read them, so a hardcoded group
would have forced every consumer to run as `nobody`.
**Test:** set `PGID` to a bare numeric GID with no matching group entry; the chown must still succeed.

## Certificate renewal

### BL-RENEW-001

> **RETIRED 2026-09-16.** The `cd` is now checked and aborts on failure. See [BL-RENEW-007](#bl-renew-007).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** The renewal script changes directory to `/dehydrated` without checking the result,
then invokes the ACME client by the relative path `./dehydrated`.
**Enforced:** `dehydrated:3`, `dehydrated:5`, `dehydrated:8`, `dehydrated:10`.
**Consequence:** every later path in the script, including `hooks/cloudflare/hook.py` and
`certs`, is relative to `/dehydrated`.

### BL-RENEW-002

> **RETIRED 2026-09-16.** The standalone `--register` call was removed. See [BL-RENEW-009](#bl-renew-009).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** Every run begins by registering an ACME account with the terms of service
auto-accepted. The exit status of the registration is ignored.
**Enforced:** `dehydrated:5` runs `./dehydrated --register --accept-terms` as a bare
statement, and the script has no `set -e` (`dehydrated:1-15`).
**Consequence:** on a container whose account directory already holds a key, this call is
redundant; on a recreated container it is a genuine new registration, see
[BL-IMG-011](#bl-img-011). Either way the script proceeds to issuance.
**Test:** run the script twice in one container, assert both runs reach the issuance command.

### BL-RENEW-003

**Rule:** Issuance and renewal always use `-t dns-01` with `-k hooks/cloudflare/hook.py`.
Neither the challenge type nor the hook path is configurable at runtime.
**Enforced:** `dehydrated` and `dehydrated`.
**Test:** no environment variable changes either argument; assert both invocations in the
script carry the same `-t` and `-k` values.

### BL-RENEW-004

> **RETIRED 2026-09-16.** The exit status is now deliberate rather than incidental. See [BL-RENEW-007](#bl-renew-007) and [BL-RENEW-008](#bl-renew-008).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** The exit status of the renewal script is the exit status of its last command, the
`find` at `dehydrated:15`. A failed certificate issuance does not make the script fail.
**Enforced:** `dehydrated:15` is the final statement and the script has no `set -e`
(`dehydrated:1-15`).
**Why it matters:** combined with [BL-IMG-009](#bl-img-009), a container whose very first
certificate issuance fails still starts `crond` and keeps running, because `find certs`
succeeded. Conversely, if `certs` does not exist, `find` fails, the script exits non-zero,
and the container exits without starting `crond`.
**Test:** make issuance fail (for example with an invalid `CF_KEY`) and assert the script
still exits 0 and the container stays up.

### BL-RENEW-005

**Rule:** The renewal script runs twice per container lifecycle pattern: once synchronously
at container start, and thereafter on the base image's daily cron schedule.
**Enforced:** `Dockerfile` for the start-up run, `Dockerfile` for placement in
`/etc/periodic/daily` which the base image's cron configuration executes.
**UNKNOWN-external:** the exact time of day is set by `/etc/crontabs/root` in the
`python:alpine` base image, not by this repository. `README.md:29` describes it as "once
daily". See [open-questions.md](./prd/appendix/open-questions.md).
**Test:** assert the file exists at `/etc/periodic/daily/dehydrated` and is executable.

### BL-RENEW-006

**Rule:** Before invoking the ACME client, the script checks that credentials are present: either
`CF_API_TOKEN`, or both `CF_EMAIL` and `CF_KEY`. With neither, it logs an error, records `FAIL`,
and exits without attempting issuance.
**Enforced:** `dehydrated`, the preflight block.
**Also catches:** `CF_API_TOKEN` set to the empty string, which the hook treats as no credentials
and which would otherwise surface as a failure partway through a challenge.
**Test:** run with no CloudFlare variables; assert the error message and a `FAIL` status.

### BL-RENEW-007

**Rule:** The script exits 0 in all normal operation, including when issuance fails. The only
non-zero exit is failure to enter `/dehydrated`.
**Enforced:** `dehydrated`, the final `exit 0` and the `cd ... || exit 1`.
**Supersedes:** [BL-RENEW-004](#bl-renew-004), where the exit status was incidentally that of a
trailing `find`.
**Why:** a transient CloudFlare or ACME outage must not tear the container down. Failure is
reported through the status file and the health check instead.
**Test:** force issuance to fail; assert exit 0, a `FAIL` status, and a container that stays up.

### BL-RENEW-008

**Rule:** The ownership and permission block runs only when `certs` exists.
**Enforced:** `dehydrated`, the `if [ -d certs ]` guard.
**Why:** dehydrated creates `CERTDIR` only as a side effect of processing at least one certificate.
A container with the default empty `domains.txt` and no `CF_HOST` never creates it, so the previous
unguarded `find certs` failed and, combined with the old `&&` in `CMD`, killed the container.
**Test:** run with no `CF_HOST` and an empty `domains.txt`; the container must stay up.

### BL-RENEW-009

**Rule:** There is no separate registration step. `-c --accept-terms` registers the account on the
first run and is a no-op afterwards.
**Enforced:** `dehydrated`, the single `./dehydrated -c --accept-terms ...` invocation.
**Supersedes:** [BL-RENEW-002](#bl-renew-002).
**Why:** the standalone `--register` took the lockfile and made a live call to the CA directory on
every run, so a CA outage failed it even when no certificate needed renewing.
**Test:** a first run registers; a second run does not re-register and still renews.

### BL-RENEW-010

**Rule:** Pathname expansion is disabled while `CF_HOST` is split into arguments.
**Enforced:** `dehydrated`, `set -f` around the domain-selection block.
**Why:** the splitting is deliberately unquoted, which also enables globbing. A wildcard
certificate such as `*.example.com` would otherwise expand against the working directory. dehydrated
guards its own `domains.txt` parser the same way.
**Test:** with files matching `*.example.com` present in the working directory,
`CF_HOST='*.example.com'` must still yield `-d *.example.com`.

## Certificate store permissions

### BL-CERT-001

> **RETIRED 2026-09-16.** Ownership is now configurable, with unchanged defaults. See [BL-CFG-007](#bl-cfg-007).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** After each run, everything under `certs` is owned by `nobody:nogroup`.
**Enforced:** `dehydrated:13`.
**Purpose:** lets an unprivileged process in another container read the certificates from
the shared volume.
**Test:** after a run, `stat -c '%U:%G' certs/<domain>/privkey.pem` reports `nobody:nogroup`.

### BL-CERT-002

> **RETIRED 2026-09-16.** Private keys are no longer world-readable. See [BL-CERT-004](#bl-cert-004).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** After each run, every file under `certs` is readable by all users, including
private keys.
**Enforced:** `dehydrated:14` runs `chmod -R ugo+r certs`.
**Consequence:** private key material is world-readable inside the container and on the
host path backing the volume. This is a deliberate consequence of the recursive mode, not
an accident of a single file, and it is recorded here so a consumer of the volume knows the
guarantee they are given and the exposure they inherit.
**Test:** after a run, the mode of `certs/<domain>/privkey.pem` includes `o+r`.

### BL-CERT-003

**Rule:** After each run, every directory under `certs` is traversable by all users.
**Enforced:** `dehydrated`.
**Test:** after a run, the mode of `certs/<domain>` includes `o+x`.

### BL-CERT-004

**Rule:** After each run, files under `certs` matching `privkey*` are not readable by others.
Everything else under `certs` remains world-readable, and directories remain world-traversable.
**Enforced:** `dehydrated`, the `find certs -name 'privkey*' -exec chmod o-rwx` line.
**Supersedes:** [BL-CERT-002](#bl-cert-002).
**Why the glob is prefix-only:** dehydrated also produces `privkey-<timestamp>.pem-revoked` and,
with rollover enabled, `privkey.roll.pem`. An extension-anchored glob such as `privkey*.pem` misses
those, and a missed key **fails open**, silently staying world-readable.
**Breaking change:** a consumer reading the volume as a UID outside the configured group loses
access, and will fail its TLS handshake rather than reporting a permission error.
**Test:** after issuance, no `privkey*` file has the other-read bit, while `fullchain.pem` does.

### BL-CERT-005

**Rule:** dehydrated writes everything with `umask 077`, so the recursive `chmod` in this
repository exists to *loosen* the public material, not to tighten anything.
**Enforced:** upstream `dehydrated` (`umask 077`); `dehydrated`, the `chmod -R ugo+r certs` line.
**Why it is documented:** the loosening looks like an oversight and is not. Removing it would leave
certificates at `0600` and break every consumer that reads the shared volume.
**Not loosened:** the ACME account key at `accounts/<CAHASH>/account_key.pem` keeps upstream's
`0600` deliberately.
**Test:** `fullchain.pem` is world-readable after a run even though dehydrated wrote it `0600`.

## Continuous integration

### BL-CI-001

> **RETIRED 2026-09-16.** The blind weekly rebuild was replaced by a change-triggered watcher. See [BL-CI-009](#bl-ci-009).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** The image is built and pushed on every push to `main` and every Monday at
06:00 UTC.
**Enforced:** `.github/workflows/docker.yml:5` (`cron: '0 6 * * 1'`),
`.github/workflows/docker.yml:6-8` (push to `main`).
**Why it matters:** the weekly schedule is the mechanism that picks up new upstream commits
from the unpinned clones in [BL-IMG-004](#bl-img-004) and [BL-IMG-005](#bl-img-005).

### BL-CI-002

> **RETIRED 2026-09-16.** An immutable upstream-derived tag is published alongside `latest`. See [BL-CI-012](#bl-ci-012).
> The original rule is kept verbatim below because rule IDs are stable.

**Rule:** The only published tag is `latest`. No version, date, or commit tag is pushed.
**Enforced:** `.github/workflows/docker.yml:34`.
**Consequence:** consumers cannot pin to a known-good build, and cannot roll back by tag.
**Test:** the workflow's `tags` input contains exactly one entry.

### BL-CI-003

**Rule:** The published manifest covers exactly seven platforms: `linux/386`, `linux/amd64`,
`linux/arm64/v8`, `linux/arm/v6`, `linux/arm/v7`, `linux/ppc64le`, `linux/s390x`.
**Enforced:** `.github/workflows/docker.yml:33`.
**History note:** `linux/mips64le` was added in commit a464077 and removed in commit 9a4a1cd.
It is not part of the current contract.
**Test:** `docker manifest inspect kjake/dehydrated-cloudflare-cron:latest` lists seven entries.

### BL-CI-004

**Rule:** Registry authentication uses the repository secrets `DOCKER_USERNAME` and
`DOCKER_PASSWORD`. No credential is present in the repository.
**Enforced:** `.github/workflows/docker.yml:28-29`.

### BL-CI-005

**Rule:** The vulnerability scan never fails the build.
**Enforced:** `.github/workflows/anchore.yml:37` sets `fail-build: false`.
**Consequence:** a critical finding is reported to GitHub code scanning and does not block
a merge or a publish.

### BL-CI-006

**Rule:** The scan reports only `critical` severity findings that have a fix available.
**Enforced:** `.github/workflows/anchore.yml:38` (`severity-cutoff: critical`),
`.github/workflows/anchore.yml:39` (`only-fixed: true`).
**Consequence:** high, medium, and low findings, and unfixed critical findings, are not
surfaced.

### BL-CI-007

**Rule:** The scan runs on every push to `main`, every pull request targeting `main`,
and every Thursday at 05:24 UTC.
**Enforced:** `.github/workflows/anchore.yml:10-16`.

### BL-CI-008

> **CORRECTED 2026-09-16.** The original rule inferred that the SARIF upload might be failing
> because no `permissions:` block was declared. That inference was wrong and is recorded here
> rather than quietly deleted. The repository's `default_workflow_permissions` is `write`, and
> code scanning is enabled with a successful analysis on 2026-03-12, so permissions were never
> the blocker. The uploads that failed from 2026-04-02 onward did so for another reason, most
> likely the four-major-version action rot documented in [BL-CI-011](#bl-ci-011).

**Rule:** Both workflows now declare an explicit `permissions:` block.
**Enforced:** `.github/workflows/anchore.yml` (`contents: read`, `security-events: write`),
`.github/workflows/docker.yml` (`contents: read`),
`.github/workflows/watch-upstream.yml` (`contents: write`),
`.github/workflows/build-check.yml` (`contents: read`),
`.github/workflows/dependabot-automerge.yml` (`contents: write`, `pull-requests: write`).
**Why:** least privilege. This narrows the token from the repository default, it does not widen it.
**Test:** every workflow file contains a top-level `permissions:` key.

### BL-CI-009

**Rule:** The image rebuilds when any of three upstream inputs changes: the default-branch commit
of `dehydrated-io/dehydrated` (branch `master`), the default-branch commit of
`SeattleDevs/letsencrypt-cloudflare-hook` (branch `main`), or the manifest digest of
`python:alpine`. The check runs every 12 hours.
**Enforced:** `.github/workflows/watch-upstream.yml`, the `check` job.
**Why it matters:** nothing in this repository is pinned, so a rebuild is the only way upstream
fixes reach users. The previous design rebuilt blindly every Monday whether or not anything had
changed, and recorded nothing about what it produced.
**Note:** the two upstreams use different default branch names. Do not assume one for the other.
**Test:** run the workflow twice with no upstream movement; the second run must report
`changed=false` and must not publish.

### BL-CI-010

**Rule:** The composite `state_key` is the first 12 hex characters of the SHA-256 of the three
upstream identities concatenated. It is recorded in `.upstream-state.json` only after a successful
publish.
**Enforced:** `.github/workflows/watch-upstream.yml`, the `resolve` and `record` steps.
**Why the ordering matters:** recording before the publish succeeded would mark a failed build as
done and skip the retry on the next run.
**Test:** force the publish job to fail; assert `.upstream-state.json` is unchanged and the next
run still reports `changed=true`.

### BL-CI-011

**Rule:** Dependabot tracks GitHub Actions only, grouped into a single pull request, and those
pull requests are merged automatically.
**Enforced:** `.github/dependabot.yml`, `.github/workflows/dependabot-automerge.yml`.
**Why the scope is narrow:** Dependabot has no ecosystem that can read a `git clone` inside a
Dockerfile `RUN` line, so it cannot see either upstream project. The base image tag carries no
version to bump. Actions are the only dependency here it can meaningfully track, and they had
rotted by up to four major versions.
**Safety precondition:** automerge is only safe because the `build` check from
`build-check.yml` is a required status check on `main`. Without a required check that can fail,
`gh pr merge --auto` finds the pull request immediately mergeable and merges it on the spot,
unreviewed and unbuilt.
**Test:** open a pull request that breaks the Docker build; assert it is not merged.

### BL-CI-012

**Rule:** Every published build carries `latest` plus an immutable `u<state_key>` tag.
**Enforced:** `.github/workflows/docker.yml`, the `Compute tags` step.
**Why the tag derives from all three inputs:** a tag keyed on dehydrated alone would be reused
when only the base image moved, silently overwriting a previous build and destroying its value
for rollback.
**Test:** two builds differing only in base image digest must produce different `u` tags.

### BL-CI-013

**Rule:** Scheduled workflows in this repository must not go 60 days without a commit, or GitHub
disables them.
**Enforced:** `.github/workflows/watch-upstream.yml`, the `record` and `heartbeat` jobs. The
heartbeat pushes an empty commit once the last commit is 50 days old.
**Why it exists:** both workflows were found in state `disabled_inactivity` on 2026-09-16, having
last run on 2026-04-30. The published image was consequently frozen for roughly 4.5 months while
carrying 13 open critical CVEs. Any schedule-driven design reintroduces this failure without a
keepalive.
**Test:** assert the heartbeat job triggers when `git log -1 --format=%ct` is older than 50 days.

## State machines

### Container startup

Source: `Dockerfile` (`CMD`), `dehydrated`.

| From | To | Trigger | Guard | Side effects |
|---|---|---|---|---|
| created | first-run | `docker start` | none | renewal script runs synchronously |
| first-run | scheduled | script finishes | always, because the command uses `;` not `&&` | `crond` starts as PID 1 and holds the container open |
| first-run | exited | script exits non-zero | only when `/dehydrated` cannot be entered | container exits; this is a broken image, not a runtime failure |
| scheduled | scheduled | daily cron at 02:00 container-local | none | script runs again, permissions reapplied, status file rewritten |

The previous version had a fourth transition, `first-run -> exited` on any non-zero exit, which
fired when `certs` did not exist. Both causes are now removed: see
[BL-IMG-012](#bl-img-012) and [BL-RENEW-008](#bl-renew-008).

### Health status

Source: `healthcheck`, `Dockerfile` (`HEALTHCHECK`).

| From | To | Trigger | Guard |
|---|---|---|---|
| starting | starting | check runs within the 5 minute start period | no status file yet |
| starting | unhealthy | start period elapses with no successful run | status file absent or `FAIL` |
| any | healthy | a run records `OK` | status file's first field is `OK` |
| healthy | unhealthy | a later run records `FAIL` | issuance failed |

The container keeps running in every unhealthy state; cron retries daily.

### Certificate lifecycle

UNKNOWN-external. The decision to renew an existing certificate, the renewal threshold, and
the on-disk state transitions are implemented in `dehydrated-io/dehydrated`, which is cloned
at build time (`Dockerfile`) and is not present in this checkout. This repository invokes
`-c` (`dehydrated`, `dehydrated`) and applies ownership and modes to the result. Do not
assume a threshold value; resolve it from the upstream project at the pinned build date.

## Known inconsistencies

Most of the original entries were fixed on 2026-09-16. They are listed with their outcome rather
than deleted, so the history stays legible.

| # | Inconsistency | Status |
|---|---|---|
| 1 | `apk add` with no package arguments | **Fixed.** Line removed. It was a no-op that still fetched the repository index |
| 2 | `ADD` used for a plain local file | **Fixed.** Now `COPY` |
| 3 | The cleanup deleted `/var/tmp` itself rather than its contents | **Fixed.** Now targets the contents, matching its sibling patterns |
| 4 | Unquoted expansion inside `[ ... ]` emitted `[: too many arguments` on every multi-domain run | **Fixed.** The test is quoted; the legacy value form still works. See [BL-CFG-006](#bl-cfg-006) |
| 5 | ACME account re-registered on every run | **Fixed.** See [BL-RENEW-009](#bl-renew-009) |
| 6 | The repo script and the upstream executable share the name `dehydrated` | **Open.** Harmless: different paths, and the script invokes `./dehydrated` after `cd`. Still makes `ps` output ambiguous |
| 7 | `README.md` described daily renewal unconditionally, but it was gated on the first run succeeding | **Fixed.** The gate is gone ([BL-IMG-012](#bl-img-012)) and the README now states the 02:00 schedule |

### Remaining, accepted

- **Nothing is version-pinned.** The base image and both upstream projects float. This is
  deliberate: the watcher rebuilds on change, so pinning would add maintenance without adding
  safety. The cost is that a Python major version jump arrives unannounced; the watcher emits a
  notice when it happens. See [BL-CI-009](#bl-ci-009).
- **The default ownership pair is mismatched** (`nobody` is 65534, `nogroup` is 65533). Preserved
  for backwards compatibility rather than corrected. See [BL-CFG-007](#bl-cfg-007).

## Open questions

Behavior visible in code whose intent cannot be determined from this checkout. The full
list, with resolution steps, is in
[docs/prd/appendix/open-questions.md](./prd/appendix/open-questions.md).

- Is the world-readable private key mode at `dehydrated` intentional for consumption by
  other containers, or an over-broad recursive `chmod`? The code does not say.
- Is the absence of an `accounts` volume ([BL-IMG-011](#bl-img-011)) deliberate or an oversight?
- Why is the platform list what it is, and why was `linux/mips64le` removed in commit 9a4a1cd?
  The commit message "Tweak buildx" does not say.
