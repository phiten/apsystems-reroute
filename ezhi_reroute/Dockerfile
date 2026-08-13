# Base pinned by digest (alpine 3.24.1, as of 2026-08-11). What matters here in
# particular: the whole iptables compatibility analysis (container iptables
# 1.8.13 against host iptables 1.8.11, both nf_tables) holds for this exact
# image. An unpinned rebuild could pull it out from under us unnoticed.
# After bumping the digest, re-run the "stop leaves the rule in place" check.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL io.hass.name="EZHI Reroute"
LABEL io.hass.description="Redirects the APsystems EZHI inverter's MQTT connection to a local broker"
# Muss beim Versions-Bump zusammen mit config.yaml angehoben werden -
# der Supervisor liest config.yaml, dieses LABEL ist nur Metadaten.
LABEL io.hass.version="1.0.0"
LABEL io.hass.type="addon"
LABEL io.hass.arch="aarch64"

# iptables    -> /usr/sbin/iptables is already xtables-nft-multi (v1.8.13,
#                nf_tables), matching the host (v1.8.11, nf_tables).
# jq          -> read /data/options.json and build the state file (no bashio).
# musl-utils  -> getent, to resolve the vendor endpoint (30 KB rather than the
#                2 MB of bind-tools).
# tzdata      -> without it, date ignores the TZ the Supervisor sets and logs UTC.
# conntrack-  -> drop the tracked connections after a rule change, so the
#   tools         inverter re-enters the nat table instead of riding out its old
#                 translation (see drop_conntrack in run.sh).
RUN apk add --no-cache iptables jq musl-utils tzdata conntrack-tools

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
