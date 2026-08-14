#!/bin/sh
# Self-test of the pure logic in run.sh. Touches no network and no real iptables.
#
# Addresses come from RFC 5737 (TEST-NET-1/2/3) on purpose: these tests are
# published, and a real home network has no business in them.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASE_PATH="$HERE/stub:$PATH"
export EZHI_REROUTE_LIB=1
PASS=0; FAIL=0

setup() {
    WORK=$(mktemp -d)
    # Reset PATH for every test: one that prepends its own stub would otherwise
    # leak into all the following ones.
    export PATH="$BASE_PATH"
    export STUB_LOG="$WORK/calls" STUB_RC=0
    export STUB_CHAIN=/dev/null STUB_PREROUTING=/dev/null STUB_COUNTERS=/dev/null
    : > "$STUB_LOG"
    SOURCE_IP=192.0.2.10; BROKER_IP=192.0.2.20; PORT=9005
    DNS_NAME=broker.example.invalid; VENDOR_IP=""
    # What load_options ends with in production. Anything that changes BROKER_IP
    # or CAPTURE has to call set_target again, exactly as the daemon loop does.
    CAPTURE=false; CERTFILE=""; KEYFILE=""; set_target
}

check() {   # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); printf 'FAIL %s\n  erwartet: [%s]\n  ist:      [%s]\n' "$1" "$2" "$3"; fi
}

. "$HERE/../ezhi_reroute/run.sh"

# run.sh sets `set -eu` for daemon use. The harness must undo that: a test that
# checks a FAILURE - $(detect_source >/dev/null 2>&1; echo $?) - would abort the
# command substitution before `echo` ever runs. Measured: with the leak, macOS
# /bin/sh reports 18/1 while busybox ash reports 19/0. Without it, both agree.
set +eu

# --- Task 2: resolving the vendor endpoint --------------------------------

setup
VENDOR_IP=198.51.100.7
check "feste vendor_ip gewinnt" "198.51.100.7" "$(resolve_vendor)"

setup
cat > "$WORK/getent" <<'EOF'
#!/bin/sh
printf '203.0.113.9  STREAM x\n203.0.113.9  DGRAM  x\n203.0.113.4  STREAM x\n'
EOF
chmod +x "$WORK/getent"; export PATH="$WORK:$PATH"
check "aufgeloest, sortiert, dedupliziert" "203.0.113.4 203.0.113.9" "$(resolve_vendor | tr '\n' ' ' | sed 's/ $//')"

# --- Task 3: chain management ---------------------------------------------

setup
cat > "$WORK/chain" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.9/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
STUB_CHAIN="$WORK/chain"
check "Adressen aus der Chain, ohne /32" "203.0.113.4 203.0.113.9" "$(chain_addresses | tr '\n' ' ' | sed 's/ $//')"

setup
STUB_CHAIN=/dev/null
check "leere Chain ergibt leere Menge" "" "$(chain_addresses)"

setup
install_rules "203.0.113.4
203.0.113.9"
check "eine Regel je Adresse" "2" "$(grep -c -- '-A EZHI_REROUTE' "$STUB_LOG")"
check "Chain wird zuerst geleert" "1" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"
check "jede Regel bindet die Quelle" "2" "$(grep -c -- '-s 192.0.2.10' "$STUB_LOG")"

# --- Task 4: migrating away from the 0.3.0 rule ---------------------------

setup
cat > "$WORK/pre" <<'EOF'
-P PREROUTING ACCEPT
-A PREROUTING -j EZHI_REROUTE
-A PREROUTING -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
-A PREROUTING -s 192.0.2.99/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.77:9005
EOF
STUB_PREROUTING="$WORK/pre"
drop_legacy_rules
check "genau die eigene Alt-Regel wird geloescht" "1" "$(grep -c -- '-D PREROUTING' "$STUB_LOG")"
check "fremde DNAT-Regel bleibt unangetastet" "0" "$(grep -c -- '192.0.2.77' "$STUB_LOG")"
check "der Chain-Sprung wird nicht geloescht" "0" "$(grep -c -- '-D PREROUTING -j EZHI_REROUTE' "$STUB_LOG")"

