# Surface Inventory

Every addressable unit, at the address a consumer actually uses. This replaces `api-inventory.md`:
there is no HTTP API, so the addressable units are an image reference, environment and mount names,
filesystem paths, and workflow identifiers.

## HTTP endpoints

**None.** Nothing in this repository binds a port, registers a route, or starts a server. `curl` is
installed as an outbound client for the upstream ACME code. Affirmative finding, not an omission.

## Addressable units

| # | Kind | Address (verbatim) | Defined in | Auth | Consumers |
|---|---|---|---|---|---|
| 1 | Container image | `kjake/dehydrated-cloudflare-cron:latest` | `docker.yml` | None to pull | Operators |
| 2 | Container image | `kjake/dehydrated-cloudflare-cron:u<state_key>` | `docker.yml` | None to pull | Operators pinning or rolling back |
| 3 | Container command | `/etc/periodic/daily/dehydrated; exec crond -f` | `Dockerfile` | Runs as root | Docker, at `docker start` |
| 4 | Executable path | `/etc/periodic/daily/dehydrated` | `Dockerfile` | Runs as root | busybox `crond`, and the container command |
| 5 | Executable path | `/usr/local/bin/healthcheck` | `Dockerfile` | Runs as root | Docker's health check |
| 6 | Env var | `CF_API_TOKEN` | read by the hook; presence checked by the renewal script | n/a | The hook |
| 7 | Env var | `CF_EMAIL` | read by the hook; presence checked by the renewal script | n/a | The hook, legacy path only |
| 8 | Env var | `CF_KEY` | read by the hook; presence checked by the renewal script | n/a | The hook, legacy path only |
| 9 | Env var | `CF_HOST` | `dehydrated` | n/a | The renewal job |
| 10 | Env var | `CF_DNS_SERVERS` | read by the hook | n/a | The hook |
| 11 | Env var | `CF_SETTLE_TIME` | read by the hook | n/a | The hook |
| 12 | Env var | `CF_DEBUG` | read by the hook | n/a | The hook |
| 13 | Env var | `PUID` | `dehydrated` | n/a | The renewal job |
| 14 | Env var | `PGID` | `dehydrated` | n/a | The renewal job |
| 15 | Mount point | `/dehydrated/certs` | `Dockerfile` | Filesystem; keys restricted to `PGID` | Operator, sibling containers |
| 16 | Mount point | `/dehydrated/accounts` | `Dockerfile` | Filesystem, `0600` | The upstream client |
| 17 | Mount point | `/dehydrated/domains.txt` | `Dockerfile`, `README.md` | Filesystem, mounted read-only | The upstream client |
| 18 | File in image | `/etc/dehydrated-build-info` | `Dockerfile` | World-readable | Humans inspecting provenance |
| 19 | File at runtime | `/run/dehydrated.status` | `dehydrated` | Root | `healthcheck` |
| 20 | File in repo | `.upstream-state.json` | `watch-upstream.yml` | Public | The watcher |
| 21 | Workflow | `watch-upstream.yml`, jobs `check` / `publish` / `record` / `heartbeat` | itself | `contents: write` | Scheduler, manual dispatch |
| 22 | Workflow | `docker.yml`, job `push` | itself | Repository secrets | Watcher, `master` pushes |
| 23 | Workflow | `anchore.yml`, job `Anchore-Build-Scan` | itself | `security-events: write` | Scheduler, `master`, pull requests |
| 24 | Workflow | `build-check.yml`, job `build` | itself | `contents: read` | Pull requests. **Required status check** |
| 25 | Workflow | `dependabot-automerge.yml`, job `automerge` | itself | `contents`/`pull-requests: write` | Dependabot pull requests |

## Full invocations, verbatim

Single domain with a scoped token:

```shell
docker create \
  --name=dehydrated \
  -e 'CF_API_TOKEN=your_api_token' \
  -e 'CF_HOST=host.domain.tld' \
  -v /path/to/certs:/dehydrated/certs \
  -v /path/to/accounts:/dehydrated/accounts \
  kjake/dehydrated-cloudflare-cron
```

Several names on one certificate, substituting the `CF_HOST` line:

```shell
  -e 'CF_HOST=host1.domain.tld host2.domain.tld host3.domain.tld' \
```

Legacy equivalent, still supported:

```shell
  -e 'CF_HOST=host1.domain.tld -d host2.domain.tld -d host3.domain.tld' \
```

Multiple certificates via a domains file, with `CF_HOST` absent:

```shell
docker create \
  --name=dehydrated \
  -e 'CF_API_TOKEN=your_api_token' \
  -v /path/to/domains.txt:/dehydrated/domains.txt:ro \
  -v /path/to/certs:/dehydrated/certs \
  -v /path/to/accounts:/dehydrated/accounts \
  kjake/dehydrated-cloudflare-cron
```

Start, inspect health, and read provenance:

```shell
docker start dehydrated
docker inspect --format '{{.State.Health.Status}}' dehydrated
docker run --rm kjake/dehydrated-cloudflare-cron cat /etc/dehydrated-build-info
```

## Resolved internal invocations

The arguments the renewal script passes, with `CF_HOST` resolved. Verified by reproducing the
shell expansion, and covered by a test in `build-check.yml`.

| Mode | Resolved command (working directory `/dehydrated`) |
|---|---|
| domains file | `./dehydrated -c --accept-terms -t dns-01 -k hooks/cloudflare/hook.py` |
| single host | `./dehydrated -c --accept-terms -t dns-01 -k hooks/cloudflare/hook.py -d host.domain.tld` |
| hostname list `a.tld b.tld` | `... -d a.tld -d b.tld` |
| legacy `a.tld -d b.tld` | `... -d a.tld -d b.tld` (identical) |
| wildcard `*.example.com` | `... -d *.example.com` (not glob-expanded) |

There is no longer a separate `./dehydrated --register --accept-terms` invocation.

## Units defined here but never called by any known consumer

None. Every unit above has at least one identified consumer.

## Units called by consumers but not found in this repository

| Unit | Owning project | Reached via | What is unknown |
|---|---|---|---|
| `./dehydrated` | `dehydrated-io/dehydrated`, branch `master` | Cloned at build, invoked by the renewal script | Nothing material remains: renewal threshold, exit codes, file layout, and `domains.txt` grammar were all resolved from source |
| `hooks/cloudflare/hook.py` | `SeattleDevs/letsencrypt-cloudflare-hook`, branch `main` | Cloned at build, invoked via `-k` | Its six environment variables are now documented. Internal retry and propagation behavior is not |
| `crond`, `run-parts`, `/etc/crontabs/root` | busybox and `alpine-baselayout` | Started by the container command | Resolved: `/etc/periodic/daily` runs at 02:00 |
| GitHub Actions (7 actions) | Third parties | Referenced by the workflows | Their full input sets |
