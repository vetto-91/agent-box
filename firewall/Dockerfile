FROM ubuntu:26.04

LABEL agentbox.base="ubuntu26.04"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    opensnitch \
    iptables \
    iproute2 \
    ca-certificates \
    procps \
    jq \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/opensnitchd/rules /run/opensnitch

COPY default-config.json /etc/opensnitchd/default-config.json
COPY system-fw.json /etc/opensnitchd/system-fw.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