# --- Task 5: proving the inverter address ---------------------------------

setup
cat > "$WORK/arp" <<'EOF'
IP address       HW type     Flags       HW address            Mask     Device
192.0.2.5        0x1         0x2         aa:bb:cc:dd:ee:01     *        eth0
192.0.2.10       0x1         0x2         aa:bb:cc:dd:ee:02     *        eth0
EOF
ARP_TABLE="$WORK/arp"; export STUB_EZHI_IP=192.0.2.10
check "findet den Wechselrichter in der ARP-Tabelle" "192.0.2.10" "$(detect_source)"

setup
cat > "$WORK/arp" <<'EOF'
IP address       HW type     Flags       HW address            Mask     Device
192.0.2.5        0x1         0x2         aa:bb:cc:dd:ee:01     *        eth0
192.0.2.11       0x1         0x0         00:00:00:00:00:00     *        eth0
EOF
ARP_TABLE="$WORK/arp"; export STUB_EZHI_IP=192.0.2.11
check "unvollstaendiger ARP-Eintrag wird nicht geprobt" "" "$(detect_source)"
check "kein Fund ist ein Fehlschlag" "1" "$(detect_source >/dev/null 2>&1; echo $?)"

# --- Task 6: the packet counter -------------------------------------------

setup
cat > "$WORK/cnt" <<'EOF'
Chain EZHI_REROUTE (1 references)
    pkts      bytes target     prot opt in     out     source               destination
       3      180 DNAT       tcp  --  *      *       192.0.2.10           203.0.113.4
       0        0 DNAT       tcp  --  *      *       192.0.2.10           203.0.113.9
EOF
STUB_COUNTERS="$WORK/cnt"
check "Zaehler werden summiert" "3" "$(packet_count)"

setup
STUB_COUNTERS=/dev/null
check "keine Chain ergibt 0, nicht leer" "0" "$(packet_count)"

# --- Task 7: the state file -----------------------------------------------

setup
STATE_FILE="$WORK/state.json"
write_state ok "203.0.113.4
203.0.113.9" 3
check "Zustandsdatei ist gueltiges JSON" "ok" "$(jq -r .rule "$WORK/state.json")"
check "Adressen als JSON-Array" "2" "$(jq '.addresses | length' "$WORK/state.json")"
check "Zaehler als Zahl, nicht als Text" "number" "$(jq -r '.packets | type' "$WORK/state.json")"

setup
STATE_FILE="$WORK/state.json"
write_state ok "" 0
check "leere Adressmenge ergibt leeres Array" "0" "$(jq '.addresses | length' "$WORK/state.json")"

# --- Task 8: dropping the tracked connections after a rule change ---------

setup
drop_conntrack
check "conntrack wird auf Quelle und Port eingegrenzt" "1" \
  "$(grep -c '^conntrack -D -s 192.0.2.10 -p tcp --dport 9005$' "$STUB_LOG")"

setup
check "nichts zu loeschen ist kein Fehler" "0" \
  "$( (STUB_CT_RC=1; export STUB_CT_RC; drop_conntrack; echo $?) )"

setup
SOURCE_IP=""
drop_conntrack
check "ohne Quelladresse wird nichts geloescht" "0" "$(grep -c '^conntrack' "$STUB_LOG")"

setup
check "fehlendes conntrack ist kein Daemon-Tod" "0" \
  "$( (PATH="$WORK"; export PATH; drop_conntrack >/dev/null 2>&1; echo $?) )"

setup
cat > "$WORK/chain" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
STUB_CHAIN="$WORK/chain"; VENDOR_IP=203.0.113.4
ensure
check "unveraenderte Adressmenge laesst die Verbindung in Ruhe" "0" \
  "$(grep -c '^conntrack' "$STUB_LOG")"

setup
STUB_CHAIN="$WORK/chain2"; : > "$WORK/chain2"; VENDOR_IP=203.0.113.9
ensure
check "Adresswechsel loescht den alten Verbindungszustand" "1" \
  "$(grep -c '^conntrack -D' "$STUB_LOG")"

# --- Task 9: die Faelle, die der Review 2026-08-13 aufgedeckt hat -----------

