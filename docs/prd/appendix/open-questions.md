# Open Questions and Unknowns

Everything that could not be determined from this checkout. Each entry states why it is unknowable
and how to resolve it. Resolved entries are kept with their answers rather than deleted, so the
reasoning survives.

**Open items: 2. Resolved on 2026-09-16: 11.**

## Still open

### 1. Why the SARIF upload started failing

The Anchore workflow's `Upload Anchore Scan Report` step failed on every run from 2026-04-02 to
2026-04-30, after succeeding on 2026-03-12. The failing step is known; its error text is not,
because run logs older than 90 days have been purged.

Permissions have been **ruled out**: the repository's `default_workflow_permissions` is `write`,
code scanning is enabled, and an analysis succeeded on 2026-03-12 under the same configuration.

Leading explanation is action version rot: `github/codeql-action` was pinned at v3 against a
current v4, and `anchore/scan-action` at v3 against v7. Both have been bumped.

**How to resolve:** re-enable the workflows, let one run, and read the fresh log. If it succeeds,
the rot explanation holds. If it fails, the log will finally say why.

### 2. Why `linux/mips64le` was removed

Added in commit a464077 ("Add support for mips64le"), removed in 9a4a1cd ("Tweak buildx"). Whether
it was dropped for build failures, build time under QEMU, or lack of demand is not recorded. It
matters because the answer decides whether it should be restored.

**How to resolve:** ask the maintainer, or attempt a build for that platform and observe.
Decision taken for now: leave it out.

## Resolved on 2026-09-16

| # | Question | Answer | Source |
|---|---|---|---|
| 1 | Hook environment variables | Six: `CF_API_TOKEN`, `CF_EMAIL`, `CF_KEY`, `CF_DNS_SERVERS`, `CF_SETTLE_TIME` (default `10`), `CF_DEBUG`. Token is tried first and the two paths are mutually exclusive | Hook source, branch `main` |
| 2 | Is `CF_KEY` a token or a global key | Must be a **Global API Key**, sent as `X-Auth-Key`. Scoped tokens go in `CF_API_TOKEN` | Hook source |
| 3 | Minimum token scope | `Zone -> DNS -> Edit` and `Zone -> Zone -> Read`. `DNS Write` covers create, list and delete; `Zone Read` is needed for the zone lookup. CloudFlare's `Edit zone DNS` template omits the second | CloudFlare API reference |
| 4 | Exact daily cron time | **02:00 container-local**, from `alpine-baselayout`'s `/etc/crontabs/root`, unchanged since 2013 | Alpine aports |
| 5 | Does `nogroup` exist | Yes, **GID 65533**. But `nobody`'s primary group is **GID 65534** (a group also named `nobody`), so the historical `nobody:nogroup` pair is mismatched. On Debian `nogroup` is 65534, which is why it looks correct | Alpine aports |
| 6 | `apk add` with no package arguments | No-op, exit 0, but still fetches the repository index. The line has been removed | apk-tools 3.0.8 source |
| 7 | Are world-readable private keys intentional | Resolved by decision: keys are now group-readable only, with `PUID`/`PGID` to make the group configurable | See [BL-CERT-004](../../BUSINESS-LOGIC.md#bl-cert-004) |
| 8 | Is the missing accounts volume deliberate | Resolved by decision: it is now a declared volume | See [BL-IMG-013](../../BUSINESS-LOGIC.md#bl-img-013) |
| 9 | Should a failed renewal be detectable | Resolved by decision: loud logs plus a `HEALTHCHECK`, container keeps running | See [BL-IMG-014](../../BUSINESS-LOGIC.md#bl-img-014) |
| 10 | Is `latest`-only publishing intended | Resolved by decision: an immutable `u<state>` tag now accompanies `latest` | See [BL-CI-012](../../BUSINESS-LOGIC.md#bl-ci-012) |
| 11 | `certs/` internal layout | `privkey.pem` -> `privkey-<ts>.pem`, plus `cert`, `chain`, `fullchain` in both forms, `cert.csr`, optional `ocsp.der`, and `-revoked` variants. Private keys are exactly the `privkey*` prefix set | dehydrated v0.7.2 source |
| 12 | Default `GITHUB_TOKEN` permissions | `write`, and code scanning is enabled. This **disproved** the earlier hypothesis in `BL-CI-008` | GitHub API |

Additional facts established while resolving the above:

- dehydrated renews at **32 days** remaining (`RENEW_DAYS="32"`), and generates a **new private
  key on every renewal** by default (`PRIVATE_KEY_RENEW="yes"`), which matters for DANE and HPKP.
- `PRIVATE_KEY_ROLLOVER="no"` by default, so `privkey.roll.pem` does not normally exist.
- dehydrated exit codes are only 0 and 1, and **do not distinguish "nothing to do" from
  "renewed"**. Its `_openssl` wrapper can propagate other codes, so callers must test non-zero
  rather than `== 1`.
- `--register` is unnecessary: `-c --accept-terms` auto-registers.
- dehydrated writes everything under `umask 077`, which is why this repository's `chmod` exists.
- dehydrated creates `CERTDIR` only as a side effect of processing a certificate, which was the
  root of a confirmed container-killing bug.
- The hook publishes **zero releases**, so only commit tracking is possible for it.
- dehydrated's latest release is `v0.7.2` from **2025-05-17**, far behind its default branch,
  which is why release-based pinning was rejected.

## Verification caveats

These are inferences from source rather than observed runs, because Docker was unavailable in the
session that produced this document. The build check now exercises most of them in CI.

| Claim | Basis | How to confirm |
|---|---|---|
| Daily cron fires at 02:00 | `alpine-baselayout` source, plus the chain from `python:alpine` to `alpine:3.24` | `docker run --rm python:alpine cat /etc/crontabs/root` |
| `nogroup` is GID 65533 | Alpine `group` file in aports | `docker run --rm python:alpine getent group nogroup` |
| Branch behavior under Alpine's bash | Reproduced on host bash 3.2; the container runs bash 5.x | Now covered by the `CF_HOST forms` step in `build-check.yml` |
| `privkey*` covers every private key | Regex-derived from dehydrated's 2492 lines; a filename built purely from variables would have been missed | Inspect a real `certs/<domain>` after issuance |

## Categories checked and found empty

| Category | Result |
|---|---|
| HTTP endpoints, routes, handlers | None. Nothing binds a port |
| Database models, migrations, schemas | None |
| Inbound webhooks | None |
| Real-time channels | None |
| Feature flags | None |
| `USER` directive | None. The container runs as root, which the `chown` requires |
| `ENTRYPOINT` | None. Only `CMD`, now in exec form |
| `.dockerignore` | Not present |
