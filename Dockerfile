FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    NON_INTERACTIVE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    hostapd \
    dnsmasq \
    iptables \
    iproute2 \
    iw \
    wireless-tools \
    wireless-regdb \
    rfkill \
    procps \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY runap.sh /app/runap.sh
RUN chmod +x /app/runap.sh

STOPSIGNAL SIGTERM

ENTRYPOINT ["/app/runap.sh"]

