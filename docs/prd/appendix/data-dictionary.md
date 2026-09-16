# Data Dictionary

No database, ORM, or migration history. Persistent state is a filesystem tree on Docker volumes,
plus one input file and three small state files. This appendix records what this repository
guarantees about each, and marks where a layout is defined upstream.

## Relationship graph

```
/dehydrated/domains.txt   (input, operator-supplied)      CF_HOST (input, environment)
        |                                                        |
        +-------------------> ACME issuance <--------------------+
                                     |
        +----------------------------+----------------------------+
        |                            |                            |
        v                            v                            v
/dehydrated/accounts          /dehydrated/certs          /run/dehydrated.status
  account key, volume           certificates, volume       last run outcome
  left at 0600                  perms normalized each run  read by healthcheck

.upstream-state.json (repo)         /etc/dehydrated-build-info (image)
  what the watcher last published     what the build actually cloned
```

## `/dehydrated/certs`

- Declared volume. Bind-mounted in documented usage; anonymous otherwise.
- Written by the upstream ACME client, then adjusted by the renewal script every run.

### Guarantees this repository makes

| Property | Value | Applies to | Rule |
|---|---|---|---|
| Owner | `PUID`, default `nobody` | every path, recursively | [BL-CFG-007](../../BUSINESS-LOGIC.md#bl-cfg-007) |
| Group | `PGID`, default `nogroup` | every path, recursively | [BL-CFG-007](../../BUSINESS-LOGIC.md#bl-cfg-007) |
| Read for all | user, group, other | every file **except** `privkey*` | [BL-CERT-005](../../BUSINESS-LOGIC.md#bl-cert-005) |
| No access for others | `o-rwx` | every file matching `privkey*` | [BL-CERT-004](../../BUSINESS-LOGIC.md#bl-cert-004) |
| Traverse for all | user, group, other | every directory | [BL-CERT-003](../../BUSINESS-LOGIC.md#bl-cert-003) |
| Reapplication | after every run, renewed or not | whole tree | [BL-CERT-005](../../BUSINESS-LOGIC.md#bl-cert-005) |

The loosening exists because dehydrated writes everything `0600` under `umask 077`. Removing it
would break every consumer reading the shared volume.

### Internal layout

Defined by dehydrated, not by this repository. Established from upstream v0.7.2 source:

| Name | Kind | Private key? |
|---|---|---|
| `privkey-<timestamp>.pem` | real file | **yes** |
| `privkey.pem` | symlink to the above | **yes** |
| `privkey.roll.pem` | real file, only when `PRIVATE_KEY_ROLLOVER="yes"` (not the default) | **yes** |
| `privkey-<timestamp>.pem-revoked` | real file | **yes** |
| `cert-<timestamp>.pem`, `cert.pem` | real file, symlink | no |
| `chain-<timestamp>.pem`, `chain.pem` | real file, symlink | no |
| `fullchain-<timestamp>.pem`, `fullchain.pem` | real file, symlink | no |
| `cert-<timestamp>.csr`, `cert.csr` | real file, symlink | no |
| `ocsp-<timestamp>.der`, `ocsp.der` | only when `OCSP_FETCH="yes"` | no |

Every private key matches the prefix `privkey*`, which is why the restricting glob is prefix-only
rather than extension-anchored: `privkey*.pem` would miss the `-revoked` form and fail open.

`fullchain` is certificate plus chain only; dehydrated never writes key material into a combined
bundle. The one private key it writes outside `CERTDIR` is the TLS-ALPN-01 key, which does not
apply here because the challenge type is fixed to `dns-01`.

## `/dehydrated/accounts`

- **Now a declared volume.** Previously container-local and discarded on every recreate.
- Layout: `accounts/<CAHASH>/account_key.pem`, plus `registration_info.json`, `account_id.json`,
  and optional `config` and `deactivated`. `CAHASH` is the urlbase64 of the CA directory URL, not
  a readable name.
- Permissions: left at dehydrated's `0600`. **Deliberately not loosened.**

## `/dehydrated/domains.txt`

- Created empty at build; replaced by an operator bind mount, read-only in documented usage.
- Read by the upstream client only in domains-file mode. Never written by this repository.

Grammar, established from upstream source:

| Rule | Detail |
|---|---|
| One certificate per line | first name is the CN, the rest are SANs |
| Separator | whitespace; runs collapse |
| Comments | `#` only as the first non-whitespace character. **No inline comments** |
| Blank lines | skipped |
| Case | everything is lowercased, including aliases |
| Alias | `>alias` names the output directory; at most one per line |
| Wildcards | a wildcard first name requires an explicit alias |
| Drop-ins | `domains.txt.d/*.txt` is appended in glob order |

## `/run/dehydrated.status`

Written by the renewal script every run; read by the health check.

| Field | Type | Values | Example |
|---|---|---|---|
| status | string | `OK` or `FAIL` | `OK` |
| timestamp | UTC ISO-8601 | `%Y-%m-%dT%H:%M:%SZ` | `2026-09-16T02:00:11Z` |

One line, space-separated: `OK 2026-09-16T02:00:11Z`. Lives in `/run` deliberately, so it is
neither swept into the user's certs volume nor subject to the recursive `chmod`. Absent until the
first run completes, which the health check's start period accommodates. Contains no credentials.

## `.upstream-state.json`

Committed to `master` by the watcher after a successful publish. This commit is also what keeps
the repository active enough that GitHub does not disable the schedule.

| Field | Type | Example |
|---|---|---|
| `dehydrated_revision` | 40-char commit sha | `a1b2c3...` |
| `hook_revision` | 40-char commit sha | `d4e5f6...` |
| `base_digest` | image digest | `sha256:...` |
| `python_version` | major.minor | `3.14` |
| `state_key` | 12 hex chars | `0f3c9d2e5b71` |
| `updated` | UTC ISO-8601 | `2026-09-16T06:00:00Z` |

`state_key` is the first 12 hex characters of the SHA-256 of the three identities concatenated,
and becomes the immutable image tag `u<state_key>`.

## `/etc/dehydrated-build-info`

Written into the image during the build, recording what `git clone` actually fetched.

```
dehydrated=<40-char sha>
hook=<40-char sha>
built=<UTC ISO-8601>
```

This differs from the OCI labels only if upstream moved between the watcher's observation and the
build; the next watcher run reconciles it.

## Secrets

Names and purposes only. No value appears in this repository.

| Name | Kind | Where it lives | Reaches |
|---|---|---|---|
| `CF_API_TOKEN` | Zone-scoped CloudFlare token | Container environment | The hook. Presence checked by the preflight |
| `CF_EMAIL` / `CF_KEY` | Legacy account email and **Global API Key** | Container environment | The hook, only when no token is set |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Registry credentials | GitHub repository secrets | `docker/login-action` |
| `GITHUB_TOKEN` | Actions token | Provided per run | `gh api` in the watcher and automerge workflows |
| ACME account key | Private key | `/dehydrated/accounts` volume | The upstream client. Left at `0600` |
| Certificate private keys | Private keys | `/dehydrated/certs` volume | Readers in `PGID` only |

## Migrations

**None.** There is no schema. A change to the certificate layout would arrive through an upstream
update on an unpinned clone, with no migration step. The watcher at least makes such a change
visible, by recording which upstream commit each published image was built from.
