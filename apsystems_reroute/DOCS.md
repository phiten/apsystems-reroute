# EZHI Reroute

Gives you local control of an APsystems EZHI inverter by sending its MQTT
connection to a broker you run, instead of to the vendor's cloud.

It exists because the inverter has **no setting for its broker address**. The
hostname is fixed in the firmware — established three separate ways: a sweep of
the BLE command identifiers, decompiling the vendor app, and reading the EZ1-M
firmware in Ghidra. The vendor app's entire command vocabulary has no field for a
server, broker or host. So the redirect has to happen in your network.

Meant to be used with the
[apsystems_ezhi_local](https://github.com/kamilkosek/EZHI) integration set to the
`local_mqtt` control transport.

## What this add-on does, and what it does not

It holds one `iptables` DNAT rule per resolved vendor address, in its own
chain, and re-checks every round (default 60 s, configurable) that the chain,
its rules and the jump into `PREROUTING` are all still in place.

**It is not a switch.** What decides whether your inverter talks to your broker or
to the vendor is the **static route in your router**. This add-on only makes sure
that traffic arriving here is actually redirected. Turning it off does not put the
inverter back on the vendor cloud — removing the route does.

## What you have to set up in your router

A static route that sends the vendor's address to the host running this add-on:

| | |
|---|---|
| Network | the vendor address, as a `/32` host route |
| Gateway | the IP of the host running Home Assistant |

You do not have to look the address up. Start the add-on and read its log:

```
[ezhi_reroute] 2026-01-01 12:00:00 detected the inverter at 192.0.2.10 - set source_ip in the options to skip this search
[ezhi_reroute] 2026-01-01 12:00:00 installing rules for 198.51.100.7 (was: none)
[ezhi_reroute] 2026-01-01 12:00:00 active: 192.0.2.10 -> data.mqtt.apsystemsema.com:9005  ==>  192.0.2.20:9005
```

The address after `installing rules for` is the one your route needs.

Set `source_ip` to a comma-separated list to redirect multiple inverters, for
example `192.0.2.10,192.0.2.11`. Each device gets rules for the same vendor
addresses and is sent to the same broker. Leave the option empty for automatic
detection of one inverter.

Your broker must listen on **port 9005 with TLS 1.2** and present a certificate
for the vendor's MQTT hostname. Self-signed is fine — the device validates
nothing, which is the whole reason this works.

### Did it work?

After five minutes, if the rule has never matched a packet, the log says so:

```
WARN the rule is installed but has never matched a packet.
     Your router is not sending this traffic here. Check the
     static route: 198.51.100.7 -> this host.
```

That message means the add-on side is fine and the router side is not.

## The password your broker has to accept

The inverter authenticates. Its client id and username are both the serial number
on its label; its password is 25 characters held in firmware, printed nowhere,
and not something your broker will tell you either — a rejected client is logged
by name and never by password. It has to be read off the wire once.

By hand that means standing something on port 9005 in your broker's place, which
is awkward everywhere and worst here: with this mechanism the only machine the
inverter's traffic ever reaches is this one, and the broker already holds that
port. So the add-on does it instead.

1. Put the certificate your broker serves into `/ssl`, and name the two files in
   **`certfile`** and **`keyfile`**. The inverter has to meet the same
   certificate here as it would at the broker.
2. Turn **`capture_credentials`** on and restart the add-on.
3. Watch the log. Within about ten seconds:

   ```
   CAPTURE MODE: the inverter is being sent here instead of to your broker.
   capture | connection from 192.0.2.10
   capture | client id : D00000000000
   capture | username  : D00000000000
   capture | password  : ****
   ```

4. Put that username and password into your broker's logins, turn
   `capture_credentials` back off, and the rules return to the broker on the next
   round.

**Your broker keeps running throughout.** The listener sits on a port of its own,
and the DNAT rule is what decides where the inverter lands — so nothing has to be
stopped and nothing has to move to another machine.

Capture always redirects to **this** host, even when `broker_ip` points somewhere
else. DNAT rewrites the destination and not the source, so a third machine would
answer the inverter under its own address, and the inverter would discard the
reply: it is waiting to hear from the vendor.

If the certificate cannot be read, or this host has no address yet, capture does
not start and the rules stay on the broker. Sending the inverter to a port with
nothing behind it would be the blackhole below.

Measured end to end against a real inverter on 2026-08-15: the credentials
appeared about ten seconds after the restart, and the password matched one that
had been captured by hand, off a packet trace, months earlier. Turning the option
back off returned the rules to the broker on the next round.

## The blackhole, and how to avoid it

Docker sets `-P FORWARD DROP` on the host. So with the **route active** and **no
rule installed**, the inverter's packets arrive here and are dropped — it then
reaches neither your broker nor the vendor cloud.

A reboot clears the nat table, so that is the situation to guard against:

- **Leave `boot: auto` on**, so the rules are back before anything misses them.
- **Turn on the Watchdog** (below), so a container that dies comes back.

**Stopping the add-on is not one of the ways to get there.** It deliberately keeps
its rule, so the redirect survives a stop, an update and a crash alike. A leftover
rule only matches traffic from your inverter to the vendor address: with the route
off it is unreachable, with the route on you want it. An earlier version removed
the rule on shutdown, which turned every clean stop into the blackhole above.

**To go back to the vendor cloud, remove the route.** Stopping the add-on will not
do it — the add-on is not the switch.

### Turn on the Watchdog

Add-ons run with `RestartPolicy=no`. Without the **Watchdog** toggle on this
add-on's page, nothing restarts it if its container dies. Turn it on: measured on
a live host, it caught a killed container (exit code 137) and had it running again
**178 ms** later — and it does that without this add-on declaring a health
endpoint, so the toggle is all it takes.

## Reading the state file

Every check writes `/share/ezhi_reroute.json`:

```json
{
  "ts": "2026-01-01T12:00:00+0100",
  "rule": "ok",
  "addresses": ["198.51.100.7"],
  "packets": 1,
  "source_ip": "192.0.2.10",
  "broker": "192.0.2.20:9005",
  "mode": "normal"
}
```

**`broker` is where the rules actually point**, not the configured `broker_ip`.
In capture mode it names this host and the capture port, and `mode` reads
`capture` — which is also the honest answer to "why is my broker seeing
nothing".

**`packets` settles at a small number and does not grow.** The nat table counts
only the first packet of each connection, and the inverter holds one long-lived
MQTT connection. So `0` is the signal, not "it stopped rising".

The counter survives a restart of this add-on untouched — the chain is only
flushed when the vendor's address set actually changes. When that happens, the
add-on also drops the inverter's tracked connection, so the device reconnects
through the new rules instead of riding out the translation it got under the
old ones. Without that, a fresh rule could sit at `0` while everything worked,
which would make `0` mean two different things.

`ts` comes from busybox and carries no colon in its offset (`+0100`), which is
valid ISO 8601 but not what Home Assistant's `device_class: timestamp` accepts —
treat it as a string, or reformat it.

A sensor that turns this into an alert:

```yaml
command_line:
  - sensor:
      name: EZHI reroute
      unique_id: ezhi_reroute_state
      command: "cat /share/ezhi_reroute.json"
      value_template: "{{ value_json.rule }}"
      json_attributes:
        - packets
        - addresses
        - ts
      scan_interval: 120
```

Check `ts` as well, not just `rule`. Add-on containers run with
`RestartPolicy=no`: if this one dies, the file simply stops changing and keeps
its last `"rule": "ok"` forever. A sensor that reads only `rule` will report a
dead add-on as healthy.

```yaml
template:
  - binary_sensor:
      - name: EZHI reroute problem
        # now() is load-bearing: it makes Home Assistant re-render every
        # minute. Without it this hangs on a state change of the sensor above -
        # which is exactly what stops happening when the add-on dies.
        state: >
          {% set src = 'sensor.ezhi_reroute' %}
          {% set ts = state_attr(src, 'ts') %}
          {{ states(src) != 'ok'
             or ts is none
             or (now() - (ts | as_datetime)).total_seconds() > 300
             or (state_attr(src, 'packets') | int(-1)) < 1
             or (state_attr(src, 'addresses') | count) > 1 }}
```

## When this is the wrong mechanism

There are four ways to get the inverter's traffic to your broker. They differ in
effort — and in something less obvious: **whether you can undo it when you are not
at home.** If you ever want the vendor app while away, that column decides for you.

| Mechanism | What it costs | What it risks | Undo it remotely? |
|---|---|---|---|
| **This add-on** — DNAT plus a static route | A router that can do static routes | The switch lives in your router, not with you. Blackhole as described above | **Only if your router has an API.** AVM FRITZ!Box: yes, via TR-064 — see `examples/`. Most ISP boxes: no |
| **Network-wide DNS** — AdGuard Home or Pi-hole with one rewrite | One add-on, one rule | All name resolution now depends on that host. The rewrite also catches the vendor app while your phone is on WiFi | **Yes, for anyone** — both have REST APIs |
| **Separate segment** — a second router or AP, inverter only | Spare hardware, a new SSID, re-provisioning, a port forward back for the local HTTP API | Nothing outside that segment | Usually, if you run the segment |
| **Per-device DNS via DHCP** — hand the inverter another resolver by MAC | Your DHCP has to move to the host doing this | If that host dies, no device gets a lease | Yes, if you can reach that host |

**If your router cannot be automated, prefer the DNS route.** Then the switch sits
on a machine you can reach through Home Assistant rather than behind your router's
login.

**If you want the vendor app while away and would rather not switch at all**, look
at bridging your broker to the vendor cloud instead. It has real downsides — your
broker becomes a permanent man-in-the-middle and a single point of failure for the
cloud path as well — but it needs no switch. The integration's README covers it.

What this add-on has over the DNS approaches is real but narrower than it sounds.
The rule is bound to the inverter's address, so the app on your phone is never
redirected: it reaches the vendor as usual, logs in, and behaves normally. A
network-wide DNS rewrite would send the app's own MQTT to your broker along with
the inverter's.

**It will still show your inverter as offline** — measured 2026-08-15 on a phone
on the home network, with Home Assistant controlling the device happily at the
same time. That is not the redirect failing, it is the redirect working: the
inverter has left the vendor cloud, the cloud therefore knows nothing about it,
and the app reports what the cloud knows. Every mechanism on this page does that,
this one included. Keeping the app's view alive takes the bridging broker above,
and nothing less.

## Known limitations

**A second A record.** If the vendor hostname starts resolving to more than one
address, this add-on installs a rule for each — but your router's route still
covers only the one you entered. The inverter can then reach the vendor past the
redirect, and everything looks normal. The log names the new address so you can
add it; the add-on cannot fix it, because the route is not here.

**aarch64 only.** The iptables compatibility this depends on (container 1.8.13
nf_tables against the host's 1.8.11 nf_tables) was verified on an aarch64 HAOS
host. On an amd64 host using the legacy backend, the container would write into
an nf_tables view the host does not consult, and the redirect would silently not
happen. If you run amd64 and want to help, build it there and report back.

## What you give up while redirected

The vendor app, OTA updates, and any remote wake — the cloud can no longer reach
the inverter. It keeps running on its own settings regardless: a dead broker means
"I cannot change anything", not "the battery stops".
