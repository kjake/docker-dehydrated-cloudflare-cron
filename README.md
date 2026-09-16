Runs [dehydrated-io/dehydrated](https://github.com/dehydrated-io/dehydrated) with [SeattleDevs/letsencrypt-cloudflare-hook](https://github.com/SeattleDevs/letsencrypt-cloudflare-hook) as a cron job to acquire and update [Let's Encrypt](https://letsencrypt.org/) certificates by DNS-01 challenge using [CloudFlare](https://www.cloudflare.com/) as the DNS provider.

## Authentication

Use a **zone-scoped API token** (`CF_API_TOKEN`). The older `CF_EMAIL` + `CF_KEY` pair is a
*Global API Key*, which grants full access to your entire CloudFlare account, and the hook now
prints a deprecation warning when you use it.

Create a token at <https://dash.cloudflare.com/profile/api-tokens>. It needs exactly two
permissions:

| Group | Permission | Access |
|---|---|---|
| Zone | DNS | Edit |
| Zone | Zone | Read |

Under **Zone Resources**, choose **Include** -> **Specific zones** and select each zone you need.
One token can cover several zones in the same account.

> **The `Edit zone DNS` template is not enough on its own.** It grants only the DNS permission and
> leaves out `Zone -> Zone -> Read`. Without that, the hook cannot look up your zone ID and fails
> with `None of the provided API tokens have the required permissions for the domain`, which does
> not obviously point at the missing permission. Start from the template, then add the Zone Read row.

Leave **TTL** blank. A token that expires will make renewals fail quietly.

For zones spread across different CloudFlare accounts, put several tokens in `CF_API_TOKEN`
separated by spaces; each is tried until one can resolve the zone.

## Usage

For a single domain:
```shell
docker create \
  --name=dehydrated \
  -e 'CF_API_TOKEN=your_api_token' \
  -e 'CF_HOST=host.domain.tld' \
  -v /path/to/certs:/dehydrated/certs \
  -v /path/to/accounts:/dehydrated/accounts \
  kjake/dehydrated-cloudflare-cron
```

For one certificate covering several names, give `CF_HOST` a space-separated list:
```shell
  -e 'CF_HOST=host1.domain.tld host2.domain.tld host3.domain.tld' \
```

For multiple certificates, provide a [domains.txt](https://github.com/dehydrated-io/dehydrated/blob/master/docs/domains_txt.md) instead. `CF_HOST` must be unset or empty for this to work:
```shell
docker create \
  --name=dehydrated \
  -e 'CF_API_TOKEN=your_api_token' \
  -v /path/to/domains.txt:/dehydrated/domains.txt:ro \
  -v /path/to/certs:/dehydrated/certs \
  -v /path/to/accounts:/dehydrated/accounts \
  kjake/dehydrated-cloudflare-cron
```

Then start the container, which runs once at start and daily at 02:00 container-local time after that:
```shell
docker start dehydrated
```

Certificates are renewed once they are within 32 days of expiry. dehydrated generates a **new
private key on every renewal** by default, which matters if anything pins your key (DANE, HPKP).

## Configuration

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CF_API_TOKEN` | Yes, unless using the legacy pair | none | Zone-scoped CloudFlare API token. Space-separate several tokens to span accounts |
| `CF_EMAIL` | Legacy only | none | CloudFlare account email. Ignored when `CF_API_TOKEN` is set |
| `CF_KEY` | Legacy only | none | CloudFlare **Global API Key**. Ignored when `CF_API_TOKEN` is set |
| `CF_HOST` | No | unset | Space-separated hostnames. Unset or empty reads `domains.txt` instead |
| `CF_DNS_SERVERS` | No | hook default | Resolvers used to confirm DNS propagation |
| `CF_SETTLE_TIME` | No | `10` | Seconds to wait for propagation |
| `CF_DEBUG` | No | unset | Verbose hook logging |
| `PUID` | No | `nobody` | Owner applied to `certs` |
| `PGID` | No | `nogroup` | Group applied to `certs` |

| Mount | Required | Purpose |
|---|---|---|
| `/dehydrated/certs` | Strongly recommended | Issued certificates |
| `/dehydrated/accounts` | Recommended | ACME account key. Without it, recreating the container forces a fresh registration against Let's Encrypt's new-account rate limit |
| `/dehydrated/domains.txt` | Multi-certificate mode only | Domain list, mount read-only |

### Legacy `CF_HOST` form

Earlier versions documented embedding extra `-d` flags in the value:

```shell
  -e 'CF_HOST=host1.domain.tld -d host2.domain.tld -d host3.domain.tld' \
```

This still works and produces an identical certificate. The plain space-separated list above is
preferred and does the same thing without the embedded flags.

## Certificate permissions

After every run, everything under `certs` is owned by `PUID:PGID` and readable by all, **except
private keys, which are not readable by others**. Directories remain traversable.

> **Upgrading from an image published before 2026-09:** private keys used to be world-readable.
> If another container reads them, it must now run as a user in the `nogroup` group (GID 65533),
> or you must set `PGID` to a group it does belong to. A consumer that silently loses access will
> fail its TLS handshake rather than reporting a permission error, so check this before upgrading.

## Health

The container reports a Docker health status. A failed renewal leaves the container running so
cron retries the next day, and marks it `unhealthy`:

```shell
docker inspect --format '{{.State.Health.Status}}' dehydrated
```

Renewal failures are only visible in `docker logs`; the container's exit status deliberately does
not reflect them.

## Versions and updates

Published to Docker Hub as `kjake/dehydrated-cloudflare-cron`:

- `latest` tracks the most recent build.
- `u<state>` is an immutable tag identifying the exact combination of dehydrated, hook, and base
  image that went into that build. Use it to pin or roll back.

Nothing in this image is version-pinned: it tracks the default branch of both upstream projects
and the floating `python:alpine` base. A [watcher workflow](.github/workflows/watch-upstream.yml)
checks every 12 hours and rebuilds when any of the three changes. Each image records what it
contains in its OCI labels and in `/etc/dehydrated-build-info`:

```shell
docker run --rm kjake/dehydrated-cloudflare-cron cat /etc/dehydrated-build-info
```

## License

[MIT](LICENSE). The bundled upstream projects carry their own licenses.

Based on [kmlucy/docker-dehydrated](https://github.com/kmlucy/docker-dehydrated)
