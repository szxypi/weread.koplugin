#!/usr/bin/env python3
"""Offline preflight tests: synthetic HTTP, real read-only SQLite, no account."""
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from urllib.error import HTTPError

from test_eink_login import Opener
from verify_eink_readtime import BASE, ReadtimeProbe, ProbeError, ledger_preview, select_book, validate_position


class ReadtimeProbeTests(unittest.TestCase):
    def test_public_probe_exposes_auth_gate_without_credentials_or_writes(self):
        denied = HTTPError("https://example.invalid/?private-url", 401, "private-response", {}, io.BytesIO(b"private-body"))
        opener = Opener([denied, dict(feature=dict(guest_token="private-guest-token"), synckey=1)])
        probe = ReadtimeProbe(opener)
        report = probe.preflight()
        self.assertEqual(report["result"], "PARTIAL")
        self.assertFalse(report["read_only_preflight_complete"])
        self.assertIn("owner_scan_and_native_authorization", report["pending"])
        self.assertEqual(report["stages"][0]["status"], 401)
        self.assertEqual(report["signature_token_source"], "remote")
        self.assertTrue(all(req.get_method() == "GET" and req.get_header("Accesstoken") is None for req in opener.requests))
        self.assertNotIn("private-", json.dumps(report))

    def test_authenticated_preflight_checks_position_but_never_sends_time(self):
        opener = Opener([dict(token="private-config-token"), dict(feature={}),
                         dict(book=dict(bookId="private-book", chapterUid=33, chapterOffset=424242, readingTime=600))])
        probe = ReadtimeProbe(opener)
        result = probe.preflight(dict(vid="123", accessToken="private-access"), dict(books=[dict(bookId="private-book")]))
        self.assertTrue(result["read_only_preflight_complete"])
        self.assertTrue(result["reading_seconds_present"])
        self.assertEqual(result["result"], "PARTIAL")
        self.assertIn("time_only_payload_and_write_readback", result["pending"])
        self.assertIn("web_offline_overlap_coordination", result["pending"])
        self.assertEqual(result["signature_token_source"], "client_default")
        self.assertTrue(all(req.get_method() == "GET" for req in opener.requests))
        self.assertEqual(opener.requests[-1].get_header("Accesstoken"), "private-access")
        self.assertNotIn("private-", json.dumps(result))
        self.assertNotIn("424242", json.dumps(result))
        self.assertEqual(result["time_uploads_attempted"], 0)

    def test_transport_rejects_data_writes_but_allows_authorization(self):
        opener = Opener([dict(vid=123, accessToken="private-access", refreshToken="private-refresh"), dict(books=[])])
        probe = ReadtimeProbe(opener)
        with self.assertRaises(ProbeError):
            probe.request("forbidden_upload", BASE + "/book/batchUploadProgress", body={})
        self.assertEqual(opener.requests, [])
        credentials, shelf = probe.finish("private-code")
        self.assertEqual(credentials["accessToken"], "private-access")
        self.assertRegex(credentials["deviceId"], r"^eink334691225\d{19}$")
        self.assertEqual(shelf["books"], [])
        self.assertNotIn("private-", json.dumps(probe.report))
        self.assertEqual([req.get_method() for req in opener.requests], ["POST", "GET"])

    def test_missing_contracts_never_claim_preflight_completion(self):
        probe = ReadtimeProbe(Opener([{}, dict(feature={})]))
        report = probe.preflight(dict(vid="123", accessToken="private-access"), dict(books=[]))
        self.assertEqual(report["result"], "UNVERIFIED")
        self.assertFalse(report["read_only_preflight_complete"])
        self.assertIn("config_contract_validation", report["pending"])
        with self.assertRaises(ProbeError):
            ReadtimeProbe(Opener([dict(token="token"), dict(feature=dict(guest_token={}))])).preflight()

    def test_book_selection_is_shelf_bound_and_excludes_articles(self):
        shelf = dict(books=[dict(bookId=None), dict(bookId=True), dict(bookId="MP_WXS_article"),
                            dict(bookInfo=dict(book=dict(bookId="book-a"))), dict(bookId="book-b")])
        self.assertEqual(select_book(shelf), "book-a")
        self.assertEqual(select_book(shelf, "book-b"), "book-b")
        for requested in ("other", "MP_WXS_article"):
            with self.assertRaises(ProbeError):
                select_book(shelf, requested)

    def test_position_identity_and_types_are_validated(self):
        self.assertEqual(validate_position(dict(data=dict(result=dict(chapterUid=0, chapterOffset=0))), "book")["chapter_offset"], 0)
        for value in (dict(bookId="other", chapterUid=1, chapterOffset=1),
                      dict(chapterUid=True, chapterOffset=1), dict(chapterUid=1, chapterOffset=True),
                      dict(chapterUid=1, chapterOffset=-1), dict(chapterUid=1), {}):
            with self.assertRaises(ProbeError):
                validate_position(value, "book")

    def fixture_ledger(self, root):
        key = hashlib.sha256(b"weread-library:123").hexdigest()[:20]
        path = Path(root) / f"offline-time-{key}.db"
        with sqlite3.connect(path) as db:
            db.executescript("""CREATE TABLE windows(id INTEGER,book_id TEXT,time_zone TEXT,book_version INTEGER);
                CREATE TABLE segments(id INTEGER,window_id INTEGER,start_time INTEGER,duration INTEGER,state TEXT);
                INSERT INTO windows VALUES(1,'book','+08:00',7),(2,'book','+08:00',8);
                INSERT INTO segments VALUES(1,1,100,30,'pending'),(2,1,130,20,'pending'),
                    (3,2,150,10,'pending'),(4,1,50,5,'unknown');""")
        return path

    def test_ledger_preview_is_read_only_account_bound_and_version_bounded(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.fixture_ledger(root)
            before = hashlib.sha256(path.read_bytes()).digest()
            report = ledger_preview(path, "123", "book", 200)
            self.assertEqual(report, dict(rows=2, seconds=50, nonzero_book_version=True, has_more=True, uncertain_seconds=5))
            self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)
            with self.assertRaises(ProbeError):
                ledger_preview(path, "other-account", "book", 200)
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM segments WHERE state='pending'").fetchone()[0], 3)

    def test_overlapping_future_or_corrupt_rows_are_not_proposed(self):
        for statement, now in (("UPDATE segments SET start_time=120 WHERE id=2", 200), ("SELECT 1", 110),
                               ("UPDATE segments SET duration=61 WHERE id=1", 200),
                               ("UPDATE windows SET time_zone='bad-zone'", 200)):
            with self.subTest(statement=statement), tempfile.TemporaryDirectory() as root:
                path = self.fixture_ledger(root)
                with sqlite3.connect(path) as db:
                    db.execute(statement)
                with self.assertRaises(ProbeError):
                    ledger_preview(path, "123", "book", now)

    def test_cli_requires_authorization_for_ledger_and_has_no_upload_switch(self):
        script = str(Path(__file__).with_name("verify_eink_readtime.py"))
        result = subprocess.run([sys.executable, script, "--ledger", "/private-path", "--book-id", "private-book"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires --interactive", result.stderr)
        self.assertNotIn("private-", result.stderr)
        help_result = subprocess.run([sys.executable, script, "--help"], capture_output=True, text=True, check=True)
        self.assertNotIn("--upload", help_result.stdout)


if __name__ == "__main__":
    unittest.main()
