"""Synthetic-only CB_ native acceptance orchestration boundaries."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_cb_reading import FIRST, point, ready, responses
from test_owner_reading import envelope, frame
import verify_cb_native_reading as cb


class CbNativeReadingTests(unittest.TestCase):
    def test_default_is_offline_and_incomplete_options_do_not_open_stores(self):
        with patch.object(cb, 'SessionStore') as store, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cb.main([]), 0)
        store.assert_not_called(); self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')
        for args in (['--saved-session'], ['--book-index', '1'], ['--lua-command', 'synthetic'],
                     ['--saved-session', '--lua-command', 'synthetic']):
            with patch.object(cb, 'SessionStore') as store, redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): cb.main(args)
            store.assert_not_called()

    def invoke(self, *, result=None, observed=None, accepted=None, rotation=False):
        web, _opener = ready([dict(books=[dict(bookId=FIRST)])] + responses())
        after, after_opener = ready([point() if observed is None else observed])
        value = envelope() if accepted is None else accepted
        for stage in value['report']['stages']: stage['source_match_reason'] = 'none'
        if accepted is None:
            for stage in value['report']['stages']: stage['shelf_books'] = 1
        child = SimpleNamespace(returncode=0, stdout=frame(value), stderr=b'private child diagnostics') if result is None else result
        saved = dict(vid='900000', cookies=dict(wr_vid='900000', wr_skey='synthetic-private-cookie'))
        fresh = dict(vid=saved['vid'], cookies=saved['cookies'].copy())
        if rotation: fresh['cookies']['wr_skey'] = 'rotated-private-cookie'
        saved_snapshots = []
        def save(_store, snapshot, probe):
            saved_snapshots.append(dict(vid=snapshot['vid'], cookies=snapshot['cookies'].copy()))
            if rotation and len(saved_snapshots) == 1:
                probe.set_cookie('wr_skey', fresh['cookies']['wr_skey'])
                return True
            return False
        with patch.object(cb, 'SessionStore') as store, patch.object(cb, 'CbReadingProbe', side_effect=[web, after]), \
             patch.object(web, 'verify_account'), patch.object(after, 'verify_account'), \
             patch.object(cb, 'save_refreshed_web_session', side_effect=save), \
             patch.object(cb.subprocess, 'run', **({'side_effect': child} if isinstance(child, Exception) else {'return_value': child})) as run, \
             redirect_stdout(io.StringIO()) as out:
            store.return_value.load.side_effect = [saved, fresh]
            code = cb.main(['--saved-session', '--book-index', '1', '--lua-command', 'synthetic'])
        self.assertEqual(saved, {}); self.assertEqual(web.samples, []); self.assertEqual(after.samples, [])
        self.assertEqual(fresh, {})
        if rotation and len(saved_snapshots) > 1: self.assertEqual(saved_snapshots[1]['cookies']['wr_skey'], 'rotated-private-cookie')
        store.return_value.delete.assert_not_called()
        for private in (FIRST, 'synthetic-private-cookie', 'synthetic-cb-session', '900000', 'private child diagnostics'):
            self.assertNotIn(private, out.getvalue())
        return code, json.loads(out.getvalue()), run, after_opener

    def test_success_requires_native_offline_cleanup_and_independent_position(self):
        code, report, run, after = self.invoke()
        self.assertEqual(code, 0); self.assertEqual(report['result'], 'CB_NATIVE_READING_VERIFIED')
        self.assertTrue(report['cloud_position_unchanged']); self.assertEqual(len(after.calls), 1)
        self.assertEqual(report['account_data_posts'], 0); self.assertEqual(report['authentication_posts'], 0)
        payload = json.loads(run.call_args.kwargs['input'])
        self.assertTrue(payload['cb_reading']); self.assertEqual(payload['book_id'], FIRST)
        for key in ('source', 'baseline', 'shards', 'context', 'annotations', 'progress_roundtrip', 'source_upload_preview'):
            self.assertNotIn(key, payload)

    def test_changed_cloud_position_is_not_treated_as_success_or_restored(self):
        code, report, _run, after = self.invoke(observed=dict(book=dict(point()['book'], chapterOffset=11)))
        self.assertEqual(code, 1); self.assertFalse(report['cloud_position_unchanged']); self.assertEqual(len(after.calls), 1)
        self.assertEqual(report['account_data_posts'], 0)

    def test_preflight_cookie_rotation_uses_the_verified_fresh_keychain_snapshot(self):
        code, report, run, _after = self.invoke(rotation=True)
        self.assertEqual(code, 0); self.assertTrue(report['preflight_rotation_saved'])
        self.assertEqual(json.loads(run.call_args.kwargs['input'])['cookies']['wr_skey'], 'rotated-private-cookie')

    def test_child_failure_still_checks_position_and_never_exports_diagnostics(self):
        value = envelope()
        for stage in value['report']['stages']: stage.update(shelf_books=1, source_match_reason='none')
        code, report, _run, after = self.invoke(result=SimpleNamespace(returncode=1, stdout=frame(value), stderr=b'private child diagnostics'))
        self.assertEqual(code, 1); self.assertTrue(report['cloud_position_unchanged']); self.assertEqual(len(after.calls), 1)

    def test_foreign_cookie_or_missing_native_proof_rejects_before_independent_requests(self):
        for kind in ('owner', 'proof', 'shelf'):
            value = envelope()
            for stage in value['report']['stages']: stage['shelf_books'] = 1
            if kind == 'owner': value['cookies']['wr_vid'] = '900099'
            elif kind == 'proof': value['report']['stages'][0]['source_receipt_verified'] = False
            else: value['report']['stages'][0]['shelf_books'] = value['report']['stages'][1]['shelf_books'] = 2
            code, _report, _run, after = self.invoke(accepted=value)
            self.assertEqual(code, 1); self.assertEqual(after.calls, [])

    def test_child_timeout_is_terminal_and_does_not_replay_or_delete_credentials(self):
        code, report, run, after = self.invoke(result=subprocess.TimeoutExpired('synthetic', 360))
        self.assertEqual(code, 1); self.assertEqual(report['result'], 'UNVERIFIED')
        self.assertEqual(run.call_count, 1); self.assertEqual(after.calls, [])

    def test_runner_cb_mode_cannot_combine_with_any_write_or_annotation_addon(self):
        from run_owner_reading_probe import main
        for addon in ('--annotations', '--annotation-recovery', '--progress-preview', '--progress-roundtrip', '--source-upload-preview'):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main(['--koreader', '/synthetic', '--candidate', '/synthetic.zip', '--cb-reading', addon])

    def test_cb_diagnostics_are_explicit_and_cannot_export_private_text(self):
        from verify_owner_reading import validate_stage
        value = envelope()['report']['stages'][0]
        value['source_match_reason'] = 'none'
        self.assertEqual(validate_stage(value, 'live', cb_reading=True), value)
        with self.assertRaises(ValueError): validate_stage(value, 'live')
        for reason in ('private chapter text', [], True):
            value['source_match_reason'] = reason
            with self.assertRaises(ValueError): validate_stage(value, 'live', cb_reading=True)


if __name__ == '__main__':
    unittest.main()
