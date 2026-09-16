# Enum and Constant Dictionary

Every closed value set in this repository. There are no programming-language enums: the closed sets
are branch conditions, fixed CLI arguments, action inputs, status values, and permission modes. All
values are literal, copied from source.

## 1. Credential mode

- Source: the renewal script's preflight, and the hook's own credential block
- Used by: every run

| Condition | Mode | Effect |
|---|---|---|
| `CF_API_TOKEN` non-empty | Token | `Authorization: Bearer`. Preferred. Multiple whitespace-separated tokens tried in order |
| `CF_API_TOKEN` unset or empty, both `CF_EMAIL` and `CF_KEY` non-empty | Legacy | `X-Auth-Email` + `X-Auth-Key`. Deprecated; warns at runtime. `CF_KEY` must be a Global API Key |
| Neither | None | Preflight logs an error, records `FAIL`, exits 0 without contacting anything |

See [BL-CFG-005](../../BUSINESS-LOGIC.md#bl-cfg-005).

## 2. CF_HOST domain-source mode

- Source: the renewal script's `case` on `" ${CF_HOST} "`

| Value of `CF_HOST` | Mode | Effect |
|---|---|---|
| unset | Domains file | No `-d`; domains come from `domains.txt` |
| `''` | Domains file | Identical to unset |
| contains ` -d ` | Legacy passthrough | Expanded unquoted so embedded flags split into the argument list |
| any other non-empty value | Hostname list | One `-d` per whitespace-separated name, each quoted |

Globbing is disabled throughout, so wildcard names survive. See
[BL-CFG-006](../../BUSINESS-LOGIC.md#bl-cfg-006) and
[BL-RENEW-010](../../BUSINESS-LOGIC.md#bl-renew-010).

## 3. Required CloudFlare token permissions

- Source: the hook's call pattern; CloudFlare API reference

| Dashboard dropdowns | API reference name | Needed for |
|---|---|---|
| Zone / DNS / Edit | `DNS Write` | Creating, listing, and deleting the challenge TXT record |
| Zone / Zone / Read | `Zone Read` | Resolving the zone ID via `GET /zones?name=` |

Zone Resources must be **Include** -> **Specific zones**. CloudFlare's `Edit zone DNS` template
grants only the first row.

## 4. ACME challenge type and hook path

- Source: the renewal script's fixed arguments. Not configurable without rebuilding.

| Argument | Value |
|---|---|
| `-t` | `dns-01` |
| `-k` | `hooks/cloudflare/hook.py` |

## 5. Certificate store permission modes

- Source: the renewal script's ownership block

| Value | Applies to | Meaning |
|---|---|---|
| `${PUID}:${PGID}`, default `nobody:nogroup` | every path under `certs`, recursively | Owner and group after each run |
| `ugo+r` | every file under `certs` | Read for all, then partially revoked below |
| `o-rwx` | files matching `privkey*` | Private keys are not readable by others |
| `ugo+x` | directories under `certs` | Traversable by all |
| `0600` (upstream default, untouched) | `accounts/<CAHASH>/account_key.pem` | Deliberately not loosened |

## 6. Run status values

- Source: the renewal script's status file; the health check

| Value | Meaning | Health result |
|---|---|---|
| `OK` | The ACME client exited zero | healthy |
| `FAIL` | Issuance failed, or credentials were missing | unhealthy |
| (file absent) | No run has completed yet | unhealthy, expected during the start period |

## 7. Published target platforms

- Source: `.github/workflows/docker.yml`, the `platforms` input

`linux/386`, `linux/amd64`, `linux/arm64/v8`, `linux/arm/v6`, `linux/arm/v7`, `linux/ppc64le`,
`linux/s390x`.

Retired value: `linux/mips64le`, present between commits a464077 and 9a4a1cd.

## 8. Published image tags

| Value | When | Meaning |
|---|---|---|
| `latest` | every publish | Most recent build |
| `u<state_key>` | only when the watcher supplies one | Immutable identity of the three upstreams. 12 hex characters |

## 9. Local-only build tags

| Value | Where | Pushed? |
|---|---|---|
| `dehydrated-cloudflare-cron:pr` | `build-check.yml` | No |
| `localbuild/testimage:latest` | `anchore.yml` | No |

## 10. Scan action inputs

- Source: `.github/workflows/anchore.yml`. The full allowed set for each is defined by the
  external action.

| Input | Value | Meaning |
|---|---|---|
| `output-format` | `sarif` | Required by the upload step |
| `fail-build` | `false` | Findings never fail the job |
| `severity-cutoff` | `critical` | Only critical findings reported |
| `only-fixed` | `true` | Only findings with an available fix |

The last two together mean an empty result set is consistent with an image carrying many known
vulnerabilities.

## 11. Workflow triggers and schedules

| Value | Where | Meaning |
|---|---|---|
| `0 */12 * * *` | `watch-upstream.yml` | Every 12 hours UTC, upstream check |
| `24 5 * * 4` | `anchore.yml` | Thursdays 05:24 UTC, vulnerability scan |
| `weekly` | `dependabot.yml` | GitHub Actions update check |
| `master` | all workflows | The only branch any workflow reacts to |
| `0 2 * * *` (base image) | `alpine-baselayout` crontab | The in-container daily job, 02:00 local |

The former `0 6 * * 1` weekly rebuild was retired in favour of the watcher.

## Sets deliberately not closed here

| Set | Why it is open |
|---|---|
| `domains.txt` grammar values | Defined upstream. Documented in [data-dictionary.md](./data-dictionary.md) |
| ACME client exit codes | Only 0 and 1 in practice, but `_openssl` can propagate others. Test non-zero |
| Base image package versions | `python:alpine` floats by design |
