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
from secure_weread_session import StoreError


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
        for private in (f'"{credentials()["vid"]}"', *(value for key, value in credentials().items() if key != "vid"),
                        "private-book", "existing", "Private book title"):
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
        self.assertTrue(rejection.closed)

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
        for arguments in (["--apply"], ["--roundtrip"],
                          ["--interactive", "--roundtrip", "--operation", "remove", "--book-id", "private-book"]):
            with patch("sys.argv", ["verify_eink_shelf_write.py", *arguments]), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as invalid:
                    main()
            self.assertNotEqual(invalid.exception.code, 0)

    def test_confirmed_roundtrip_two_posts_and_original_members_restored(self):
        before, after = shelf("existing"), shelf("existing", "private-book")
        probe, opener = self.probe([before, before, dict(succ=1), after,
                                    after, after, dict(succ=1), before])
        plan = probe.prepare(credentials(), "add", "private-book")
        probe.apply_roundtrip(credentials(), plan, confirmed=True)
        self.assertTrue(probe.report["roundtrip_verified"])
        self.assertEqual(probe.report["data_writes_attempted"], 2)
        self.assertEqual([step["operation"] for step in probe.report["operations"]], ["add", "remove"])
        posts = [req for req in opener.requests if req.get_method() == "POST"]
        self.assertEqual([req.full_url.rsplit("/", 1)[1] for req in posts], ["add", "delete"])
        self.assertTrue(all(json.loads(req.data) == dict(bookIds=["private-book"]) for req in posts))
        for private in ("private-book", "existing", "Private book title", credentials()["refreshToken"]):
            self.assertNotIn(private, json.dumps(probe.report))

    def test_roundtrip_existing_or_concurrently_added_target_is_never_removed(self):
        for responses in ([shelf("private-book")], [shelf(), shelf("private-book")]):
            probe, opener = self.probe(responses)
            plan = probe.prepare(credentials(), "add", "private-book")
            probe.apply_roundtrip(credentials(), plan, confirmed=True)
            self.assertEqual(probe.report["result"], "NOOP")
            self.assertFalse(probe.report["roundtrip_verified"])
            self.assertTrue(all(req.get_method() == "GET" for req in opener.requests))

    def test_roundtrip_unknown_add_receipt_never_dispatches_remove(self):
        probe, opener = self.probe([shelf(), shelf(), TimeoutError(), shelf("private-book")])
        plan = probe.prepare(credentials(), "add", "private-book")
        probe.apply_roundtrip(credentials(), plan, confirmed=True)
        self.assertEqual(probe.report["result"], "PARTIAL")
        self.assertFalse(probe.report["roundtrip_verified"])
        self.assertEqual(sum(req.get_method() == "POST" for req in opener.requests), 1)

    def test_roundtrip_changed_members_or_remove_receipt_cannot_claim_restoration(self):
        after = shelf("private-book")
        for tail in ([shelf("private-book", "other")], [after, after, TimeoutError(), shelf()]):
            probe, opener = self.probe([shelf(), shelf(), dict(succ=1), after, *tail])
            plan = probe.prepare(credentials(), "add", "private-book")
            if len(tail) == 1:
                with self.assertRaises(ProbeError):
                    probe.apply_roundtrip(credentials(), plan, confirmed=True)
                self.assertEqual(sum(req.get_method() == "POST" for req in opener.requests), 1)
            else:
                probe.apply_roundtrip(credentials(), plan, confirmed=True)
                self.assertEqual(probe.report["result"], "PARTIAL")
                self.assertEqual(sum(req.get_method() == "POST" for req in opener.requests), 2)
            self.assertFalse(probe.report["roundtrip_verified"])

    def test_roundtrip_requires_exact_add_plan_and_confirmation(self):
        probe, opener = self.probe([shelf(), shelf("private-book")])
        plan = probe.prepare(credentials(), "add", "private-book")
        with self.assertRaises(ProbeError):
            probe.apply_roundtrip(credentials(), plan)
        removal = probe.prepare(credentials(), "remove", "private-book")
        for candidate in (plan, removal):
            with self.assertRaises(ProbeError):
                probe.apply_roundtrip(credentials(), candidate, confirmed=True)
        self.assertEqual(probe.report["data_writes_attempted"], 0)
        self.assertTrue(all(req.get_method() == "GET" for req in opener.requests))

    def test_saved_session_preview_has_one_read_no_qr_no_write_and_keeps_entries(self):
        probe,opener=self.probe([shelf('existing')])
        private_credentials=credentials()
        with patch('sys.argv',['verify_eink_shelf_write.py','--saved-session','--operation','add','--book-id','private-book','--roundtrip']),\
                patch('verify_eink_shelf_write.SessionStore') as web,patch('verify_eink_shelf_write.NativeSessionStore') as native,\
                patch('verify_eink_shelf_write.ShelfWriteProbe',return_value=probe),redirect_stdout(io.StringIO()) as out,self.assertRaises(SystemExit) as exited:
            web.return_value.load.return_value=dict(vid=private_credentials['vid'])
            native.return_value.load.return_value=private_credentials
            main()
        self.assertEqual(exited.exception.code,0)
        self.assertEqual([req.get_method() for req in opener.requests],['GET'])
        self.assertEqual(json.loads(out.getvalue())['result'],'PREVIEW_ONLY')
        self.assertNotIn('private-book',out.getvalue());self.assertNotIn('Private book title',out.getvalue())
        native.return_value.delete.assert_not_called();web.return_value.delete.assert_not_called()
        self.assertEqual(private_credentials,{})

    def test_saved_apply_requires_the_exact_target_before_loading_any_store(self):
        for args in (['--saved-session','--apply'],['--saved-session','--operation','add','--book-id','private-book','--apply'],
                     ['--saved-session','--operation','add','--book-id','private-book','--apply','--confirm-book-id','other-book']):
            with patch('sys.argv',['verify_eink_shelf_write.py',*args]),patch('verify_eink_shelf_write.NativeSessionStore') as native,\
                    redirect_stderr(io.StringIO()),self.assertRaises(SystemExit) as exited:
                main()
            self.assertNotEqual(exited.exception.code,0);native.assert_not_called()

    def test_saved_owner_mismatch_never_sends_or_deletes(self):
        with patch('sys.argv',['verify_eink_shelf_write.py','--saved-session','--operation','add','--book-id','private-book']),\
                patch('verify_eink_shelf_write.SessionStore') as web,patch('verify_eink_shelf_write.NativeSessionStore') as native,\
                patch.object(ShelfWriteProbe,'request') as request,redirect_stdout(io.StringIO()) as out,self.assertRaises(SystemExit) as exited:
            web.return_value.load.return_value=dict(vid='123')
            native.return_value.load.side_effect=StoreError('native_owner_mismatch')
            main()
        self.assertEqual(exited.exception.code,1);request.assert_not_called();native.return_value.delete.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['data_writes_attempted'],0)


if __name__ == "__main__":
    unittest.main()
