# Runtime Configuration

> Surface type: config and policy domain
> Address: `docker create -e ... -v ...` against `kjake/dehydrated-cloudflare-cron`
> Source: `dehydrated` (preflight and domain selection), `Dockerfile` (volumes, defaults), `README.md`
> Consumed by: the operator, at container create time
> Auth or permissions: the operator supplies a CloudFlare credential able to write DNS records for the target zones. Scope is enforced by CloudFlare, not here. See [BL-CFG-005](../../BUSINESS-LOGIC.md#bl-cfg-005).

## Overview

This is the entire contract an operator must satisfy. There is no config file owned by this
repository, no command-line flags, and no runtime API: configuration is environment variables and
mount points, fixed at `docker create` time and never re-read afterwards.

Two decisions are made here. **Which credential** is used, where a zone-scoped API token is
strongly preferred over the legacy global key. And **where the domain list comes from**, which is
selected by whether `CF_HOST` is set.

## Command tree

No subcommands. Two independent axes.

```
Credential                                                        selected by the hook
  CF_API_TOKEN set          -> Authorization: Bearer <token>       tried FIRST
  otherwise CF_EMAIL+CF_KEY -> X-Auth-Email + X-Auth-Key           deprecated, warns at runtime
  neither                   -> preflight fails loudly              dehydrated:preflight

Domain source                                                     selected by this repo
  CF_HOST unset or empty    -> /dehydrated/domains.txt
  CF_HOST is a list         -> -d <host> per name
  CF_HOST contains " -d "   -> legacy passthrough, identical result
```

The two axes are independent: any credential form works with any domain form.

## Fields

### Credentials

| Name | Type | Required | Default | Allowed values | Notes |
|---|---|---|---|---|---|
| `CF_API_TOKEN` | string (secret) | Yes, unless the legacy pair is used | none | One token, or several separated by whitespace | Preferred. Tried before the legacy pair. Multiple tokens are tried in order until one resolves the zone. Set-but-empty is treated as absent and fails the preflight |
| `CF_EMAIL` | string (email) | Legacy path only | none | CloudFlare account email | Read **only** when `CF_API_TOKEN` is unset. Ignored otherwise |
| `CF_KEY` | string (secret) | Legacy path only | none | A CloudFlare **Global API Key** | Must be a global key, not a scoped token. Sent as `X-Auth-Key`. The hook warns that this path is deprecated |

Minimum token scope is two permissions, in dashboard wording: **Zone -> DNS -> Edit** and
**Zone -> Zone -> Read**. The API reference spells the same two `DNS Write` and `Zone Read`.
CloudFlare's `Edit zone DNS` template grants only the first, so a token built from the template
alone fails at the initial zone lookup.

### Domain selection and behavior

| Name | Type | Required | Default | Allowed values | Notes |
|---|---|---|---|---|---|
| `CF_HOST` | string | No | unset, meaning domains-file mode | Empty, a space-separated hostname list, or the legacy form carrying its own `-d` flags | The only variable this repo interprets. Globbing is disabled while it is split, so wildcard names survive |
| `CF_DNS_SERVERS` | string | No | hook default | Resolver addresses | Consumed by the hook. Overrides the resolvers used to confirm propagation |
| `CF_SETTLE_TIME` | integer (seconds) | No | `10` | Any integer the hook accepts | Consumed by the hook |
| `CF_DEBUG` | any | No | unset | Presence-checked | Consumed by the hook. Verbose logging |
| `PUID` | string or numeric UID | No | `nobody` | Any user name or numeric UID | Owner applied to `certs`. Numeric values pass straight through |
| `PGID` | string or numeric GID | No | `nogroup` | Any group name or numeric GID | Group applied to `certs`. Decides who can read private keys |

### Mount points

| Path in container | Kind | Required | Default without a mount | Notes |
|---|---|---|---|---|
| `/dehydrated/certs` | Volume, read-write | Strongly recommended | Anonymous volume, declared in `Dockerfile` | Certificate output |
| `/dehydrated/accounts` | Volume, read-write | Recommended | Anonymous volume, declared in `Dockerfile` | ACME account key. Bind it to survive `docker rm`, otherwise each recreate spends a new-account registration |
| `/dehydrated/domains.txt` | Bind mount, read-only | Domains-file mode only | Empty file created at build | Grammar defined upstream: one certificate per line, space-separated names, first is the CN, `#` only as the first non-whitespace character, all lowercased, `>alias` names the output directory |

### Precedence

| Situation | Winner |
|---|---|
| `CF_API_TOKEN` and the legacy pair both set | The token. The hook warns the pair is unnecessary |
| `CF_API_TOKEN` set but empty | Neither. Treated as absent and the preflight fails |
| `CF_HOST` set and a `domains.txt` mounted | `CF_HOST` supplies `-d`; the file is still read by the client |
| `CF_HOST` empty and a `domains.txt` mounted | The file |
| Nothing set or mounted | Domains-file mode against the empty build-time file: nothing is issued |

## Invocations

### Configure with a scoped token

- Trigger: `docker create -e CF_API_TOKEN=... -e CF_HOST=host.domain.tld -v ...`
- Preconditions: the token carries both required permissions and is scoped to include the zone.
- Behavior: the preflight sees the token and proceeds. The hook authenticates with a bearer token.
- Success: one certificate directory appears under the certs volume.
- Failure: a token missing `Zone -> Zone -> Read` fails at the zone lookup with
  `None of the provided API tokens have the required permissions for the domain`, which does not
  name the missing permission.
- Edge case: a token with a TTL that has passed fails the same way, silently, at renewal time.

### Configure with the legacy global key

- Trigger: `-e CF_EMAIL=... -e CF_KEY=...` with no `CF_API_TOKEN`.
- Behavior: the preflight emits a deprecation warning, then proceeds. The hook emits its own.
- Consequence: the credential grants full account access and ignores zone scoping entirely.

### Configure with no credentials

- Behavior: the preflight logs an error naming both accepted forms, records `FAIL`, and exits
  without contacting anything.
- Success signal: none. The container stays up and reports `unhealthy`.
- See [BL-RENEW-006](../../BUSINESS-LOGIC.md#bl-renew-006).

### Configure domains

- One name: `CF_HOST=host.domain.tld` yields `-d host.domain.tld`.
- Several names: `CF_HOST='a.tld b.tld'` yields `-d a.tld -d b.tld`.
- Legacy: `CF_HOST='a.tld -d b.tld'` yields the identical argument list, and is detected by the
  presence of ` -d ` in the value.
- Wildcard: `CF_HOST='*.example.com'` is preserved literally; globbing is disabled during splitting.
- Many certificates: leave `CF_HOST` unset and mount `domains.txt`.

### Change configuration after creation

- Environment variables cannot be changed on an existing container: `docker rm` and recreate.
- With the accounts volume bound, this no longer costs a fresh ACME registration.

## Dependencies

| Dependency | Kind | Purpose | Failure behavior |
|---|---|---|---|
| CloudFlare API token or global key | External credential | Authorizes DNS TXT writes for the challenge | Validated by the hook. Absence is caught by the preflight |
| Docker volume for certs | Host storage | Certificate persistence | Anonymous volume used if unbound |
| Docker volume for accounts | Host storage | ACME account persistence | Anonymous volume used if unbound; lost on `docker rm` |
| Host path for `domains.txt` | Host storage | Domain list | Empty build-time file used, so nothing is issued |

## Relationships

- Consumed by: [03-certificate-renewal-job.md](./03-certificate-renewal-job.md), the only reader
  of `CF_HOST`, `PUID`, and `PGID`.
- Applies to: [01-container-image.md](./01-container-image.md), which defines the defaults.
- Passed through to: the external hook, which reads the four `CF_*` variables this repo does not
  interpret.
- Writes to: the certificate store in [data-dictionary.md](../appendix/data-dictionary.md).

## Business Rules

1. `CF_API_TOKEN` and the legacy pair are mutually exclusive, token first, and the token needs
   exactly two permissions. See [BL-CFG-005](../../BUSINESS-LOGIC.md#bl-cfg-005).
2. `CF_HOST` accepts a list or the legacy embedded form and produces identical arguments for
   equivalent inputs. See [BL-CFG-006](../../BUSINESS-LOGIC.md#bl-cfg-006).
3. Wildcard names are not glob-expanded against the working directory. See
   [BL-RENEW-010](../../BUSINESS-LOGIC.md#bl-renew-010).
4. Ownership is `PUID:PGID`, defaulting to the historical `nobody:nogroup`. See
   [BL-CFG-007](../../BUSINESS-LOGIC.md#bl-cfg-007).
5. Missing credentials fail loudly before any network call, and do not stop the container. See
   [BL-RENEW-006](../../BUSINESS-LOGIC.md#bl-renew-006).
6. Given `CF_HOST` unset, domains come from `domains.txt`. See
   [BL-CFG-001](../../BUSINESS-LOGIC.md#bl-cfg-001).
