# Open Questions and Unknowns

Everything that could not be determined from this checkout. Each entry states why it is unknowable
and how to resolve it. Resolved entries are kept with their answers rather than deleted, so the
reasoning survives.

**Open items: 1. Resolved on 2026-09-16: 12. Resolved on 2026-10-21: 2.**

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

## Resolved on 2026-09-16

| # | Question | Answer | Source |
|---|---|---|---|
| 1 | Hook environment variables | Six: `CF_API_TOKEN`, `CF_EMAIL`, `CF_KEY`, `CF_DNS_SERVERS`, `CF_SETTLE_TIME` (default `10`), `CF_DEBUG`. Token is tried first and the two paths are mutually exclusive | Hook source, branch `main` |
| 2 | Is `CF_KEY` a token or a global key | Must be a **Global API Key**, sent as `X-Auth-Key`. Scoped tokens go in `CF_API_TOKEN` | Hook source |
| 3 | Minimum token scope | `Zone -> DNS -> Edit` and `Zone -> Zone -> Read`. `DNS Write` covers create, list and delete; `Zone Read` is needed for the zone lookup. CloudFlare's `Edit zone DNS` template omits the second | CloudFlare API reference |
| 4 | Exact daily cron time | **02:00 container-local**, from `alpine-baselayout`'s `/etc/crontabs/root`, unchanged since 2013. **Superseded 2026-10-21:** the schedule is now this repository's own crontab, 02:00 UTC, see [BL-RENEW-011](../../BUSINESS-LOGIC.md#bl-renew-011) | Alpine aports |
| 5 | Does `nogroup` exist | Yes, **GID 65533**. But `nobody`'s primary group is **GID 65534** (a group also named `nobody`), so the historical `nobody:nogroup` pair is mismatched. On Debian `nogroup` is 65534, which is why it looks correct. **Re-checked 2026-10-21 on wolfi-base:** same values, 65533 and 65534 | Alpine aports; a built wolfi-base image |
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

## Resolved on 2026-10-21

| # | Question | Answer | Source |
|---|---|---|---|
| 1 | Why `linux/mips64le` was removed, and whether to restore it | Why it was removed in 9a4a1cd ("Tweak buildx") is still not recorded, but the question is now moot: `cgr.dev/chainguard/wolfi-base` is published only for `linux/amd64` and `linux/arm64`, so neither `mips64le` nor the five other dropped platforms can be built without changing the base image | `docker buildx imagetools inspect cgr.dev/chainguard/wolfi-base`; [BL-CI-014](../../BUSINESS-LOGIC.md#bl-ci-014) |
| 2 | Should the daily run follow `TZ` | Yes. wolfi-base ships no time zone data, so after the move off `python:alpine` (which shipped `tzdata`) `TZ` was silently ignored and every run was at 02:00 UTC. `tzdata` is now installed and in `RUNTIME_PACKAGES`, restoring the old behaviour. Observed: no `TZ` gives `02:00:00 +0000 UTC`, `TZ=America/New_York` gives `02:00:00 -0400 EDT` | `supercronic -debug` in a built image; [BL-RENEW-011](../../BUSINESS-LOGIC.md#bl-renew-011) |

## Verification caveats

The 2026-09-16 entries were inferences from source, because Docker was unavailable in that
session. On 2026-10-21 the first three were re-checked by running a locally built wolfi-base image.
The build check exercises most of them in CI.

| Claim | Basis | How to confirm |
|---|---|---|
| Daily run fires at 02:00 container time | **Observed 2026-10-21.** `supercronic -debug` reports `02:00:00 +0000 UTC` with no `TZ` and `02:00:00 -0400 EDT` with `TZ=America/New_York` | `docker run --rm IMAGE timeout 3 supercronic -debug /etc/crontabs/dehydrated` |
| `nogroup` is GID 65533 | **Observed 2026-10-21** in `/etc/group` of a built image. The image has no `getent` | `docker run --rm IMAGE grep -E '^(nogroup\|nobody):' /etc/group` |
| Branch behavior under the container's bash | Reproduced on host bash 3.2; the container runs GNU bash 5.3.0 (observed 2026-10-21) | Covered by the `CF_HOST forms` step in `build-check.yml` |
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
