FROM python:alpine
LABEL maintainer="kjake"

# Upstream identities observed by the watcher workflow at the moment it decided
# to rebuild. They are recorded here so a published image says what is inside it.
# Both clones below track their default branch deliberately, so if upstream moves
# between the watcher's observation and this build these labels can be one commit
# stale; /etc/dehydrated-build-info records what was actually cloned, and the next
# watcher run reconciles the difference.
ARG DEHYDRATED_REVISION=unknown
ARG HOOK_REVISION=unknown
ARG BASE_DIGEST=unknown

LABEL org.opencontainers.image.source="https://github.com/kjake/docker-dehydrated-cloudflare-cron" \
      org.opencontainers.image.description="dehydrated + CloudFlare DNS-01 hook, renewing daily via cron" \
      org.opencontainers.image.licenses="MIT" \
      net.kjake.dehydrated.revision="${DEHYDRATED_REVISION}" \
      net.kjake.hook.revision="${HOOK_REVISION}" \
      net.kjake.base.digest="${BASE_DIGEST}"

COPY dehydrated /etc/periodic/daily/dehydrated
COPY healthcheck /usr/local/bin/healthcheck

RUN apk add --no-cache curl openssl bash git && \
    cd / && \
    git clone https://github.com/dehydrated-io/dehydrated && \
    cd dehydrated && \
    mkdir hooks && \
    git clone https://github.com/SeattleDevs/letsencrypt-cloudflare-hook hooks/cloudflare && \
    pip3 install -r hooks/cloudflare/requirements.txt && \
    printf 'dehydrated=%s\nhook=%s\nbuilt=%s\n' \
      "$(git -C /dehydrated rev-parse HEAD)" \
      "$(git -C /dehydrated/hooks/cloudflare rev-parse HEAD)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/dehydrated-build-info && \
    apk del git && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/* ~/.cache/pip && \
    chmod +x /etc/periodic/daily/dehydrated /usr/local/bin/healthcheck && \
    touch /dehydrated/domains.txt

# The renewal script always exits 0 so a transient failure does not stop the
# container, so its status file is what reports trouble. --start-period covers
# the first run, which can take a while waiting for DNS propagation.
HEALTHCHECK --interval=6h --timeout=10s --start-period=5m \
    CMD /usr/local/bin/healthcheck

# ";" rather than "&&" so crond starts even when the first run fails, and "exec"
# so crond becomes PID 1 and receives SIGTERM from "docker stop" directly.
CMD ["/bin/bash", "-c", "/etc/periodic/daily/dehydrated; exec crond -f"]

VOLUME /dehydrated/certs

# Holds the ACME account key. Without this the key is discarded whenever the
# container is recreated, forcing a fresh registration against the CA's
# new-account rate limit on every recreate.
VOLUME /dehydrated/accounts
