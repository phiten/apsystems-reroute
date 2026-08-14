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
# Where the capture listener sits while capture_credentials is on. A port of its
# own rather than 9005, so the broker keeps that one and never has to be stopped
# -- the DNAT rule is what decides where the inverter lands, not the port number
# it dialled. Not an option: nothing outside this file has any use for it.
CAPTURE_PORT=19005
CAPTURE_SCRIPT=${CAPTURE_SCRIPT:-/capture_credentials.py}

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
    # Ohne Wert waere das `sleep ""` - und weil der Fehler mit `|| true`
    # gefangen wird, ergaebe das eine Schleife mit 100 % CPU statt eines Fehlers.
    case "$INTERVAL" in
        ''|*[!0-9]*) log "WARN check_interval is '${INTERVAL}', using 60"; INTERVAL=60 ;;
    esac

    BROKER_OPT="$BROKER_IP"
    [ -n "$BROKER_IP" ] || BROKER_IP=$(host_ip)

    CAPTURE=$(opt capture_credentials)
    CERTFILE=$(opt certfile)
    KEYFILE=$(opt keyfile)
    set_target
}

# Where the DNAT rules point. Normally the broker; in capture mode the listener
# on this host.
#
# Capture deliberately ignores broker_ip and uses this host's own address, even
# when the broker is elsewhere. DNAT rewrites the destination and nothing else,
# so a machine that is not this one would answer the inverter under its own
# address and the inverter would drop the reply - it is waiting to hear from the
# vendor. Redirecting to somewhere on this host keeps the return path intact,
# because conntrack undoes the translation on the way back.
set_target() {
    if [ "${CAPTURE:-false}" = "true" ]; then
        _here=$(host_ip)
        if [ -n "$_here" ]; then
            TARGET="$_here:$CAPTURE_PORT"
            return 0
        fi
        # No address yet (the boot race host_ip already warns about elsewhere).
        # Falling back to the broker keeps the inverter working; entering capture
        # mode with an empty address would write ":19005" and every -A after the
        # -F would fail, which is the blackhole this add-on exists to avoid.
        log "WARN capture_credentials is on but this host has no address yet -"
        log "     staying on the broker for now, retrying next round."
    fi
    TARGET="$BROKER_IP:$PORT"
}

refresh_broker_ip() {
    # Nur wenn der Nutzer nichts vorgegeben hat. Beim Boot kann `ip route get`
    # noch nichts liefern (Race mit dem Netz), und die Host-Adresse kann sich
    # per DHCP aendern - beides waere sonst bis zum naechsten Add-on-Neustart
    # eingefroren. Ein leeres Ergebnis behaelt den alten Wert: lieber die alte
    # Adresse als ein Ziel ":9005", an dem jedes -A nach dem -F scheitert.
    [ -n "$BROKER_OPT" ] && return 0
    _fresh=$(host_ip)
    if [ -n "$_fresh" ] && [ "$_fresh" != "$BROKER_IP" ]; then
        log "broker address changed: ${BROKER_IP:-none} -> $_fresh"
        BROKER_IP=$_fresh
    fi
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
# revisions. The probe is better evidence, but not proof of identity - it shows
# "some device answers getDeviceInfo on port 80". With two APsystems devices on
# the network the lowest address wins, which may be the wrong one. That is what
# the source_ip option is for, and why the log asks for it after every find.
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
drop_conntrack() {
    # The nat table only ever sees the FIRST packet of a connection; every
    # packet after it follows the conntrack entry made back then. A rule change
    # therefore does not move a connection that is already up - the inverter
    # keeps talking through the translation it got under the old rules, while
    # the fresh rule sits at zero packets and everything looks fine. Dropping
    # the tracked connection forces the next packet back through the nat table,
    # which is what makes the packet counter mean what this add-on says it
    # means. Measured 2026-08-13: the counter survives a container restart
    # untouched, because ensure_chain does not flush - only a rule change does.
    #
    # Scoped to this inverter and this port. The HAOS host runs other DNAT of
    # its own (Tailscale), and a blanket flush would drop connections that have
    # nothing to do with us.
    [ -n "$SOURCE_IP" ] || return 0
    if ! command -v conntrack >/dev/null 2>&1; then
        log "WARN conntrack is missing - the inverter keeps its existing"
        log "     connection until it reconnects on its own, so the packet"
        log "     counter can read 0 for a while after a rule change."
        return 0
    fi
    # Exit code 1 means "nothing matched", which is the ordinary case: the
    # inverter may not have a connection up. Under set -e that would be fatal.
    conntrack -D -s "$SOURCE_IP" -p tcp --dport "$PORT" || true
}

install_rules() {
    iptables -t nat -F "$CHAIN"
    for ip in $1; do
        iptables -t nat -A "$CHAIN" -s "$SOURCE_IP" -d "$ip" \
                 -p tcp --dport "$PORT" -j DNAT --to-destination "$TARGET"
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
      | grep -- "-s $SOURCE_IP/32 " \
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
        --arg broker "$TARGET" \
        --arg mode "$([ "${CAPTURE:-false}" = "true" ] && echo capture || echo normal)" \
        --argjson packets "$_packets" \
        '{ts: $ts, rule: $rule, addresses: map(select(. != "")),
          packets: $packets, source_ip: $src, broker: $broker, mode: $mode}' \
        > "$STATE_FILE.$$.tmp" && mv "$STATE_FILE.$$.tmp" "$STATE_FILE"
}