setup
# H1: gleiche Adressmenge, aber der Nutzer hat den Broker umgestellt. Vorher
# blieb die alte Regel ewig stehen, weil nur -d verglichen wurde.
cat > "$WORK/chain" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
STUB_CHAIN="$WORK/chain"; VENDOR_IP=203.0.113.4
BROKER_IP=192.0.2.99; set_target          # Option geaendert
ensure
check "Broker-Wechsel installiert neu" "1" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"

setup
STUB_CHAIN="$WORK/chain2"
cat > "$WORK/chain2" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
VENDOR_IP=203.0.113.4
SOURCE_IP=192.0.2.77                      # Quelle geaendert
ensure
check "Quell-Wechsel installiert neu" "1" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"

setup
STUB_CHAIN="$WORK/chain3"
cat > "$WORK/chain3" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
VENDOR_IP=203.0.113.4
ensure
check "unveraenderte Optionen installieren NICHT neu" "0" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"

setup
# H2: getent liefert beim ZWEITEN Aufruf nichts. Vorher flushte install_rules
# die Chain leer (Blackhole) und drop_conntrack riss die Verbindung dazu.
cat > "$WORK/getent" <<'EOF'
#!/bin/sh
n=$(cat "$STUB_LOG.getent" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STUB_LOG.getent"
[ "$n" -eq 0 ] && printf '203.0.113.4  STREAM x\n'
exit 0
EOF
chmod +x "$WORK/getent"; export PATH="$WORK:$BASE_PATH"
ensure
check "DNS-Blip laesst die Chain nicht leer zurueck" "1" "$(grep -c -- '-A EZHI_REROUTE' "$STUB_LOG")"
check "und reisst die Verbindung nicht ohne Regeln" "1" "$(grep -c '^conntrack -D' "$STUB_LOG")"

setup
# M3: Prefix-Kollision. Die eigene Quelle .10 darf die fremde Regel .100 nicht
# treffen -- ohne /32-Anker loeschte grep sie mit.
cat > "$WORK/pre" <<'EOF'
-P PREROUTING ACCEPT
-A PREROUTING -j EZHI_REROUTE
-A PREROUTING -s 192.0.2.100/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
STUB_PREROUTING="$WORK/pre"
drop_legacy_rules
check "fremde Regel mit laengerem Praefix bleibt" "0" "$(grep -c -- '-D PREROUTING' "$STUB_LOG")"

# --- Task 10: DNS-Rotation und Broker-Adresse -------------------------------

setup
# M2: rotierende A-Records duerfen keinen Flush ausloesen, sobald die Adresse
# schon in der Chain steht. Vorher differierte die Menge jede Runde -> Flush
# plus conntrack-Drop im Takt des Intervalls.
cat > "$WORK/chain" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.9/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
STUB_CHAIN="$WORK/chain"; VENDOR_IP=203.0.113.9      # heute nur der zweite Record
ensure
check "Rotation loest keinen Flush aus" "0" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"
check "und reisst die Verbindung nicht" "0" "$(grep -c '^conntrack' "$STUB_LOG")"

setup
STUB_CHAIN="$WORK/chain2"
cat > "$WORK/chain2" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.20:9005
EOF
VENDOR_IP=203.0.113.9                                 # wirklich neue Adresse
ensure
check "eine neue Adresse installiert neu" "1" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"
check "und behaelt die alte bei" "2" "$(grep -c -- '-A EZHI_REROUTE' "$STUB_LOG")"

setup
# L1: ohne broker_ip-Option wird die Host-Adresse pro Runde nachgezogen.
BROKER_OPT=""; BROKER_IP=192.0.2.20
cat > "$WORK/ip" <<'EOF'
#!/bin/sh
echo "1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.55 uid 0"
EOF
chmod +x "$WORK/ip"; export PATH="$WORK:$BASE_PATH"
refresh_broker_ip
check "neue Host-Adresse wird uebernommen" "192.0.2.55" "$BROKER_IP"

setup
BROKER_OPT="192.0.2.20"; BROKER_IP=192.0.2.20
cat > "$WORK/ip" <<'EOF'
#!/bin/sh
echo "1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.55 uid 0"
EOF
chmod +x "$WORK/ip"; export PATH="$WORK:$BASE_PATH"
refresh_broker_ip
check "gesetzte Option gewinnt gegen die Autoerkennung" "192.0.2.20" "$BROKER_IP"

setup
BROKER_OPT=""; BROKER_IP=192.0.2.20
cat > "$WORK/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/ip"; export PATH="$WORK:$BASE_PATH"
refresh_broker_ip
check "leere Antwort behaelt die alte Adresse" "192.0.2.20" "$BROKER_IP"

setup
# L6: fehlendes check_interval darf keine Hot-Loop erzeugen.
cat > "$WORK/options.json" <<'EOF'
{"source_ip":"","vendor_ip":"","broker_ip":"192.0.2.20","dns_name":"x.invalid","port":9005}
EOF
EZHI_OPTIONS="$WORK/options.json" load_options >/dev/null 2>&1
check "fehlendes check_interval faellt auf 60" "60" "$INTERVAL"

# --- Task 10: capture mode -------------------------------------------------

stub_host_ip() {   # stub_host_ip <adresse|"">
    if [ -n "$1" ]; then
        printf '#!/bin/sh\necho "1.1.1.1 via 192.0.2.1 dev eth0 src %s uid 0"\n' "$1" > "$WORK/ip"
    else
        printf '#!/bin/sh\nexit 0\n' > "$WORK/ip"
    fi
    chmod +x "$WORK/ip"; export PATH="$WORK:$BASE_PATH"
}

setup
stub_host_ip 192.0.2.55
CAPTURE=true; set_target
check "Capture zielt auf diesen Host und den Capture-Port" "192.0.2.55:19005" "$TARGET"

setup
# Der Broker steht woanders. Capture darf ihm NICHT folgen: DNAT schreibt nur das
# Ziel um, also antwortete die fremde Maschine unter ihrer eigenen Adresse und
# der Wechselrichter verwirft die Antwort - er wartet auf den Hersteller.
stub_host_ip 192.0.2.55
BROKER_IP=198.51.100.7; CAPTURE=true; set_target
check "Capture ignoriert broker_ip" "192.0.2.55:19005" "$TARGET"

setup
# Ohne Host-Adresse (Boot-Race) waere das Ziel ":19005". Jedes -A nach dem -F
# scheitert daran, die Chain bleibt leer - genau das Blackhole.
stub_host_ip ""
CAPTURE=true; set_target
check "ohne Host-Adresse bleibt es beim Broker" "192.0.2.20:9005" "$TARGET"

setup
stub_host_ip 192.0.2.55
CAPTURE=true; set_target
install_rules "203.0.113.4"
check "die Regel traegt den Capture-Port" "1" \
      "$(grep -c -- '--to-destination 192.0.2.55:19005' "$STUB_LOG")"

setup
# Capture wieder aus: die installierten Regeln zeigen noch auf den Capture-Port,
# passen also nicht mehr zu den Optionen und muessen neu geschrieben werden.
cat > "$WORK/chain" <<'EOF'
-N EZHI_REROUTE
-A EZHI_REROUTE -s 192.0.2.10/32 -d 203.0.113.4/32 -p tcp -m tcp --dport 9005 -j DNAT --to-destination 192.0.2.55:19005
EOF
STUB_CHAIN="$WORK/chain"; VENDOR_IP=203.0.113.4
ensure
check "Capture aus installiert neu" "1" "$(grep -c -- '-F EZHI_REROUTE' "$STUB_LOG")"
check "und zeigt wieder auf den Broker" "1" \
      "$(grep -c -- '--to-destination 192.0.2.20:9005' "$STUB_LOG")"

# Derselbe Selbsttest, den die Datei auch im Integrations-Repo mitbringt.
if command -v python3 >/dev/null 2>&1; then
    check "capture_credentials selftest" "selftest ok" \
          "$(python3 "$HERE/../ezhi_reroute/capture_credentials.py" selftest 2>&1)"
else
    printf 'SKIP capture_credentials selftest (kein python3)\n'
fi

printf '\n%d bestanden, %d fehlgeschlagen\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
