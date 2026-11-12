#!/usr/bin/env python3
"""Offline renewal-probe checks. No account, QR or network required."""
import hashlib
import json
import unittest

from test_eink_login import Opener
from verify_eink_login import ProbeError
from verify_eink_renewal import RenewalProbe, shelf_contract


def credentials():
    return dict(vid="123", accessToken="private-old-access", refreshToken="private-old-refresh",
                deviceId="eink334691225" + "1" * 19)


class RenewalTests(unittest.TestCase):
    def test_refresh_payload_signature_and_readback(self):
        opener = Opener([dict(vid=123, accessToken="private-new-access", refreshToken="private-new-refresh"),
                         dict(books=[dict(bookId="book", title="Private title")], archive=[])])
        old = credentials()
        probe = RenewalProbe(opener)
        renewed, shelf = probe.renew(old)
        self.assertEqual(len(opener.requests), 2)
        post, get = opener.requests
        body = json.loads(post.data)
        self.assertEqual(post.full_url, "https://i.weread.qq.com/login")
        self.assertEqual(body["deviceId"], old["deviceId"])
        self.assertEqual(body["refreshToken"], old["refreshToken"])
        self.assertEqual([body[key] for key in ("inBackground", "kickType", "refCgi")], [0, 1, ""])
        self.assertNotIn("code", body)
        self.assertNotIn("installId", body)
        signature = hashlib.sha256(f"{body['timestamp']}{old['deviceId']}{body['random']}".encode()).hexdigest()
        self.assertEqual(body["signature"], signature)
        self.assertIsNone(post.get_header("Accesstoken"))
        self.assertIsNone(post.get_header("Cookie"))
        self.assertEqual(get.get_header("Accesstoken"), renewed["accessToken"])
        self.assertEqual(old, credentials())
        self.assertEqual(len(shelf["books"]), 1)
        report = json.dumps(probe.report)
        for secret in (f'"{old["vid"]}"', *(value for key, value in old.items() if key != "vid"),
                       *(value for key, value in renewed.items() if key != "vid"), "Private title", "\"book\""):
            self.assertNotIn(secret, report)
        self.assertTrue(probe.report["renewal_verified"])
        self.assertEqual(probe.report["renewal_attempts"], 1)
        self.assertEqual(probe.report["data_writes_attempted"], 0)

    def test_rotation_uses_new_refresh_token_on_next_call(self):
        opener = Opener([dict(vid=123, accessToken="access-1", refreshToken="refresh-1"), dict(books=[]),
                         dict(vid=123, accessToken="access-2", refreshToken="refresh-2"), dict(books=[])])
        probe = RenewalProbe(opener)
        next_credentials, _shelf = probe.renew(credentials())
        final, _shelf = probe.renew(next_credentials)
        self.assertEqual(json.loads(opener.requests[2].data)["refreshToken"], "refresh-1")
        self.assertEqual(final["deviceId"], credentials()["deviceId"])
        self.assertEqual(probe.report["renewal_attempts"], 2)

    def test_unknown_receipt_never_retries_refresh(self):
        opener = Opener([TimeoutError()])
        probe = RenewalProbe(opener)
        with self.assertRaises(ProbeError):
            probe.renew(credentials())
        self.assertEqual(len(opener.requests), 1)
        self.assertNotIn("renewal_verified", probe.report)

    def test_wrong_owner_or_missing_fields_never_reads_shelf(self):
        for response in (dict(vid=456, accessToken="a", refreshToken="b"),
                         dict(accessToken="a", refreshToken="b"), dict(vid=123, refreshToken="b"),
                         dict(vid=123, accessToken="a", refreshToken=""),
                         dict(vid=123, accessToken="private\n", refreshToken="b")):
            opener = Opener([response])
            with self.assertRaises(ProbeError):
                RenewalProbe(opener).renew(credentials())
            self.assertEqual(len(opener.requests), 1)

    def test_omitted_refresh_token_is_retained_and_reusable(self):
        opener = Opener([dict(vid=123, accessToken="new-access-1"), dict(books=[]),
                         dict(vid=123, accessToken="new-access-2"), dict(books=[])])
        probe = RenewalProbe(opener)
        first, _shelf = probe.renew(credentials())
        second, _shelf = probe.renew(first)
        self.assertEqual(second["refreshToken"], credentials()["refreshToken"])
        self.assertEqual(json.loads(opener.requests[2].data)["refreshToken"], credentials()["refreshToken"])
        self.assertFalse(probe.report["refresh_token_returned"])
        self.assertEqual(len(probe.report["verified_renewals"]), 2)

    def test_invalid_private_credentials_send_nothing(self):
        for key, value in (("vid", "0"), ("vid", True), ("accessToken", ""), ("refreshToken", "a\n"),
                           ("refreshToken", "\ud800"), ("deviceId", "short")):
            value_credentials = credentials()
            value_credentials[key] = value
            opener = Opener([])
            with self.assertRaises(ProbeError):
                RenewalProbe(opener).renew(value_credentials)
            self.assertEqual(opener.requests, [])

    def test_shelf_contract_counts_only(self):
        shelf = dict(books=[dict(bookId="private-book", title="Private title", version=700, readUpdateTime=1)],
                     archive=[dict(bookIds=["private-book"])])
        contract = shelf_contract(shelf)
        self.assertTrue(contract["display_contract_valid"])
        self.assertNotIn("Private", json.dumps(contract))
        self.assertNotIn("private-book", json.dumps(contract))
        self.assertEqual(contract["fields_present"]["version"], 1)
        shelf["books"].append(shelf["books"][0])
        self.assertFalse(shelf_contract(shelf)["display_contract_valid"])
        shelf["books"] = [dict(bookId=10 ** 1000, title="x")]
        self.assertFalse(shelf_contract(shelf)["display_contract_valid"])
        shelf["archive"][0]["bookIds"] = "invalid"
        self.assertEqual(shelf_contract(shelf)["invalid_archives"], 1)

    def test_unknown_or_mutating_routes_are_blocked(self):
        opener = Opener([])
        probe = RenewalProbe(opener)
        for url, body in (("https://i.weread.qq.com/shelf/add", {}),
                          ("https://i.weread.qq.com/shelf/sync", {}),
                          ("https://i.weread.qq.com/book/read", {}),
                          ("https://example.invalid/login", {}),
                          ("http://i.weread.qq.com/login", {}),
                          ("https://secret:private@i.weread.qq.com/login", {})):
            with self.assertRaises(ProbeError):
                probe.request("blocked", url, body=body)
        self.assertEqual(opener.requests, [])


if __name__ == "__main__":
    unittest.main()
