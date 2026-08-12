# EZHI Reroute — a Home Assistant add-on

Local control of an APsystems EZHI inverter, by sending its MQTT connection to a
broker you run instead of to the vendor's cloud.

The inverter has no setting for its broker address — the hostname is fixed in the
firmware. So the redirect has to happen in your network. This add-on holds the
`iptables` DNAT rule that does it; the static route that brings the traffic here
is something you add in your router.

Built for use with the
[apsystems_ezhi_local](https://github.com/kamilkosek/EZHI) integration on its
`local_mqtt` control transport.

## Install

1. Home Assistant → **Settings → Add-ons → Add-on Store**
2. The three-dot menu → **Repositories** → add
   `https://github.com/Glenbeulah/ezhi-reroute`
3. Install **EZHI Reroute**, start it, and read its log — it tells you the exact
   static route to add in your router.
4. Turn on the **Watchdog** toggle on the add-on's page.

Full documentation: [`ezhi_reroute/DOCS.md`](ezhi_reroute/DOCS.md). Read the
"When this is the wrong mechanism" section before you commit to this approach —
for some networks a DNS rewrite is the better fit, and the reason is not effort.

## Requirements

- Home Assistant OS on **aarch64** (see the limitations section in DOCS.md)
- A router that can do static routes
- An MQTT broker on port 9005 with TLS 1.2, e.g. the Mosquitto add-on

## Extras

`examples/` contains an optional switch for AVM FRITZ!Box users: it toggles the
static route over TR-064, which makes the redirect something you can undo from
Home Assistant when you are not at home. Owners of other routers with an API can
use it as a template.

## Tests

```sh
sh tests/run_tests.sh
python3 tests/test_fritz_route.py
```

The shell tests stub `iptables`, `getent` and `wget`, so they touch neither the
network nor your firewall. They run under both macOS `/bin/sh` and busybox `ash`.