# --- the loop --------------------------------------------------------------

# Makes the chain hold exactly the currently valid addresses.
# Returns 0 when the state is right, 1 when it could not be established.
#
# NEVER fatal: add-ons run with RestartPolicy=no, so a death under `set -e` would
# leave the container lying there quietly - the rule gone and nobody the wiser.
# That is the silent break this add-on exists to prevent.
chain_matches_options() {
    # Every DNAT rule in the chain has to carry the source and broker the
    # options ask for right now. Comparing the -d addresses alone is not
    # enough: change broker_ip or source_ip and the address set is identical,
    # so nothing would ever be reinstalled and the old rule would keep sending
    # traffic to the old broker - while the state file, which reports the
    # option values, cheerfully shows the new one.
    # Also what puts capture mode into effect and takes it out again: TARGET
    # changes, every rule stops matching, and the next ensure() reinstalls the
    # lot. Turning the option on or off needs nothing else.
    _total=$(iptables -t nat -S "$CHAIN" 2>/dev/null | grep -c -- '-j DNAT')
    _ours=$(iptables -t nat -S "$CHAIN" 2>/dev/null | grep -- '-j DNAT' \
            | grep -c -- "-s $SOURCE_IP/32 .*--to-destination $TARGET")
    [ "$_total" = "$_ours" ]
}
ensure() {
    _want=$(resolve_vendor | tr '\n' ' ')
    if [ -z "$_want" ]; then
        log "WARN cannot resolve $DNS_NAME - keeping the rules already installed"
        return 1
    fi
    _have=$(chain_addresses | tr '\n' ' ')

    # Additiv, nicht symmetrisch: nur NEUE Adressen loesen etwas aus. Liefert
    # der regionale Load Balancer rotierende Teilmengen - bei AWS-artigen
    # Endpunkten ueblich - unterscheidet sich die Menge sonst jede Runde, und
    # jede Runde bedeutet Flush plus conntrack-Drop, also einen Verbindungs-
    # abriss im Takt des Intervalls. Eine Regel fuer eine Adresse, die der
    # Hersteller nicht mehr benutzt, matcht einfach nie; sie kostet nichts.
    _new=""
    for _ip in $_want; do
        case " $_have " in
            *" $_ip "*) ;;
            *) _new="$_new $_ip" ;;
        esac
    done
    if [ -z "$_new" ] && chain_matches_options; then
        return 0
    fi
    _want=$(printf '%s %s' "$_have" "$_want" | tr ' ' '\n' \
            | grep -v '^$' | sort -u | tr '\n' ' ')
    log "installing rules for ${_want}(was: ${_have:-none})"
    # $_want, not a second resolve. A DNS blip between the two calls used to
    # hand install_rules an empty list: it flushes first, so the chain ended up
    # empty - a blackhole while the route is active - and since 0f118bc
    # drop_conntrack then tore down the connection that would otherwise have
    # ridden the blip out on its existing translation.
    install_rules "$_want"
    drop_conntrack
}

