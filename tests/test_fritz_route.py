"""How fritz_route.py builds its SOAP calls and reads the answers.

No network: --dry-run builds the same body the live path sends, and the fault
test injects the error the box actually produces.
"""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "fritz_route", pathlib.Path(__file__).parent.parent / "examples/fritz_route.py")
fr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fr)

CONF = {"host": "192.0.2.1", "user": "u", "password": "p",
        "dest": "198.51.100.7", "dest_mask": "255.255.255.255",
        "source": "0.0.0.0", "source_mask": "0.0.0.0"}


def _fault(code: str, desc: str) -> str:
    """Die echte Form, in der eine FRITZ!Box einen Fault schickt (HTTP 500)."""
    return ('<s:Envelope><s:Body><s:Fault><faultcode>s:Client</faultcode>'
            '<faultstring>UPnPError</faultstring><detail>'
            '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
            f'<errorCode>{code}</errorCode>'
            f'<errorDescription>{desc}</errorDescription>'
            '</UPnPError></detail></s:Fault></s:Body></s:Envelope>')


class BuildEnvelope(unittest.TestCase):
    def test_enable_carries_the_boolean(self):
        body = fr.envelope("SetForwardingEntryEnable", CONF, enable=True)
        self.assertIn("<NewEnable>1</NewEnable>", body)
        self.assertIn("<NewDestIPAddress>198.51.100.7</NewDestIPAddress>", body)

    def test_disable_carries_zero_not_false(self):
        body = fr.envelope("SetForwardingEntryEnable", CONF, enable=False)
        self.assertIn("<NewEnable>0</NewEnable>", body)

    def test_state_query_sends_no_enable(self):
        body = fr.envelope("GetSpecificForwardingEntry", CONF)
        self.assertNotIn("NewEnable", body)

    def test_the_action_is_in_the_soapaction_header(self):
        self.assertTrue(fr.soap_action("GetSpecificForwardingEntry").endswith(
            "Layer3Forwarding:1#GetSpecificForwardingEntry"))

    def test_parse_reads_the_enable_flag(self):
        reply = "<s:Envelope><s:Body><u:X><NewEnable>1</NewEnable></u:X></s:Body></s:Envelope>"
        self.assertEqual(fr.parse_enable(reply), "1")

    def test_parse_returns_zero_when_the_entry_is_gone(self):
        """713/714 heisst: die Route steht nicht in der Box. Dann ist sie auch
        nicht in Kraft, und genau das soll der Schalter zeigen."""
        self.assertEqual(
            fr.parse_enable(_fault("713", "SpecifiedArrayIndexInvalid")), "0")
        self.assertEqual(
            fr.parse_enable(_fault("714", "NoSuchEntryInArray")), "0")

    def test_any_other_fault_is_unknown_not_off(self):
        """Der teure Fehler waere, einen Auth- oder Argumentfehler als "aus" zu
        melden: der Schalter zeigte dann "Wechselrichter in der Cloud", waehrend
        in Wahrheit niemand weiss, was die Box tut."""
        for code, desc in (("606", "Action not authorized"),
                           ("402", "Invalid Args"),
                           ("501", "Action Failed")):
            with self.assertRaises(SystemExit) as caught:
                fr.parse_enable(_fault(code, desc))
            self.assertIn(code, str(caught.exception))
            self.assertIn(desc, str(caught.exception))

    def test_a_fault_carries_its_reason_into_the_message(self):
        """Ohne den Grund im Text ist die Meldung im HA-Log wertlos."""
        self.assertEqual(
            fr.fault_reason(_fault("606", "Action not authorized")),
            "606 Action not authorized")
        self.assertEqual(fr.fault_reason("<NewEnable>1</NewEnable>"), "")

    def test_a_truncated_reply_yields_empty_not_garbage(self):
        """Fehlt der Schliess-Tag, gab find() -1 zurueck und das Slice
        schnitt still das letzte Zeichen ab."""
        self.assertEqual(fr.field("<NewEnable>1", "NewEnable"), "")


class FaultHandling(unittest.TestCase):
    """The fault path is the one a user triggers by accident: if the four
    identifying fields do not match the real route byte for byte, the box answers
    with a fault. Unhandled, HTTPError propagates and the switch shows `unknown`
    rather than `off`."""

    def test_a_500_fault_is_read_as_a_body_not_raised(self):
        import io
        import urllib.error
        import urllib.request

        fault = _fault("713", "SpecifiedArrayIndexInvalid").encode()

        class Opener:
            def open(self, request, timeout=None):
                raise urllib.error.HTTPError(
                    request.full_url, 500, "Internal Server Error", {},
                    io.BytesIO(fault))

        original = urllib.request.build_opener
        urllib.request.build_opener = lambda *a, **k: Opener()
        try:
            reply = fr.call("GetSpecificForwardingEntry", CONF)
        finally:
            urllib.request.build_opener = original
        self.assertEqual(fr.parse_enable(reply), "0")


class ConfigLoading(unittest.TestCase):
    """A dry run has to work before the config exists - otherwise the one command
    that is safe to try first is the one you cannot run yet."""

    def setUp(self):
        self.original = fr.CONFIG

    def tearDown(self):
        fr.CONFIG = self.original

    def test_dry_run_falls_back_to_the_example(self):
        fr.CONFIG = self.original.with_name("does-not-exist.json")
        self.assertEqual(fr.load_config(dry_run=True)["password"], "CHANGE ME")

    def test_a_real_call_without_a_config_refuses(self):
        fr.CONFIG = self.original.with_name("does-not-exist.json")
        with self.assertRaises(SystemExit):
            fr.load_config(dry_run=False)

    def test_a_real_call_with_the_template_password_refuses(self):
        import json as _json
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            _json.dump(dict(CONF, password="CHANGE ME"), handle)
        fr.CONFIG = pathlib.Path(handle.name)
        with self.assertRaises(SystemExit):
            fr.load_config(dry_run=False)


if __name__ == "__main__":
    unittest.main()
