# The container runs as the unprivileged 'radsec' user, uid/gid pinned to 10001. It must
# be pinned: /certs is a bind mount, so the host's numeric ownership applies at runtime
# and the image's chown below is ignored. setup.sh creates a matching radsec user on the
# host so the certificates can be owned by it and kept at mode 600.
#
# 10001 sits inside the normal UID_MIN/UID_MAX range (1000-60000), so useradd accepts it
# without a warning, while being high enough that it will not collide with a real account.
FROM debian:bookworm-slim AS builder

ARG RADSECPROXY_COMMIT=1.11.1
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    git \
    ca-certificates \
    autoconf \
    automake \
    libtool \
    pkg-config \
    nettle-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/radsecproxy/radsecproxy.git --branch ${RADSECPROXY_COMMIT} && \
    cd radsecproxy && \
    ./autogen.sh && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make -j$(nproc) && \
    make install DESTDIR=/install && \
    strip /install/usr/sbin/radsecproxy

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libnettle8 \
    && rm -rf /var/lib/apt/lists/* && \
    groupadd -g 10001 radsec && useradd -u 10001 -g radsec -s /sbin/nologin -M radsec && \
    mkdir -p /etc/radsecproxy /certs /var/log/radsecproxy && \
    chown -R radsec:radsec /etc/radsecproxy /certs /var/log/radsecproxy

COPY --from=builder /install/usr/sbin/radsecproxy /usr/bin/

# radsecproxy.conf is deliberately NOT copied into the image — it is bind-mounted by
# docker-compose.yml, the same way certs/ is.
#
# Baking it in meant `docker compose restart` silently kept running the configuration
# the image was built with: rotating the RADIUS shared secret appeared to succeed while
# the old secret stayed live, with no error and nothing in the logs. It also wrote the
# shared secret into an image layer.
#
# Leaving no fallback copy here is intentional. If the mount is ever missing,
# radsecproxy exits immediately with a config error rather than quietly starting with
# stale settings — a loud failure beats a silent wrong answer.

WORKDIR /etc/radsecproxy
EXPOSE 1812/udp 1813/udp

USER radsec
ENTRYPOINT ["/usr/bin/radsecproxy", "-f", "-c", "/etc/radsecproxy/radsecproxy.conf"]
