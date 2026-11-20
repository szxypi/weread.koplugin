#!/usr/bin/env python3
"""Offline tests for native authorization prototype; no QR/account/network."""
import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from verify_eink_login import NativeProbe, NoRedirect, ProbeError, ProbeTimeout


class Response:
    status = 200

    def __init__(self, data):
        self.raw = json.dumps(data).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, size):
        return self.raw[:size]


class Opener:
    def __init__(self, responses):
        self.responses, self.requests = list(responses), []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return Response(response)


class NativeLoginTests(unittest.TestCase):
    def test_qr_metadata_never_contains_ticket_or_uuid(self):
        opener = Opener([dict(signature="sensitive-signature", timeStamp=1),
                         dict(errcode=0, uuid="sensitive-uuid", qrcode="sensitive-image")])
        probe = NativeProbe(opener)
        self.assertEqual(probe.create_qr(), "sensitive-uuid")
        report = json.dumps(probe.report)
        for secret in ("sensitive-signature", "sensitive-uuid", "sensitive-image"):
            self.assertNotIn(secret, report)
        self.assertEqual(len(opener.requests), 2)
        self.assertTrue(all(req.get_header("Cookie") is None for req in opener.requests))
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.invalid"))

    def test_owner_confirmation_and_read_only_shelf_validation(self):
        opener = Opener([dict(vid=123, accessToken="sensitive-access", refreshToken="sensitive-refresh"), dict(books=[])])
        probe = NativeProbe(opener)
        probe.finish("sensitive-code")
        self.assertEqual([req.method if hasattr(req, "method") else req.get_method() for req in opener.requests], ["POST", "GET"])
        body = json.loads(opener.requests[0].data)
        self.assertEqual(body["code"], "sensitive-code")
        self.assertRegex(body["deviceId"], r"^eink334691225\d{19}$")
        self.assertRegex(body["installId"], r"^eink31\d{26}$")
        self.assertEqual(opener.requests[1].get_header("Accesstoken"), "sensitive-access")
        self.assertEqual(probe.report["shelf_book_count"], 0)
        report = json.dumps(probe.report)
        for secret in ("sensitive-access", "sensitive-refresh", "sensitive-code", body["deviceId"]):
            self.assertNotIn(secret, report)

    def test_incomplete_credentials_do_not_read_shelf(self):
        for response in (dict(vid="123", accessToken="access"), dict(vid="bad", accessToken="access", refreshToken="refresh")):
            opener = Opener([response])
            with self.assertRaises(ProbeError):
                NativeProbe(opener).finish("code")
            self.assertEqual(len(opener.requests), 1)
        with self.assertRaises(ProbeError):
            NativeProbe(Opener([dict(vid=123, accessToken="access", refreshToken="refresh"), {}])).finish("code")

    def test_network_and_api_errors_are_sanitized(self):
        error = HTTPError("https://example.invalid/?uuid=secret-uuid", 403, "secret-response", {}, io.BytesIO(b"secret-body"))
        probe = NativeProbe(Opener([error]))
        with self.assertRaises(ProbeError) as caught:
            probe.request("qr_poll", "https://example.invalid")
        self.assertNotIn("secret-", str(caught.exception) + json.dumps(probe.report))
        probe = NativeProbe(Opener([dict(errcode=-10102, errmsg="secret-message")]))
        with self.assertRaises(ProbeError):
            probe.request("qr_poll", "https://example.invalid")
        self.assertEqual(probe.report["stages"][0]["error_code"], -10102)
        self.assertNotIn("secret-message", json.dumps(probe.report))

    def test_poll_timeout_retries_but_decline_does_not(self):
        probe = NativeProbe(Opener([TimeoutError(), dict(wx_errcode=405, wx_code="confirmed-code")]))
        self.assertEqual(probe.wait_for_code("uuid", seconds=2), "confirmed-code")
        for response in (dict(wx_errcode=402), dict(wx_errcode=403), dict(wx_errcode=405)):
            with self.assertRaises(ProbeError):
                NativeProbe(Opener([response])).wait_for_code("uuid", seconds=2)
        with self.assertRaises(ProbeError):
            NativeProbe(Opener([])).wait_for_code("uuid", seconds=0)
        with self.assertRaises(ProbeTimeout):
            NativeProbe(Opener([TimeoutError()])).request("qr_poll", "https://example.invalid")


if __name__ == "__main__":
    unittest.main()
