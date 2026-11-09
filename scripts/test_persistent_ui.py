"""Offline acceptance boundaries; no Keychain, real account or network."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch, MagicMock
import zipfile

from verify_persistent_ui import FRAME, FLAGS, decode_result, decode_stage, main, validate_stage, verified_web_snapshot
from run_persistent_ui_probe import extract_candidate, run_child


def stage(mode='live'):
    return dict(result='PASS', phase='complete', mode=mode, paged_shelf=True,
                request_counts=[1, 1] if mode=='live' else [0, 0],
                shelf_books=40, shelf_groups=3, painted_views=4,
                cover_gets=12 if mode=='live' else 0, progress_gets=12 if mode=='live' else 0,
                cover_retries=0,
                denied_kind=0,denied_reason=0,cover_redirects=0,
                cover_http_redirects=0,
                redirect_address_kind=0,
                cover_cells=12, progress_snapshots=12, known_progress=6,
                failed_line=0, progress_http_status=200 if mode=='live' else 0,
                progress_fetch_result=4 if mode=='live' else 0, progress_parse_result=1 if mode=='live' else 0,
                progress_shape=0,
                profile_files_audited=20, screenshots=0, forbidden_requests=0, **dict.fromkeys(FLAGS, True))


def result():
    return dict(result='PASS', tmpfs_profile=True, profile_removed=True, stages=[stage(), stage('reopen')],runner_error='none')


class PersistentUITests(unittest.TestCase):
    def test_offline_does_not_access_credentials_or_processes(self):
        with patch('verify_persistent_ui.SessionStore') as web, patch('verify_persistent_ui.NativeSessionStore') as native, \
                patch('verify_persistent_ui.NativeMetadataProbe') as probe, patch('verify_persistent_ui.subprocess.run') as child, \
                redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]), 0)
        for mocked in (web, native, probe, child): mocked.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_saved_session_and_command_are_paired(self):
        for args in (['--saved-session'], ['--lua-command', 'synthetic']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): main(args)

    def test_fixed_schema_rejects_private_fields(self):
        for key in ('credentials', 'title', 'book_id', 'raw'):
            value=stage(); value[key]='private'
            with self.assertRaises(ValueError): validate_stage(value, 'live')
            value=result(); value[key]='private'
            with self.assertRaises(ValueError): decode_result(FRAME+json.dumps(value).encode())

    def test_flags_types_limits_and_completion(self):
        for key in FLAGS:
            value=stage(); value[key]=False
            with self.subTest(key=key), self.assertRaises(ValueError): validate_stage(value, 'live')
        for key, bad in (('shelf_books', True), ('cover_gets', 49), ('progress_gets', -1), ('screenshots', 1),
                         ('painted_views', 0), ('phase', []), ('result', {}), ('mode', 'private'), ('paged_shelf', 1),
                         ('forbidden_requests', 1), ('shelf_books', 0), ('cover_cells', 0), ('progress_snapshots', 0)):
            value=stage(); value[key]=bad
            with self.subTest(key=key), self.assertRaises(ValueError): validate_stage(value, 'live')

    def test_offline_reopen_rejects_any_request(self):
        for key, bad in (('request_counts', [1,0]), ('cover_gets', 1), ('progress_gets', 1)):
            value=stage('reopen'); value[key]=bad
            with self.assertRaises(ValueError): validate_stage(value, 'reopen')

    def test_live_requires_two_native_gets_and_visible_data_reads(self):
        for key, bad in (('request_counts', [0,1]), ('request_counts', [True,True]),
                         ('request_counts', [1,1,1]), ('progress_gets', 0), ('cover_gets', 0), ('known_progress', 13)):
            value=stage(); value[key]=bad
            with self.assertRaises(ValueError): validate_stage(value, 'live')

    def test_small_shelf_and_unknown_progress_remain_valid(self):
        value=stage(); value.update(paged_shelf=False, painted_views=3, known_progress=0)
        self.assertEqual(validate_stage(value, 'live'), value)

    def test_frames_are_bounded_unique_and_have_no_private_trailer(self):
        raw=FRAME+json.dumps(stage()).encode()
        self.assertEqual(decode_stage(b'diagnostic'+raw, 'live'), stage())
        for value in (b'private', raw+raw, raw+b'private', b'x'*(2*1024*1024+1)+raw):
            with self.assertRaises(ValueError): decode_stage(value, 'live')

    def test_two_process_proof_requires_same_cached_results_and_cleanup(self):
        for key in ('tmpfs_profile', 'profile_removed'):
            value=result(); value[key]=False
            with self.assertRaises(ValueError): decode_result(FRAME+json.dumps(value).encode())
        for key in ('shelf_books', 'shelf_groups', 'known_progress', 'progress_snapshots', 'cover_cells'):
            value=result(); value['stages'][1][key]-=1
            with self.assertRaises(ValueError): decode_result(FRAME+json.dumps(value).encode())
        value=result(); value['stages'].pop()
        with self.assertRaises(ValueError): decode_result(FRAME+json.dumps(value).encode())

    def invoke(self, child_result=None, error=None):
        credentials=dict(vid='88008800',accessToken='private-access',refreshToken='private-refresh',deviceId='private-device')
        saved=dict(vid='88008800',cookies={'wr_skey':'private-cookie'})
        samples=[dict(book_id='99009900',expected=dict(bookId='99009900',title='private-title'))]
        probe=SimpleNamespace(inspect=lambda *_:dict(shelf_book_count=40),samples=samples)
        with patch('verify_persistent_ui.SessionStore') as web, patch('verify_persistent_ui.NativeSessionStore') as native, \
                patch('verify_persistent_ui.NativeMetadataProbe', return_value=probe), \
                patch('verify_persistent_ui.verified_web_snapshot',return_value=(saved['cookies'],False)), \
                patch('verify_persistent_ui.subprocess.run', side_effect=error, return_value=child_result) as child, \
                redirect_stdout(io.StringIO()) as output:
            web.return_value.load.return_value=saved
            native.return_value.load.return_value=credentials
            code=main(['--saved-session','--lua-command','synthetic'])
        for store in (web,native):
            store.return_value.save.assert_not_called();store.return_value.delete.assert_not_called()
        self.assertEqual(credentials,{});self.assertEqual(saved,{});self.assertEqual(samples,[])
        text=output.getvalue()
        for private in ('private-access','private-refresh','private-cookie','private-title','private-device','88008800','99009900'):
            self.assertNotIn(private,text)
        return code,json.loads(text),child

    def test_web_rotation_is_verified_and_saved_before_use(self):
        saved=dict(vid='88008800',cookies=dict(wr_vid='88008800',wr_skey='old-private'))
        cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/')
                 for k,v in dict(wr_vid='88008800',wr_skey='new-private').items()]
        store=object()
        with patch('verify_persistent_ui.WebSourceProbe') as web, \
                patch('verify_persistent_ui.save_refreshed_web_session',return_value=True) as save:
            web.return_value.cookies=cookies
            actual,rotated=verified_web_snapshot(store,saved)
        web.return_value.verify_account.assert_called_once();save.assert_called_once_with(store,saved,web.return_value)
        self.assertTrue(rotated);self.assertEqual(actual['wr_skey'],'new-private')

    def test_failed_web_owner_check_never_saves_or_starts_ui(self):
        with patch('verify_persistent_ui.WebSourceProbe') as web, \
                patch('verify_persistent_ui.save_refreshed_web_session') as save:
            web.return_value.verify_account.side_effect=ValueError('private')
            with self.assertRaises(ValueError):verified_web_snapshot(object(),dict(vid='88008800',cookies={}))
        save.assert_not_called()

    def test_success_exports_only_verified_counts(self):
        code, report, child=self.invoke(SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(result()).encode(),stderr=b'private-title'))
        self.assertEqual(code,0);self.assertEqual(report['result'],'OWNER_FILE_BACKED_UI_READ_VERIFIED')
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['cookies']['wr_skey'],'private-cookie')

    def test_failure_and_timeout_never_leak_or_retry(self):
        for failure in (SimpleNamespace(returncode=1,stdout=b'private-cookie',stderr=b'private-title'),None):
            error=subprocess.TimeoutExpired('private-title',320,output=b'private-access') if failure is None else None
            code, report, child=self.invoke(failure,error)
            self.assertEqual(code,1);self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(child.call_count,1)

    def test_failed_stage_counts_remain_sanitized(self):
        value=result();value.update(result='UNVERIFIED');value['stages']=[dict(stage(),result='UNVERIFIED',phase='home')]
        code, report, _=self.invoke(SimpleNamespace(returncode=1,stdout=FRAME+json.dumps(value).encode(),stderr=b''))
        self.assertEqual(code,1);self.assertEqual(report['ui']['stages'][0]['phase'],'home')

    def test_candidate_rejects_traversal_duplicates_and_symlinks(self):
        for name, symlink, duplicate in [('weread.koplugin/../private',False,False),('/private',False,False),
                                         ('weread.koplugin/link',True,False),('weread.koplugin/a',False,True)]:
            with tempfile.TemporaryDirectory() as d:
                p=Path(d)/'candidate.zip'
                with zipfile.ZipFile(p,'w') as z:
                    info=zipfile.ZipInfo(name);info.external_attr=(0o120777 if symlink else 0o100644)<<16
                    z.writestr(info,'synthetic')
                    if duplicate:
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter('ignore',UserWarning);z.writestr(info,'synthetic')
                with self.assertRaises(ValueError):extract_candidate(p,Path(d)/'out')

    def test_candidate_extracts_expected_regular_files(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'candidate.zip'
            with zipfile.ZipFile(p,'w') as z:z.writestr('weread.koplugin/main.lua','synthetic')
            extract_candidate(p,Path(d)/'out')
            self.assertEqual((Path(d)/'out/weread.koplugin/main.lua').read_text(),'synthetic')

    def test_child_timeout_kills_group_and_reaps_before_profile_cleanup(self):
        child=MagicMock();child.pid=12345;child.communicate.side_effect=subprocess.TimeoutExpired('synthetic',150)
        with patch('run_persistent_ui_probe.subprocess.Popen',return_value=child) as spawn, \
                patch('run_persistent_ui_probe.os.killpg') as kill, self.assertRaises(subprocess.TimeoutExpired):
            run_child(['synthetic'],{},b'private-input','/runtime')
        self.assertTrue(spawn.call_args.kwargs['start_new_session']);self.assertEqual(spawn.call_args.kwargs['cwd'],'/runtime')
        kill.assert_called_once();child.wait.assert_called_once()
        for stream in (child.stdin,child.stdout,child.stderr):stream.close.assert_called_once()

    def test_repaint_diagnostic_is_not_forwarded(self):
        child=MagicMock();child.pid=12345;child.returncode=0;child.communicate.return_value=(b'private-title',b'[WeRead] forceRePaint failed: private')
        with patch('run_persistent_ui_probe.subprocess.Popen',return_value=child), patch('run_persistent_ui_probe.os.killpg'):
            code,out,repaint=run_child(['synthetic'],{},b'private-input')
        self.assertEqual(code,0);self.assertTrue(repaint);self.assertEqual(out,b'private-title')


if __name__=='__main__': unittest.main()
