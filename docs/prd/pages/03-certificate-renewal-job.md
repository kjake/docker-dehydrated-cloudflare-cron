# Certificate Renewal Job

> Surface type: background job
> Address: `/etc/periodic/daily/dehydrated` inside the container (repo file `dehydrated`)
> Schedule: once synchronously at container start, then daily at **02:00 container-local time**
> Source: `dehydrated`, placed by `Dockerfile`
> Consumed by: busybox `crond` and the container command. No human invokes it by name.
> Auth or permissions: runs as root (no `USER` directive), required for the `chown`. Authenticates to CloudFlare only indirectly, through the environment the hook inherits.

## Overview

The only code in this repository that runs at runtime. It is the glue between the two cloned
upstream projects: it verifies credentials are present, chooses where domains come from, invokes
the ACME client over DNS-01, then normalizes ownership and permissions on the output so other
containers can consume the shared volume.

Its defining property is that it **fails soft**. Issuance failure does not stop the container,
because a transient CloudFlare or ACME outage should not require operator intervention. Failure is
reported through a status file that the container health check reads, not through the exit status.

## Pipeline

```
1  cd /dehydrated                                    checked; abort is the only hard failure
2  credential preflight                              CF_API_TOKEN, else CF_EMAIL+CF_KEY, else FAIL
3  domain selection (set -f, globbing disabled)
     CF_HOST empty      -> no -d, domains.txt is used
     CF_HOST has " -d "  -> legacy passthrough, unquoted expansion
     otherwise          -> one -d per whitespace-separated name
4  ./dehydrated -c --accept-terms -t dns-01 -k hooks/cloudflare/hook.py [args]
     captures success or failure into run_status
5  if certs/ exists:
     chown -R $PUID:$PGID certs
     chmod -R ugo+r certs                            loosens upstream's umask 077
     chmod ugo+x on directories
     chmod o-rwx on privkey*                         prefix glob, covers -revoked
6  write OK|FAIL + UTC timestamp to /run/dehydrated.status
7  exit 0
```

No locking, timeout, retry, or concurrency guard is added by this repository. dehydrated takes its
own lockfile.

## Parameters

Takes no arguments; `$1` and `$@` are never referenced. Reads `CF_HOST`, `PUID`, `PGID`, and checks
the presence of `CF_API_TOKEN` / `CF_EMAIL` / `CF_KEY`. Full semantics in
[02-runtime-configuration.md](./02-runtime-configuration.md).

Fixed, non-configurable arguments to the ACME client:

| Argument | Value | Configurable |
|---|---|---|
| `-c` | cron mode, issue or renew as needed | No |
| `--accept-terms` | auto-accepts the CA terms, and auto-registers on first run | No |
| `-t` | `dns-01` | No |
| `-k` | `hooks/cloudflare/hook.py` | No |

