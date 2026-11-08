#!/usr/bin/env python3
"""Offline state-machine checks; never sends an account or network request."""
import io
import json
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
from urllib.error import HTTPError

from test_eink_login import Opener
from test_eink_renewal import credentials
from verify_eink_login import ProbeError
from verify_eink_shelf_write import ShelfWriteProbe, main


def shelf(*ids, finished=0):
    return dict(books=[dict(bookId=identity, title="Private book title", finishReading=finished,
                           finished=finished) for identity in ids])


class ShelfWriteTests(unittest.TestCase):
    def probe(self, responses):
        opener = Opener(responses)
        return ShelfWriteProbe(opener, sleep=lambda _seconds: None), opener

    def test_add_single_post_with_preflight_and_independent_readback(self):
        probe, opener = self.probe([shelf("existing"), shelf("existing"), dict(succ=1), shelf("existing", "private-book")])
        plan = probe.prepare(credentials(), "add", "private-book")
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(probe.report["result"], "PREVIEW_ONLY")
        probe.apply(credentials(), plan, confirmed=True)
        self.assertEqual([req.get_method() for req in opener.requests], ["GET", "GET", "POST", "GET"])
        self.assertEqual(json.loads(opener.requests[2].data), dict(bookIds=["private-book"]))
        self.assertTrue(opener.requests[2].full_url.endswith("/shelf/add"))
        self.assertEqual(probe.report["result"], "PASS")
        self.assertEqual(probe.report["data_writes_attempted"], 1)
        report = json.dumps(probe.report)
        for private in (*credentials().values(), "private-book", "existing", "Private book title"):
            self.assertNotIn(private, report)
        before = len(opener.requests)
        with self.assertRaises(ProbeError):
            probe.apply(credentials(), plan, confirmed=True)
        self.assertEqual(len(opener.requests), before, "possibly consumed plan was replayed")

    def test_remove_and_status_bodies(self):
        for operation, before_flag, after_flag in (("remove", 0, 0), ("finish", 0, 1), ("unfinish", 1, 0)):
            before = shelf("private-book", finished=before_flag)
            after = shelf() if operation == "remove" else shelf("private-book", finished=after_flag)
            probe, opener = self.probe([before, before, dict(success=True), after])
            plan = probe.prepare(credentials(), operation, "private-book")
            probe.apply(credentials(), plan, confirmed=True)
            body = json.loads(opener.requests[2].data)
            if operation == "remove":
                self.assertTrue(opener.requests[2].full_url.endswith("/shelf/delete"))
                self.assertEqual(body, dict(bookIds=["private-book"]))
            else:
                self.assertEqual(body, dict(bookId="private-book", auto=0, finishInfo=0,
                                            isCancel=0 if operation == "finish" else 1, status=4))
            self.assertTrue(probe.report["write_verified"])

    def test_unconfirmed_or_wrong_owner_cannot_dispatch(self):
        probe, opener = self.probe([shelf()])
        plan = probe.prepare(credentials(), "add", "private-book")
        for owner, confirmation in ((credentials(), False), (dict(credentials(), vid="456"), True)):
            with self.assertRaises(ProbeError):
                probe.apply(owner, plan, confirmed=confirmation)
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(probe.report["data_writes_attempted"], 0)
        with self.assertRaises(ProbeError):
            probe.request("blocked", "https://i.weread.qq.com/shelf/add", body=dict(bookIds=["private-book"]))
        self.assertEqual(len(opener.requests), 1)

    def test_changed_shelf_and_unknown_status_abort_before_post(self):
        probe, opener = self.probe([shelf("one"), shelf("one", "other")])
        plan = probe.prepare(credentials(), "add", "private-book")
        with self.assertRaises(ProbeError):
            probe.apply(credentials(), plan, confirmed=True)
        self.assertTrue(all(req.get_method() == "GET" for req in opener.requests))
        for response in (shelf(), dict(books=[dict(bookId="private-book")]),
                         dict(books=[dict(bookId="private-book", finishReading=0, finished=1)])):
            probe, opener = self.probe([response])
            with self.assertRaises(ProbeError):
                probe.prepare(credentials(), "finish", "private-book")
            self.assertEqual(probe.report["data_writes_attempted"], 0)

    def test_noop_does_not_post(self):
        probe, opener = self.probe([shelf(), shelf()])
        plan = probe.prepare(credentials(), "remove", "private-book")
        probe.apply(credentials(), plan, confirmed=True)
        self.assertEqual(probe.report["result"], "NOOP")
        self.assertTrue(all(req.get_method() == "GET" for req in opener.requests))

    def test_lost_receipt_reads_back_without_replaying_post(self):
        probe, opener = self.probe([shelf(), shelf(), TimeoutError(), shelf("private-book")])
        plan = probe.prepare(credentials(), "add", "private-book")
        probe.apply(credentials(), plan, confirmed=True)
        self.assertEqual(sum(req.get_method() == "POST" for req in opener.requests), 1)
        self.assertTrue(probe.report["desired_state_observed"])
        self.assertFalse(probe.report["write_verified"])
        self.assertEqual(probe.report["result"], "PARTIAL")

    def test_ack_without_readback_never_claims_success(self):
        probe, opener = self.probe([shelf(), shelf(), dict(succ=1), shelf(), shelf(), shelf()])
        plan = probe.prepare(credentials(), "add", "private-book")
        probe.apply(credentials(), plan, confirmed=True)
        self.assertEqual(probe.report["result"], "UNVERIFIED")
        self.assertEqual(probe.report["readback_attempts"], 3)
        self.assertEqual(sum(req.get_method() == "POST" for req in opener.requests), 1)
        probe, opener = self.probe([shelf(), shelf(), dict(succ=1), shelf("private-book", "unexpected")])
        plan = probe.prepare(credentials(), "add", "private-book")
        probe.apply(credentials(), plan, confirmed=True)
        self.assertEqual(probe.report["result"], "PARTIAL")
        self.assertTrue(probe.report["unrelated_membership_changes"])

    def test_rejected_http_receipt_is_distinct_from_a_lost_response(self):
        rejection = HTTPError("https://i.weread.qq.com/shelf/add", 403, "private-error", {}, io.BytesIO(b"private-body"))
        probe, _opener = self.probe([shelf(), shelf(), rejection, shelf(), shelf(), shelf()])
        plan = probe.prepare(credentials(), "add", "private-book")
        probe.apply(credentials(), plan, confirmed=True)
        self.assertTrue(probe.report["receipt_received"])
        self.assertFalse(probe.report["acknowledgement_recognized"])
        self.assertEqual(probe.report["result"], "UNVERIFIED")
        self.assertNotIn("private-error", json.dumps(probe.report))
        self.assertNotIn("private-body", json.dumps(probe.report))

    def test_cli_without_apply_or_owner_has_no_network(self):
        output = io.StringIO()
        with patch("sys.argv", ["verify_eink_shelf_write.py"]), patch.object(ShelfWriteProbe, "create_qr") as qr:
            with redirect_stdout(output), self.assertRaises(SystemExit) as exited:
                main()
        self.assertEqual(exited.exception.code, 0)
        self.assertFalse(qr.called)
        report = json.loads(output.getvalue())
        self.assertEqual(report["data_writes_attempted"], 0)
        self.assertEqual(report["network_requests"], 0)
        with patch("sys.argv", ["verify_eink_shelf_write.py", "--apply"]), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as invalid:
                main()
        self.assertNotEqual(invalid.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
