#!/usr/bin/env python3
"""Toggle a FRITZ!Box static route over TR-064, so the reroute can be undone from
Home Assistant when you are not at home.

  fritz_route.py state             prints 1 (route active) or 0
  fritz_route.py on|off            flips the checkbox, prints the resulting state
  fritz_route.py routes            lists every static route, read-only, in the
                                   exact shape this file's config wants
  fritz_route.py state --dry-run   prints the request instead of sending it

Start with `routes`. It is read-only and it hands you the four identifying
fields, which have to match byte for byte and which the web interface does not
show you.

Why this exists: with the DNAT mechanism the switch lives in your router, and most
people cannot reach their router from outside their home. This puts the switch in
Home Assistant, which you probably can reach. Off means the inverter goes back to
the vendor cloud, so the vendor app works again.

Credentials live in fritz_route.json next to this file, mode 600 - NOT in
arguments, where they would show up in the process list. Copy
fritz_route.example.json and fill it in. The four identifying fields must match
your route exactly; the box identifies a route by them, not by a name.

Requires a FRITZ!Box user with the "Einstellungen" / settings permission, and
TR-064 enabled (Heimnetz -> Netzwerk -> Netzwerkeinstellungen -> "Zugriff für
Anwendungen zulassen").

Standard library only, on purpose: this runs inside the Home Assistant container,
where installing packages is not something an example should ask for.
"""
from __future__ import annotations

import json
import pathlib
import sys
import urllib.error
import urllib.request

SERVICE = "urn:dslforum-org:service:Layer3Forwarding:1"
CONTROL = "/upnp/control/layer3forwarding"
CONFIG = pathlib.Path(__file__).with_name("fritz_route.json")

FIELDS = (("NewDestIPAddress", "dest"), ("NewDestSubnetMask", "dest_mask"),
          ("NewSourceIPAddress", "source"), ("NewSourceSubnetMask", "source_mask"))


def soap_action(action: str) -> str:
    return f"{SERVICE}#{action}"


def envelope(action: str, conf: dict, enable: bool | None = None) -> str:
    args = "".join(f"<{tag}>{conf[key]}</{tag}>" for tag, key in FIELDS)
    if enable is not None:
        args += f"<NewEnable>{1 if enable else 0}</NewEnable>"
    return ('<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{SERVICE}">{args}</u:{action}>'
            '</s:Body></s:Envelope>')


def field(reply: str, tag: str) -> str:
    """The text of one XML tag, or "" when it is not there."""
    start = reply.find(f"<{tag}>")
    if start == -1:
        return ""
    end = reply.find(f"</{tag}>", start)
    if end == -1:
        # Ohne diesen Check schneidet das Slice bei -1 das letzte Zeichen ab und
        # liefert stillen Muell statt "".
        return ""
    return reply[start + len(tag) + 2:end].strip()


# Der eine Fault, der wirklich "aus" bedeutet: die Route steht nicht in der Box,
# also ist sie auch nicht in Kraft. Alles andere - Auth, falsche Argumente nach
# einem FRITZ!OS-Update, interne Fehler - ist ein UNBEKANNTER Zustand und darf
# nicht als "aus" durchgehen: der Schalter zeigte dann "Wechselrichter in der
# Cloud", obwohl niemand weiss, was die Box tut.
_NO_SUCH_ENTRY = ("713", "714", "NoSuchEntry", "SpecifiedArrayIndexInvalid")


def fault_reason(reply: str) -> str:
    """errorCode und errorDescription eines SOAP-Faults, oder ""."""
    if "<s:Fault>" not in reply and "<SOAP-ENV:Fault>" not in reply:
        return ""
    code = field(reply, "errorCode")
    desc = field(reply, "errorDescription") or field(reply, "faultstring")
    return f"{code} {desc}".strip() or "unspecified SOAP fault"


def parse_enable(reply: str) -> str:
    """1 or 0 - oder ein harter Abbruch, wenn der Zustand unbekannt ist."""
    value = field(reply, "NewEnable")
    if value:
        return value
    reason = fault_reason(reply)
    if reason and not any(k in reason for k in _NO_SUCH_ENTRY):
        raise SystemExit(f"FRITZ!Box fault, state unknown: {reason}")
    # Kein Eintrag (oder gar kein Fault, nur ein leeres Feld): die Route ist
    # nicht in Kraft, und genau das soll der Schalter zeigen.
    return "0"


