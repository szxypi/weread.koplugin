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

from verify_persistent_ui import (FRAME,FLAGS,FullShelfMetadataProbe,decode_result,decode_stage,main,
                                  shelf_reference,validate_stage,verified_web_snapshot)
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


def full_stage(mode='live'):
    value=stage(mode)
    value.update(shelf_books=139,cover_cells=139,progress_snapshots=137,known_progress=100,
                 cover_gets=141 if mode=='live' else 0,progress_gets=137 if mode=='live' else 0,
                 painted_views=26 if mode=='live' else 48)
    value['shelf_coverage']=dict(reference_books=139,regular_books=137,public_accounts=2,forward_pages=24,
                                reverse_pages=22 if mode=='reopen' else 0,unique_cells=139,progress_eligible=137,
                                cover_eligible=139,partition_verified=True,reference_fields_match=True,
                                page_cache_matches=True,boundaries_verified=True)
    return value


def full_result():return dict(result(),stages=[full_stage(),full_stage('reopen')])


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


class FullShelfUITests(unittest.TestCase):
    def test_all_pages_is_explicit_and_cannot_change_default_limits(self):
        with self.assertRaises(ValueError):validate_stage(full_stage(),'live')
        with self.assertRaises(ValueError):decode_result(FRAME+json.dumps(full_result()).encode())
        with self.assertRaises(ValueError):validate_stage(stage(),'live',all_shelf_pages=True)
        value=full_stage()
        self.assertEqual(validate_stage(value,'live',all_shelf_pages=True),value)

    def test_full_two_process_contract_covers_reverse_paging_and_same_cached_totals(self):
        raw=FRAME+json.dumps(full_result()).encode()
        self.assertEqual(decode_result(raw,all_shelf_pages=True),full_result())
        for key in ('regular_books','public_accounts','unique_cells','forward_pages','progress_eligible','cover_eligible'):
            value=full_result();value['stages'][1]['shelf_coverage'][key]-=1
            with self.subTest(key=key),self.assertRaises(ValueError):decode_result(FRAME+json.dumps(value).encode(),all_shelf_pages=True)

    def test_missing_reference_cells_or_progress_cannot_pass(self):
        for key in ('reference_books','unique_cells','progress_eligible','cover_eligible'):
            value=full_stage();value['shelf_coverage'][key]-=1
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(value,'live',all_shelf_pages=True)
        value=full_stage();value['progress_gets']-=1
        with self.assertRaises(ValueError):validate_stage(value,'live',all_shelf_pages=True)

    def test_coverage_fields_are_fixed_and_do_not_admit_private_values(self):
        for key in ('title','book_id','raw','page_manifest','credentials'):
            value=full_stage();value['shelf_coverage'][key]='private'
            with self.assertRaises(ValueError):validate_stage(value,'live',all_shelf_pages=True)
        for key in ('partition_verified','reference_fields_match','page_cache_matches','boundaries_verified'):
            for invalid in (False,1,'private'):
                value=full_stage();value['shelf_coverage'][key]=invalid
                with self.subTest(key=key,invalid=invalid),self.assertRaises(ValueError):
                    validate_stage(value,'live',all_shelf_pages=True)

    def test_full_caps_are_bounded_and_counts_remain_strict_integers(self):
        for key,bad in (('shelf_books',161),('cover_gets',641),('progress_gets',161),('painted_views',323)):
            value=full_stage();value[key]=bad
            with self.assertRaises(ValueError):validate_stage(value,'live',all_shelf_pages=True)
        for key in full_stage()['shelf_coverage']:
            if type(full_stage()['shelf_coverage'][key]) is not int:continue
            for invalid in (-1,161,True,1.0,'1'):
                value=full_stage();value['shelf_coverage'][key]=invalid
                with self.subTest(key=key,invalid=invalid),self.assertRaises(ValueError):
                    validate_stage(value,'live',all_shelf_pages=True)

    def test_full_offline_network_or_missing_reverse_pages_is_rejected(self):
        for key,bad in (('request_counts',[1,0]),('cover_gets',1),('progress_gets',1)):
            value=full_stage('reopen');value[key]=bad
            with self.assertRaises(ValueError):validate_stage(value,'reopen',all_shelf_pages=True)
        value=full_stage('reopen');value['shelf_coverage']['reverse_pages']=0
        with self.assertRaises(ValueError):validate_stage(value,'reopen',all_shelf_pages=True)

    def test_reference_rejects_empty_duplicate_oversized_or_private_invalid_rows(self):
        valid=dict(bookId='41',title='Private title',author='Private author',cover='https://example.org/cover')
        for books in ([],[valid]*2,[valid]*161,[{}],[dict(valid,bookId=False)],
                      [dict(valid,title='private\n')],[dict(valid,title='a'*4097)]):
            with self.subTest(count=len(books)),self.assertRaises(ValueError):shelf_reference(dict(books=books))
        self.assertEqual(shelf_reference(dict(books=[valid])),{'41':dict(title='Private title',author='Private author',cover='https://example.org/cover')})
        self.assertEqual(shelf_reference(dict(books=[dict(bookId=41,title='Private',author=None,cover=None)])),
                         {'41':dict(title='Private',author='',cover='')})

    def test_reference_is_captured_from_the_existing_shelf_request_without_an_extra_get(self):
        probe=FullShelfMetadataProbe()
        response=dict(books=[dict(bookId='41',title='Private title')])
        with patch('verify_native_metadata.NativeProbe.request',return_value=response) as request:
            self.assertIs(probe.request('metadata_shelf','https://i.weread.qq.com/shelf/sync'),response)
        request.assert_called_once();self.assertEqual(len(probe.shelf_reference),1)
        with self.assertRaises(Exception):probe.request('metadata_shelf','https://i.weread.qq.com/login',body={})

    def test_all_pages_without_saved_session_does_not_open_stores(self):
        with patch('verify_persistent_ui.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
            main(['--all-shelf-pages'])
        store.assert_not_called()

    def test_full_cli_keeps_private_reference_in_captured_pipe_and_clears_it(self):
        grant=dict(vid='88008800',accessToken='private-access',refreshToken='private-refresh',deviceId='private-device')
        saved=dict(vid='88008800',cookies={'wr_skey':'private-cookie'})
        reference={'99009900':dict(title='private-title',author='',cover='')}
        probe=SimpleNamespace(inspect=lambda *_:dict(shelf_book_count=139),
                              samples=[dict(book_id='99009900',expected=dict(bookId='99009900',title='private-title'))],
                              shelf_reference=reference)
        with patch('verify_persistent_ui.SessionStore') as web,patch('verify_persistent_ui.NativeSessionStore') as native,\
             patch('verify_persistent_ui.FullShelfMetadataProbe',return_value=probe),\
             patch('verify_persistent_ui.verified_web_snapshot',return_value=(saved['cookies'],False)),\
             patch('verify_persistent_ui.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(full_result()).encode(),stderr=b'')) as child,\
             redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=saved;native.return_value.load.return_value=grant
            self.assertEqual(main(['--saved-session','--all-shelf-pages','--lua-command','synthetic']),0)
        payload=json.loads(child.call_args.kwargs['input'])
        self.assertTrue(payload['all_shelf_pages']);self.assertIn('99009900',payload['expected_shelf'])
        self.assertEqual(child.call_args.kwargs['timeout'],1280);self.assertEqual(reference,{})
        self.assertEqual(grant,{});self.assertEqual(saved,{})
        for private in ('private-title','private-cookie','private-access','88008800','99009900'):
            self.assertNotIn(private,out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['result'],'OWNER_FILE_BACKED_UI_READ_VERIFIED')


if __name__=='__main__': unittest.main()
