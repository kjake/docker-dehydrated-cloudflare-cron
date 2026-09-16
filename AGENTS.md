# AGENTS.md

Orientation for an agent or engineer picking this repository up cold.

This file deliberately does not restate what other documents already hold. It points at them and
records only what lives nowhere else: current state, unproven assumptions, and the traps that cost
time on 2026-09-16.

## What this repo is

A Docker image that keeps Let's Encrypt certificates fresh: `dehydrated` plus a CloudFlare DNS-01
hook, both cloned unpinned at build time, driven by a daily cron inside the container.

Operator usage is in [README.md](README.md). Everything below assumes you have skimmed it.

## Start here

| Question | Document |
|---|---|
| What does each surface do, and what is its contract? | [docs/prd/](docs/prd/) (start at its README) |
| What rule is enforced where, and why? | [docs/BUSINESS-LOGIC.md](docs/BUSINESS-LOGIC.md), 50 rules with citations |
| What is still unknown or unverified? | [docs/prd/appendix/open-questions.md](docs/prd/appendix/open-questions.md) |
| What file formats exist on disk? | [docs/prd/appendix/data-dictionary.md](docs/prd/appendix/data-dictionary.md) |
| How do the pieces call each other? | [docs/prd/appendix/module-relationships.md](docs/prd/appendix/module-relationships.md) |

Rule IDs (`BL-IMG-012`, `BL-CERT-004`, ...) are **stable by contract**. Never renumber one. A rule
that stops being true is marked retired in place, with a pointer to its successor.

## Invariants that bite

Each of these has burned someone. Full reasoning is behind the rule ID.

- **Nothing is pinned, on purpose.** Base image and both upstream clones float. Pinning was
  considered and rejected: dehydrated's latest release is well over a year behind the default
  branch the Dockerfile actually clones. The watcher is what makes floating safe.
- **The private key glob must stay prefix-only** (`privkey*`, not `privkey*.pem`). dehydrated also
  writes `privkey-<ts>.pem-revoked` and `privkey.roll.pem`. A missed key **fails open**, silently
  world-readable. See `BL-CERT-004`.
- **The recursive `chmod` is deliberate, not sloppy.** dehydrated writes everything `0600` under
  `umask 077`; this repo loosens the public material so sibling containers can read it. Removing it
  breaks every consumer. See `BL-CERT-005`.
- **`CF_HOST`'s unquoted expansion is load-bearing.** The documented legacy form embeds its own
  `-d` flags and depends on word splitting. Quoting that expansion breaks a documented feature.
  `set -f` is what stops wildcard certificates being globbed. See `BL-CFG-006`, `BL-RENEW-010`.
- **The renewal script must exit 0 in normal operation.** Failure is reported through
  `/run/dehydrated.status` and the health check, never the exit status. See `BL-RENEW-007`.
- **`certs/` may legitimately not exist.** dehydrated creates it only as a side effect of
  processing a certificate. See `BL-RENEW-008`.

## Commands

```bash
docker build -t dcc-test .                      # build
gh workflow run watch-upstream.yml --ref main   # force an upstream check
gh run list --workflow=watch-upstream.yml       # see what it decided
```

There is no local test suite. The tests live in `.github/workflows/build-check.yml` and run on
every pull request; that job is a required status check.

## State of play (2026-09-16)

Done and verified live:

- Image rebuilt and published, 7 platforms, `latest` plus an immutable `u<state_key>` tag. The
  13 critical CVEs that had accumulated during a 4.5 month outage are cleared.
- All five workflows active. The SARIF upload, broken since 2026-04, is fixed and passing.
- Watcher verified both ways: it rebuilds when upstream moves, and skips cleanly when it has not.
- State recording works, on the `upstream-state` branch.
- Auto-merge enabled and gated by two required checks (`build`, `Anchore-Build-Scan`).

## Unproven assumptions

Do not treat these as settled.

1. **The heartbeat may not work.** It exists to stop GitHub disabling scheduled workflows after 60
   days of inactivity, which is what killed CI in 2026. But it now commits to `upstream-state`, and
   GitHub never defines what counts as "repository activity" for that timer. Dependabot's merges to
   the default branch will probably carry the repo regardless. **If the workflows ever go
   `disabled_inactivity` again, this is the first thing to check.**
2. **Dependabot's automerge path has never run.** It is configured and gated but untested. Watch
   the first real Dependabot pull request rather than assuming.