def routes(conf: dict, dry_run: bool = False) -> int:
    """Print every static route the box holds, in the shape fritz_route.json
    wants. Read-only.

    This exists because the four identifying fields have to match the stored
    route byte for byte, and the web interface never shows you what it stored -
    it only lets you type a network, a mask and a gateway. Guessing the source
    fields is the most likely way to end up with a switch that reports `unknown`.
    """
    for index in range(32):
        body = ('<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:GetGenericForwardingEntry xmlns:u="{SERVICE}">'
                # NewForwardingIndex, not NewForwardingEntryIndex - the box
                # answers the latter with "402 Invalid Args".
                f'<NewForwardingIndex>{index}</NewForwardingIndex>'
                '</u:GetGenericForwardingEntry></s:Body></s:Envelope>')
        if dry_run:
            print(body)
            return 0
        reply = _post(conf, "GetGenericForwardingEntry", body)
        dest = field(reply, "NewDestIPAddress")
        if not dest:
            return index
        print(json.dumps({
            "dest": dest,
            "dest_mask": field(reply, "NewDestSubnetMask"),
            "source": field(reply, "NewSourceIPAddress"),
            "source_mask": field(reply, "NewSourceSubnetMask"),
            "gateway": field(reply, "NewGatewayIPAddress"),
            "enabled": field(reply, "NewEnable"),
        }))
    return 32


def call(action: str, conf: dict, enable: bool | None = None,
         dry_run: bool = False) -> str:
    body = envelope(action, conf, enable)
    if dry_run:
        url = f"http://{conf['host']}:49000{CONTROL}"
        return f"POST {url}\nSoapAction: {soap_action(action)}\n\n{body}"
    return _post(conf, action, body)


def _post(conf: dict, action: str, body: str) -> str:
    url = f"http://{conf['host']}:49000{CONTROL}"
    manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    manager.add_password(None, url, conf["user"], conf["password"])
    opener = urllib.request.build_opener(
        urllib.request.HTTPDigestAuthHandler(manager))
    request = urllib.request.Request(
        url, data=body.encode(), method="POST",
        headers={"Content-Type": 'text/xml; charset="utf-8"',
                 "SoapAction": soap_action(action)})
    try:
        with opener.open(request, timeout=15) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        # A FRITZ!Box reports "no such forwarding entry" as a SOAP fault carrying
        # HTTP 500, not as a 200 with an empty body. Without this, the graceful
        # path in parse_enable is unreachable: a mismatch between fritz_route.json
        # and the real route would crash command_state, and the switch would go
        # unknown instead of showing "off".
        if error.code == 500:
            return error.read().decode()
        raise


def load_config(dry_run: bool) -> dict:
    """The example file stands in for a dry run, so you can see what would be
    sent before wiring up credentials. Never for a real call."""
    path = CONFIG if CONFIG.exists() else CONFIG.with_name("fritz_route.example.json")
    if path is not CONFIG and not dry_run:
        raise SystemExit(f"{CONFIG.name} is missing - copy {path.name}, fill it in, chmod 600")
    conf = json.loads(path.read_text())
    if not dry_run and conf.get("password") == "CHANGE ME":
        raise SystemExit(f"{CONFIG.name} still carries the template password")
    return conf


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    command = args[1] if len(args) > 1 else "state"
    conf = load_config(dry_run)

    if command == "state":
        reply = call("GetSpecificForwardingEntry", conf, dry_run=dry_run)
        print(reply if dry_run else parse_enable(reply))
        return 0
    if command in ("on", "off"):
        written = call("SetForwardingEntryEnable", conf,
                       enable=(command == "on"), dry_run=dry_run)
        if not dry_run:
            reason = fault_reason(written)
            if reason:
                raise SystemExit(f"FRITZ!Box refused the write: {reason}")
            # Read the state back rather than echoing the intent: the switch in
            # Home Assistant should show what the box does, not what we asked for.
            print(parse_enable(call("GetSpecificForwardingEntry", conf)))
        return 0
    if command == "routes":
        print(f"# {routes(conf, dry_run=dry_run)} route(s)", file=sys.stderr)
        return 0
    print(f"usage: {args[0]} on|off|state|routes [--dry-run]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
