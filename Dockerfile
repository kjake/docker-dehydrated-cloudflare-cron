FROM cgr.dev/chainguard/wolfi-base
LABEL maintainer="kjake"

# Packages are left unpinned on purpose so each rebuild picks up Wolfi's latest
# patched versions. Wolfi's busybox has no crond, so supercronic runs the job.
ADD dehydrated /etc/periodic/daily/dehydrated
RUN apk add --no-cache curl openssl bash git python-3 py3-pip supercronic && \
    cd / && \
    git clone https://github.com/dehydrated-io/dehydrated && \
    cd dehydrated && \
    mkdir hooks && \
    git clone https://github.com/SeattleDevs/letsencrypt-cloudflare-hook hooks/cloudflare && \
    pip3 install -r hooks/cloudflare/requirements.txt && \
    apk del git py3-pip && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/ ~/.cache/pip && \
    chmod +x /etc/periodic/daily/dehydrated && \
    mkdir -p /etc/crontabs && \
    echo '0 2 * * * /etc/periodic/daily/dehydrated' > /etc/crontabs/dehydrated && \
    touch /dehydrated/domains.txt

CMD /etc/periodic/daily/dehydrated && exec supercronic /etc/crontabs/dehydrated

VOLUME /dehydrated/certs