3. **Branch cleanup is manual.** Merged branches accumulate; the ruleset's deletion rule applies to
   the default branch only, so this is a convenience gap, not a block.

## Open decisions

- Whether to restore `linux/mips64le`. Removed in commit 9a4a1cd with the message "Tweak buildx",
  reason unrecorded. Left out for now.
- Whether the heartbeat needs a more reliable mechanism than a side-branch commit (see above).

## Skills for the next session

- **prd-from-source**: regenerate `docs/prd/` after any material change to a surface. It updates
  in place and preserves rule IDs.
- **security-review** or **security-scan**: the certificate permission surface is the highest-risk
  area here, and a mistake in it fails open.
- **docker-patterns**: for Dockerfile or build changes.
- **github-ops**: for workflow, ruleset, or Dependabot work.

## Decisions and lessons

### 2026-09-16: Replace the blind weekly rebuild with a change-triggered watcher

**Decision:** keep everything unpinned; add a 12 hour watcher that compares both upstream
default-branch commits and the base image digest, and rebuilds only on change.
**Rationale:** the weekly rebuild was a stand-in for dependency watching. It rebuilt whether or not
anything had changed, recorded nothing about what it produced, and, being schedule-driven in a quiet
repository, was silently disabled by GitHub after 60 days. The published image was then frozen for
about 4.5 months.
**Next time:** a scheduled workflow in a low-traffic repository needs a deliberate activity story,
or it switches itself off and nothing tells you.

### 2026-09-16: Run the code instead of reasoning about it

**What happened:** the renewal script looked correct and passed review. Executing it against a
stubbed client found `args[@]: unbound variable` in domains-file mode, the most common
configuration. The script aborted before writing its status file, so the container would have
reported unhealthy forever while appearing to work.
**Why reasoning missed it:** the bug is a `set -u` empty-array interaction fixed in bash 4.4, and
Alpine ships 5.x, so "it will be fine in the container" was a defensible conclusion. It was also
unverifiable locally, which is exactly when it should not be trusted.
**Next time:** when a conclusion rests on a version-specific behaviour you cannot exercise, treat
it as unknown and use the portable construct.

### 2026-09-16: Two wrong root causes before the right one

**What happened:** the SARIF upload had failed every run since 2026-04. First hypothesis was token
permissions; disproved, the repository default was already `write`. Second was action version rot;
also wrong. The actual cause, visible in the first live log, was that the workflow hardcoded
`results.sarif` while `anchore/scan-action` had stopped writing that filename inside its moving
`v3` tag. The fix reads the action's documented `sarif` output instead.
**Next time:** an expired log is not a reason to guess in the artifact. Both wrong hypotheses were
recorded as fact in a rule and a commit message before evidence existed. Prefer getting one real
log over two confident inferences. `BL-CI-008` carries the correction rather than a quiet deletion.

### 2026-09-16: Do not blind-replace a branch rename

**What happened:** renaming `master` to `main` broke every workflow trigger. A repo-wide
`s/master/main/` would also have rewritten `gh api repos/dehydrated-io/dehydrated/commits/master`,
which is an **upstream** project whose default branch really is `master`, and a README link into
upstream docs. The rename was applied with an explicit upstream-marker exclusion and verified in
both directions.
**Next time:** in a repo that references other projects' branches, a branch rename is a
classification problem, not a substitution.

### 2026-09-16: Verify the thing you are actually going to do

**What happened:** to test whether a ruleset targeting all branches blocked work, a probe pushed an
*existing* commit to a new branch. It succeeded, so the ruleset looked harmless. Pushing a branch
containing *new* commits was then refused, and by that point the ruleset had blocked all
development, including the fix for it. A separate line-based `grep -v RETIRED` filter had earlier
undercounted stale citations for the same reason: it tested something adjacent to the real question.
**Next time:** make the probe do the actual operation, not a cheaper cousin of it.

### 2026-09-16: GitHub Actions cannot bypass a ruleset on a personal repository

**Constraint, not a choice.** The rulesets API refuses it: *"Actor GitHub Actions integration must
be part of the ruleset source or owner organization."* A workflow that must write to a protected
branch therefore needs either a stored PAT or somewhere else to write. This repo chose the latter,
so the watcher writes to `upstream-state` and no long-lived credential exists anywhere.