There is no separate `--register` step. See
[BL-RENEW-009](../../BUSINESS-LOGIC.md#bl-renew-009).

## Runs

### Run at container start

- Trigger: `docker start`, via the exec-form `CMD`.
- Behavior: the full pipeline runs synchronously before `crond` starts.
- Outputs: certificates under `/dehydrated/certs`, account key under `/dehydrated/accounts`, log
  output on stdout and stderr, and a status file.
- Success: exit 0, after which `crond` starts as PID 1 and holds the container open.
- Failure: the only non-zero exit is failure to enter `/dehydrated`, which indicates a broken
  image. Every other failure still exits 0 and the container proceeds to scheduled operation.

### Daily scheduled run

- Trigger: busybox cron executing `run-parts /etc/periodic/daily` at 02:00 container-local time.
- Behavior: identical pipeline. The client renews a certificate once it is within
  **32 days** of expiry, and generates a **new private key** on each renewal by default.
- Outputs: unchanged files when nothing is due. Ownership and modes are reapplied unconditionally
  every run, whether or not a certificate changed.

### Run with a failing issuance

- Trigger: wrong or expired credential, CloudFlare outage, ACME rate limit, or a zone the
  credential cannot edit.
- Behavior: the client's failure is captured, an error is logged, and the permission block still
  runs on whatever exists.
- Signal: status file records `FAIL`, the container reports `unhealthy`, and it keeps running so
  cron retries tomorrow.
- Note: dehydrated's exit codes are only 0 and 1 and do not distinguish "nothing to do" from
  "renewed", so this job reports success for both.

### Run with no domains configured

- Trigger: `CF_HOST` unset and no `domains.txt` mounted.
- Behavior: the client has nothing to do and exits 0. `certs/` is never created, because
  dehydrated creates it only as a side effect of processing a certificate.
- The guard at step 5 is what makes this safe. Without it the trailing `find` failed and, under the
  old `&&` container command, killed the container. See
  [BL-RENEW-008](../../BUSINESS-LOGIC.md#bl-renew-008).

### Run with no credentials

- Behavior: the preflight stops at step 2, before any network call.
- Signal: explicit error naming both accepted credential forms, `FAIL` status, exit 0.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| `/dehydrated/dehydrated` | Upstream executable, cloned at build | ACME registration, issuance, renewal | Run records `FAIL`; container stays up |
| `hooks/cloudflare/hook.py` | Upstream Python hook | DNS TXT record management for the challenge | Issuance fails; recorded as `FAIL` |
| `bash` | Interpreter | The script requires bash specifically, not `sh` | Script cannot run |
| CloudFlare API, ACME provider | Network services | Challenge and certificate issuance | Recorded as `FAIL` |
| `/dehydrated/certs` | Filesystem path | Output | Absence is handled by the step 5 guard |
| `/run` | Filesystem path | Status file location | A write failure warns but does not fail the run |
| `chown`, `chmod`, `find`, `date` | busybox binaries | Permission normalization and timestamping | Warn individually; the run continues |

## Relationships

- Invoked by: the container command and busybox cron, both described in
  [01-container-image.md](./01-container-image.md).
- Invokes: the upstream ACME client, which invokes the CloudFlare hook.
- Reads: configuration from [02-runtime-configuration.md](./02-runtime-configuration.md).
- Writes: `/dehydrated/certs`, `/dehydrated/accounts`, and `/run/dehydrated.status`, described in
  [data-dictionary.md](../appendix/data-dictionary.md).
- Read by: the `healthcheck` script, via the status file.
- Side effects on other units: the recursive `chown` and `chmod` change permissions of files this
  script did not create, which is what makes the certs volume consumable by a neighbouring
  container.

## Business Rules

1. Credentials are verified before any network call; absence is a loud, non-fatal failure. See
   [BL-RENEW-006](../../BUSINESS-LOGIC.md#bl-renew-006).
2. The script exits 0 in all normal operation; only failure to enter `/dehydrated` exits non-zero.
   See [BL-RENEW-007](../../BUSINESS-LOGIC.md#bl-renew-007).
3. The permission block is guarded on `certs` existing. See
   [BL-RENEW-008](../../BUSINESS-LOGIC.md#bl-renew-008).
4. No separate registration step; `-c --accept-terms` covers it. See
   [BL-RENEW-009](../../BUSINESS-LOGIC.md#bl-renew-009).
5. Globbing is disabled while splitting `CF_HOST`, so wildcard certificates work. See
   [BL-RENEW-010](../../BUSINESS-LOGIC.md#bl-renew-010).
6. Private keys end every run not readable by others, matched by a prefix glob that covers
   revoked and rollover forms. See [BL-CERT-004](../../BUSINESS-LOGIC.md#bl-cert-004).
7. The public material is deliberately loosened from upstream's `umask 077`. See
   [BL-CERT-005](../../BUSINESS-LOGIC.md#bl-cert-005).
8. Challenge type and hook path are fixed at `dns-01` and `hooks/cloudflare/hook.py`. See
   [BL-RENEW-003](../../BUSINESS-LOGIC.md#bl-renew-003).
