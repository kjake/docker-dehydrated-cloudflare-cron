# Module Relationships

No navigable UI, so this replaces a route map. It shows which unit owns what, which calls which,
and where the boundary to external code lies.

## Build-time tree

```
Dockerfile
├── cgr.dev/chainguard/wolfi-base                  external, bare name, no tag or digest
├── dehydrated              (this repo)            -> /etc/periodic/daily/dehydrated
├── healthcheck             (this repo)            -> /usr/local/bin/healthcheck
├── apk: curl openssl bash python-3 supercronic tzdata
│                                                  runtime packages, unpinned
├── apk: git py3-pip                               build only, removed in the same layer
├── dehydrated-io/dehydrated        branch master  external, unpinned -> /dehydrated
├── SeattleDevs/letsencrypt-cloudflare-hook
│                                   branch main    external, unpinned -> /dehydrated/hooks/cloudflare
├── pip3 -r hooks/cloudflare/requirements.txt      external, unpinned
├── /etc/dehydrated-build-info                     records the two cloned commits
└── /etc/crontabs/dehydrated                       0 2 * * * /etc/periodic/daily/dehydrated
```

## Runtime call tree

Everything below a boundary marker is code this repository does not contain.

```
docker start
└── bash -c "..."                                  exec form
    ├── /etc/periodic/daily/dehydrated             synchronous first run
    │   ├── cd /dehydrated                         checked
    │   ├── credential preflight                   CF_API_TOKEN | CF_EMAIL+CF_KEY | fail
    │   ├── domain selection                       set -f, then case on CF_HOST
    │   ├── ./dehydrated -c --accept-terms ...     ==== boundary: upstream ====
    │   │   └── hooks/cloudflare/hook.py           ==== boundary: upstream ====
    │   │       └── CloudFlare v4 API              external network
    │   ├── chown / chmod on certs                 guarded on certs existing
    │   └── write /run/dehydrated.status
    └── exec supercronic /etc/crontabs/dehydrated  becomes PID 1, always reached
        └── 0 2 * * *                              02:00 container time, UTC unless TZ set
            └── /etc/periodic/daily/dehydrated     same pipeline

docker healthcheck
└── /usr/local/bin/healthcheck
    └── reads /run/dehydrated.status
```

## CI graph

```
schedule (12h) ─> watch-upstream.yml
                    ├── check      resolve 4 upstream identities, compare to .upstream-state.json
                    ├── publish ──> docker.yml (workflow_call)  ──> Docker Hub
                    ├── record     commit state to upstream-state branch (keeps repo active)
                    └── heartbeat  empty commit if quiet 50 days

push to main ──> docker.yml            (paths-ignore: state file, docs, markdown, LICENSE)
               └─> anchore.yml           build + Grype + SARIF

pull request ────> build-check.yml       REQUIRED CHECK: build + 4 test steps
               └─> anchore.yml

dependabot ──────> grouped PR ──> build-check.yml ──> dependabot-automerge.yml ──> merged
                                  (gate)              (gh pr merge --auto)
```

The gate relationship is the important one: without `build-check.yml` being a required status
check, the automerge step merges immediately and unreviewed.

## Ownership

| Unit | Owns | Does not own |
|---|---|---|
| `Dockerfile` | Package set, filesystem layout, daily schedule (`/etc/crontabs/dehydrated`), container command, volumes, health check, provenance labels | The content of either cloned project, package versions |
| `dehydrated` | Credential preflight, domain selection, fixed client arguments, certificate ownership and modes, run status | Certificate issuance, DNS record management, renewal thresholds |
| `healthcheck` | Translating the status file into a Docker health result | Anything about why a run failed |
| `watch-upstream.yml` | When to rebuild, what identity a build has, the watched package list (`RUNTIME_PACKAGES`), keeping the repo active | How to build |
| `docker.yml` | How to build, which platforms, which tags | Whether a build is needed |
| `build-check.yml` | The merge gate and the only automated tests | Publishing |
| `anchore.yml` | Which findings are reported | Whether anything is blocked (nothing is) |
| `dependabot.yml` + automerge | Action versions | Either upstream project, which it structurally cannot see |

## Data ownership

| Path | Written by | Read by | Persisted |
|---|---|---|---|
| `/dehydrated/certs` | upstream client, then the renewal script | operator, sibling containers | Yes, volume |
| `/dehydrated/accounts` | upstream client | upstream client | Yes, volume |
| `/dehydrated/domains.txt` | operator, by bind mount | upstream client | Only if mounted |
| `/run/dehydrated.status` | renewal script | `healthcheck` | No, container-local |
| `/etc/dehydrated-build-info` | the build | humans | Baked into the image |
| `.upstream-state.json` | `watch-upstream.yml` | `watch-upstream.yml` | Yes, on the `upstream-state` branch |
| `results.sarif` | `anchore/scan-action` | `upload-sarif` | No, runner-local |

## Cross-unit dependencies

| From | To | Nature |
|---|---|---|
| `Dockerfile` CMD | `dehydrated` | Invokes, then `exec supercronic` regardless of outcome |
| `/etc/crontabs/dehydrated` | `dehydrated` | `supercronic` invokes it daily at 02:00 container time (UTC unless `TZ` is set) |
| `watch-upstream.yml` `RUNTIME_PACKAGES` | `Dockerfile` `apk add` | Must list the same packages minus `git`. Kept in step by hand only |
| `Dockerfile` HEALTHCHECK | `healthcheck` | Invokes every 6h |
| `healthcheck` | `dehydrated` | Reads the status file it writes |
| `dehydrated` | runtime configuration | Reads `CF_HOST`, `PUID`, `PGID`; checks credential presence |
| `dehydrated` | `Dockerfile` volumes | Depends on `certs` existing, and guards when it does not |
| `dehydrated` | absence of `USER` | Depends on running as root for the `chown` |
| `watch-upstream.yml` | `docker.yml` | Calls it and passes three of the four identities, plus `state_key` |
| `dependabot-automerge.yml` | `build-check.yml` | Depends on it being a required check for safety |
| `README.md` | `dehydrated` | Documents the two `CF_HOST` forms the script implements |

## Orphans and unreferenced units

- **No orphan units.** Every file is reachable: workflows are triggered by GitHub, the Dockerfile
  is built by three of them, both scripts are installed and invoked by the image, and `README.md`
  and `LICENSE` are operator-facing.
- **No dead code paths.** All four `CF_HOST` branches and both credential branches are reachable
  and documented, and three of them are now covered by tests in `build-check.yml`.