# Answers in the broker's place while capture mode is on, and prints what the
# inverter presented. Backgrounded, and restarted after each capture, so a second
# look does not need the add-on restarted.
#
# Returns non-zero when it cannot run, and the caller then leaves the rules
# pointing at the broker: sending the inverter to a port with nothing behind it
# would be exactly the blackhole this add-on exists to avoid.
start_capture() {
    if ! command -v python3 >/dev/null 2>&1; then
        log "WARN capture_credentials is on, but python3 is not in this image."
        return 1
    fi
    _cert="/ssl/$CERTFILE"
    _key="/ssl/$KEYFILE"
    if [ ! -r "$_cert" ] || [ ! -r "$_key" ]; then
        log "WARN capture_credentials is on, but $_cert or $_key cannot be read."
        log "     Set certfile and keyfile to the certificate your broker serves."
        log "     The inverter has to meet the same one here as it would there."
        return 1
    fi
    log "CAPTURE MODE: the inverter is being sent here instead of to your broker."
    log "     Its credentials appear below within about ten seconds. Turn"
    log "     capture_credentials off again once you have them."
    (
        while :; do
            python3 "$CAPTURE_SCRIPT" listen --port "$CAPTURE_PORT" \
                    --cert "$_cert" --key "$_key" --timeout 3600 2>&1 \
              | while IFS= read -r _line; do log "capture | $_line"; done
            sleep 10
        done
    ) &
    CAPTURE_PID=$!
    return 0
}

# On SIGTERM we exit, but we deliberately do NOT remove the rule.
#
# Why the rule stays: it only matches `-s <inverter> -d <vendor>:<port>`. With the
# route in your router switched off, those packets never reach this host - the
# rule is unreachable. With it switched on, you want the rule. A leftover rule
# can, by construction, only take effect when it should.
#
# An earlier version removed it here. That turned every clean stop into a
# blackhole: the host has -P FORWARD DROP, so the packets vanished. A hard crash,
# which never ran the trap, left the rule in place and the device kept working -
# the failure modes were the wrong way round.
#
# Why there is a trap at all, rather than none: without one the shell sits in
# `wait` and never acts on SIGTERM, so Docker kills it after its ten-second grace
# period and the Supervisor reports the add-on as `error` instead of `stopped`.
# Measured 2026-08-12: "Stopping" 20:21:37, "Cleaning" 20:21:47 - exactly the
# grace period, every single stop.
on_term() {
    log "stopping - the rule stays; the route in your router is the switch"
    [ -n "${CAPTURE_PID:-}" ] && kill "$CAPTURE_PID" 2>/dev/null
    exit 0
}
trap on_term INT TERM

main() {
    load_options

    # Before any rule is written: if the listener cannot come up, the rules must
    # keep pointing at the broker rather than at a port with nothing behind it.
    if [ "${CAPTURE:-false}" = "true" ] && ! start_capture; then
        CAPTURE=false
        set_target
        log "     Staying on the broker. Nothing is redirected away from it."
    fi

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
    log "active: ${SOURCE_IP:-<unknown>} -> $DNS_NAME:$PORT  ==>  $TARGET (every ${INTERVAL}s)"

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

        # Jede Runde, nicht nur beim Start: ensure_chain ist idempotent, und
        # ohne den Sprung in PREROUTING greift keine einzige Regel, waehrend
        # ensure() zufrieden ist und der Zaehler auf seinem alten Wert steht.
        refresh_broker_ip
        set_target
        ensure_chain
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
