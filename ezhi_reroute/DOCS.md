# EZHI Reroute

Gives you local control of an APsystems EZHI inverter by sending its MQTT
connection to a broker you run, instead of to the vendor's cloud.

It exists because the inverter has **no setting for its broker address**. The
hostname is fixed in the firmware — established three separate ways: a sweep of
the BLE command identifiers, decompiling the vendor app, and reading the EZ1-M
firmware in Ghidra. The vendor app's entire command vocabulary has no field for a
server, broker or host. So the redirect has to happen in your network.

Meant to be used with the
[apsystems_ezhi_local](https://github.com/Glenbeulah/EZHI) integration set to the
`local_mqtt` control transport.

## What this add-on does, and what it does not

It holds one `iptables` DNAT rule per resolved vendor address, in its own chain,
and checks every minute that they are still there.

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
  "broker": "192.0.2.20:9005"
}
```

**`packets` settles at a small number and does not grow.** The nat table counts
only the first packet of each connection, and the inverter holds one long-lived
MQTT connection. So `0` is the signal, not "it stopped rising".

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

What this add-on does have over the DNS approaches: the rule is bound to the
inverter's address, so **the vendor app on your phone keeps working at home**. A
network-wide DNS rewrite redirects the app along with the inverter.

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
