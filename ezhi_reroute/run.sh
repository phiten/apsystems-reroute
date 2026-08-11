#!/bin/sh
# EZHI Reroute - holds the DNAT rules that send the inverter's MQTT connection
# to a broker you control. See DOCS.md for what this does and does not do.
#
# This add-on is NOT a switch. What decides whether the inverter talks to your
# broker or to the vendor is the static route in your router. This add-on only
# makes sure that traffic arriving here is actually redirected.
set -eu

OPTS=${EZHI_OPTIONS:-/data/options.json}
STATE_FILE=${EZHI_STATE_FILE:-/share/ezhi_reroute.json}
ARP_TABLE=${ARP_TABLE:-/proc/net/arp}
CHAIN=EZHI_REROUTE

# The add-on log has no timestamps of its own. Local time comes from TZ, which
# the Supervisor sets - that is why the image carries tzdata.
log() { echo "[ezhi_reroute] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- options ---------------------------------------------------------------

opt() { jq -r "(.$1 // \"\") | tostring" "$OPTS"; }

# This host's LAN address. With host_network that is also the address the
# Mosquitto add-on listens on, which is the common case.
host_ip() {
    ip route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

load_options() {
    SOURCE_IP=$(opt source_ip)
    VENDOR_IP=$(opt vendor_ip)
    BROKER_IP=$(opt broker_ip)
    DNS_NAME=$(opt dns_name)
    PORT=$(opt port)
    INTERVAL=$(opt check_interval)

    [ -n "$BROKER_IP" ] || BROKER_IP=$(host_ip)
}

# --- resolving the vendor endpoint -----------------------------------------

# Prints the target addresses, one per line, sorted and deduplicated.
# Empty output means "resolution failed" - NOT "no addresses".
#
# Resolving beats configuring here: the vendor endpoint sits behind a regional
# load balancer, so a hardcoded address is right in exactly one part of the world.
resolve_vendor() {
    if [ -n "$VENDOR_IP" ]; then
        echo "$VENDOR_IP"
        return 0
    fi
    getent ahostsv4 "$DNS_NAME" 2>/dev/null | awk '{print $1}' | sort -u
}

# --- finding the inverter --------------------------------------------------

# Proves that something at this address really is an inverter. The local HTTP
# API listens on port 80.
is_ezhi() {
    wget -q -O- -T 1 "http://$1/getDeviceInfo" 2>/dev/null | grep -q '"deviceId"'
}

# The inverter is always in this host's ARP table, because the integration polls
# its local HTTP API anyway. That is why this short list is enough and a subnet
# scan is not needed.
#
# Deliberately NOT a lookup by MAC OUI: that would be a guess across hardware
# revisions, while an API probe is proof.
detect_source() {
    # Complete entries only (flags 0x2). The table holds around sixty lines on a
    # normal home network, each probe costs up to a second, and until there is a
    # hit no rule is installed. Set source_ip to skip this window - which is
    # exactly what the log suggests after the first successful detection.
    for ip in $(awk 'NR > 1 && $1 ~ /^[0-9]+\./ && $3 == "0x2" { print $1 }' "$ARP_TABLE" | sort -u); do
        if is_ezhi "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# --- the chain -------------------------------------------------------------

# Creates the chain and the jump into it. Idempotent.
ensure_chain() {
    iptables -t nat -N "$CHAIN" 2>/dev/null || true
    iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null \
      || iptables -t nat -I PREROUTING 1 -j "$CHAIN"
}

# The addresses our chain currently holds rules for.
chain_addresses() {
    iptables -t nat -S "$CHAIN" 2>/dev/null \
      | awk '/-j DNAT/ { for (i = 1; i < NF; i++) if ($i == "-d") print $(i + 1) }' \
      | sed 's#/32$##' | sort -u
}

# Flushes the chain and installs exactly one rule per address.
#
# Called ONLY when the address set actually changed: every flush resets the
# packet counters, and those carry the one diagnostic that tells a user their
# router is not forwarding anything here.
install_rules() {
    iptables -t nat -F "$CHAIN"
    for ip in $1; do
        iptables -t nat -A "$CHAIN" -s "$SOURCE_IP" -d "$ip" \
                 -p tcp --dport "$PORT" -j DNAT --to-destination "$BROKER_IP:$PORT"
    done
}

# Version 0.3.0 wrote its rule straight into PREROUTING. Left in place after an
# upgrade, two redirects would run in parallel. The match requires BOTH our
# source address AND our DNAT target, so a foreign rule that happens to point at
# the same broker is not swept up with it.
drop_legacy_rules() {
    # Without a known source address the first grep degenerates to `-s ` and
    # matches EVERY PREROUTING rule carrying a source - on a HAOS host that
    # includes the Tailscale DNAT rules. Correctness would then rest on the
    # second grep alone. With no source there is nothing to migrate either.
    [ -n "$SOURCE_IP" ] || return 0
    iptables -t nat -S PREROUTING 2>/dev/null \
      | grep -- "-s $SOURCE_IP" \
      | grep -- "--to-destination $BROKER_IP:$PORT" \
      | while read -r rule; do
            # shellcheck disable=SC2086
            set -- $rule
            shift                                  # drop the leading -A
            log "removing a leftover rule from version 0.3.0"
            iptables -t nat -D "$@" 2>/dev/null || true
        done
}

# CAREFUL, semantics: the nat table counts only the FIRST packet of each
# connection. The inverter holds a long-lived MQTT connection, so this counter
# settles at a small number and does not grow. The diagnostic is therefore
# "is zero", never "is not growing" - the latter would alarm during healthy
# operation.
packet_count() {
    iptables -t nat -L "$CHAIN" -n -v -x 2>/dev/null \
      | awk '/DNAT/ { sum += $1 } END { print sum + 0 }'
}

# --- state -----------------------------------------------------------------

# Turns the log into something Home Assistant can react to. Built through jq
# rather than glued together with printf on purpose: this file gets parsed, and
# broken JSON shows up as a silently dead sensor rather than as an error.
write_state() {
    _rule=$1
    _addresses=$2
    _packets=$3
    printf '%s\n' "$_addresses" | jq -R . | jq -s \
        --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        --arg rule "$_rule" \
        --arg src "$SOURCE_IP" \
        --arg broker "$BROKER_IP:$PORT" \
        --argjson packets "$_packets" \
        '{ts: $ts, rule: $rule, addresses: map(select(. != "")),
          packets: $packets, source_ip: $src, broker: $broker}' \
        > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# --- the loop --------------------------------------------------------------

# Makes the chain hold exactly the currently valid addresses.
# Returns 0 when the state is right, 1 when it could not be established.
#
# NEVER fatal: add-ons run with RestartPolicy=no, so a death under `set -e` would
# leave the container lying there quietly - the rule gone and nobody the wiser.
# That is the silent break this add-on exists to prevent.
ensure() {
    _want=$(resolve_vendor | tr '\n' ' ')
    if [ -z "$_want" ]; then
        log "WARN cannot resolve $DNS_NAME - keeping the rules already installed"
        return 1
    fi
    _have=$(chain_addresses | tr '\n' ' ')
    [ "$_want" = "$_have" ] && return 0
    log "installing rules for ${_want}(was: ${_have:-none})"
    install_rules "$(resolve_vendor)"
}

# There is deliberately NO cleanup trap. The rule stays when the add-on stops.
#
# Why: the rule only matches `-s <inverter> -d <vendor>:<port>`. With the route in
# your router switched off, those packets never reach this host - the rule is
# unreachable. With it switched on, you want the rule. A leftover rule can, by
# construction, only take effect when it should.
#
# An earlier version removed it on SIGTERM. That turned every clean stop into a
# blackhole: the host has -P FORWARD DROP, so the packets vanished. A hard crash,
# which never ran the trap, left the rule in place and the device kept working -
# the failure modes were the wrong way round.
main() {
    load_options

    if [ -z "$SOURCE_IP" ]; then
        if SOURCE_IP=$(detect_source); then
            log "detected the inverter at $SOURCE_IP - set source_ip in the options to skip this search"
        else
            log "WARN no inverter found among the hosts in the ARP table."
            log "     No rule installed - a rule without a source address would"
            log "     redirect EVERY device on your network to the broker."
            log "     Set source_ip in the add-on options. Retrying in ${INTERVAL}s."
        fi
    fi

    ensure_chain
    drop_legacy_rules
    if [ -n "$SOURCE_IP" ]; then
        ensure || true
    fi
    log "active: ${SOURCE_IP:-<unknown>} -> $DNS_NAME:$PORT  ==>  $BROKER_IP:$PORT (every ${INTERVAL}s)"

    zero_rounds=0
    while :; do
        # sleep as a job plus wait, so SIGTERM lands immediately instead of
        # waiting out the interval.
        sleep "$INTERVAL" & wait $! || true

        if [ -z "$SOURCE_IP" ]; then
            if SOURCE_IP=$(detect_source); then
                log "detected the inverter at $SOURCE_IP"
                drop_legacy_rules
            fi
        fi
        if [ -z "$SOURCE_IP" ]; then
            write_state no-source "" 0 || true
            continue
        fi

        ensure || true
        _packets=$(packet_count)
        # Resolve once per round rather than three times: less DNS traffic, and
        # every use sees the same answer.
        _addresses=$(resolve_vendor)

        if [ "$_packets" -eq 0 ]; then
            zero_rounds=$((zero_rounds + 1))
            if [ "$zero_rounds" -eq 5 ]; then
                log "WARN the rule is installed but has never matched a packet."
                log "     Your router is not sending this traffic here. Check the"
                log "     static route: $(echo $_addresses) -> this host."
            fi
        else
            zero_rounds=0
        fi

        # This was the one unguarded command in the loop. An unwritable /share
        # would have killed the daemon under `set -e`, and with RestartPolicy=no
        # the container would just lie there - exactly the silent break above.
        write_state ok "$_addresses" "$_packets" || log "WARN could not write $STATE_FILE"
    done
}

if [ "${EZHI_REROUTE_LIB:-}" != "1" ]; then
    main
fi
