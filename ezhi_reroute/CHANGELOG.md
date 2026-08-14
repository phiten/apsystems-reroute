# Changelog

## 1.2.0

- **Added: `capture_credentials`.** Your broker has to accept the inverter, and
  the inverter authenticates with a password held in its firmware — printed
  nowhere on it, and not something Mosquitto will tell you, since a rejected
  client is logged by name and never by password. Reading it off the wire meant
  standing something on port 9005 in the broker's place, which is awkward
  everywhere and worst here: with the routing mechanism the only machine the
  inverter's traffic reaches is this one, and the broker already owns that port.

  Turn the option on and the DNAT rules point at a listener inside this add-on
  instead, on a port of its own. The inverter arrives within about ten seconds
  and its client id, username and password go into the log. **The broker does
  not have to be stopped**, and nothing has to be moved to another machine. Turn
  the option off and the rules go back to the broker on the next round.

  Set `certfile` and `keyfile` to the certificate your broker serves, under
  `/ssl`: the inverter has to meet the same one here as it would there. If
  either is missing, or this host has no address yet, the rules stay on the
  broker rather than pointing at a port with nothing behind it.
  Verified against a real inverter on 2026-08-15: credentials in the log about
  ten seconds after the restart, and the password matched one captured by hand
  off a packet trace months earlier. The parser is pinned by a selftest that runs
  in the test suite and inside the built image.
- The state file gained a `mode` field, `normal` or `capture`, and `broker` now
  reports where the rules actually point rather than the configured broker.

## 1.1.0

- **Fixed:** a rule change did not move a connection that was already up. The
  nat table only ever sees the first packet of one, so the inverter kept
  talking through the translation it got under the old rules while the fresh
  rule sat at zero packets. The tracked entry carries a five-day timeout, so
  `packets: 0` could have meant "everything is fine" for days. The tracked
  connection is now dropped when the rules change, which makes that counter
  mean what this add-on says it means.
- **Fixed:** the rule set was compared by resolved address only. Change
  `broker_ip` or `source_ip` in the options and the address set is identical,
  so the old rule stayed in place forever — while the state file, which reports
  the option values, showed the new broker. The one diagnostic channel lied in
  exactly the case it exists for.
- **Fixed:** a DNS blip between two lookups in the same round could hand the
  installer an empty address list. It flushes first, so the chain ended up
  empty — a blackhole while the route is active.
- **Fixed:** the jump into `PREROUTING` was only checked at startup. Flush that
  chain from anywhere and no rule matches, while the packet counter freezes at
  its old non-zero value and everything looks healthy.
- **Fixed:** the migration of pre-0.4 rules matched source addresses by prefix,
  so an install on `.10` could delete a foreign rule on `.100`.
- **Changed:** the address set is additive. A load balancer handing out
  rotating subsets made it differ every round, and every round meant a flush —
  one dropped connection per check interval.
- **Fixed:** the broker address is re-read each round when the option is empty.
  Taken once at startup, a boot-time race with the network left an empty
  destination, and a DHCP change was never picked up.
- **Fixed:** a missing `check_interval` produced an empty `sleep` argument,
  which the surrounding guard turned into a 100% CPU loop instead of an error.
- **Fixed** in `examples/fritz_route.py`: only "no such entry" means "off" now.
  Auth failures, bad arguments after a FRITZ!OS update and internal errors were
  all reported as "off" too, so the switch showed the inverter on cloud while
  the state was in fact unknown. They exit non-zero carrying the box's own
  reason. A fault on the write path was ignored entirely. `routes --dry-run`
  sent real requests.
- **Docs:** the state-file example gained the staleness guard it needed. These
  containers run with `RestartPolicy=no`: if this one dies, the file stops
  changing and keeps its last `"rule": "ok"` forever, and a sensor reading only
  `rule` reports a dead add-on as healthy.

## 1.0.0

First public release.
