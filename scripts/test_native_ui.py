"""Offline UI probe boundaries; no account, Keychain, process or network."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_native_ui import BOOL_FIELDS,FRAME,decode_result,main,validate_result


def result():
    return dict(result='PASS',phase='complete',request_counts=[1]*5,paged_shelf=True,
                shelf_books=40,shelf_groups=3,search_books=20,similar_books=20,recommend_books=0,
                painted_views=7,profile_files_audited=4,screenshots=0,forbidden_requests=0,
                **dict.fromkeys(BOOL_FIELDS,True))


class NativeUITests(unittest.TestCase):
    def test_default_never_opens_keychain_or_network(self):
        with patch('verify_native_ui.SessionStore') as web,patch('verify_native_ui.NativeSessionStore') as native,\
                patch('verify_native_ui.NativeMetadataProbe') as probe,patch('verify_native_ui.subprocess.run') as child,\
                redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        for mocked in (web,native,probe,child):mocked.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_saved_and_command_must_be_paired(self):
        for args in (['--saved-session'],['--lua-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)

    def test_schema_rejects_private_extra_fields(self):
        for value in (dict(result(),title='private'),dict(result(),credentials={}),dict(result(),raw={})):
            with self.assertRaises(ValueError):validate_result(value)

    def test_types_limits_and_phase(self):
        for key,value in (('shelf_books',True),('search_books',-1),('similar_books',101),('screenshots',1),
                          ('phase','private-title'),('phase',[]),('result',{}),('paged_shelf',1),('worker_heartbeat',1)):
            source=result();source[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate_result(source)

    def test_pass_requires_every_real_acceptance_gate(self):
        for key in BOOL_FIELDS:
            source=result();source[key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):validate_result(source)
        for key,value in (('painted_views',0),('shelf_books',0),('profile_files_audited',0),('forbidden_requests',1),('phase','shelf')):
            source=result();source[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate_result(source)

    def test_shelf_page_count_adapts_to_small_account(self):
        source=result();source.update(shelf_books=1,paged_shelf=False,painted_views=6)
        self.assertEqual(validate_result(source),source)

    def test_requests_are_exactly_once_per_allowlisted_get(self):
        for value in ([1]*4,[1]*6,[1,1,1,1,2],[True]*5,[0]*5,'private'):
            source=result();source['request_counts']=value
            with self.subTest(value=value),self.assertRaises(ValueError):validate_result(source)

    def test_frame_is_single_bounded_and_has_no_trailer(self):
        frame=FRAME+json.dumps(result()).encode()
        self.assertEqual(decode_result(b'runtime diagnostic'+frame),result())
        for raw in (b'private',frame+frame,frame+b'private',b'x'*(2*1024*1024+1)+frame):
            with self.assertRaises(ValueError):decode_result(raw)

    def invoke(self,child_result=None,error=None):
        credentials=dict(vid='88008800',accessToken='private-access',refreshToken='private-refresh',deviceId='private-device')
        samples=[dict(book_id='99009900',expected=dict(bookId='99009900',title='private-title'))]
        probe=SimpleNamespace(inspect=lambda *_:dict(shelf_book_count=40),samples=samples)
        with patch('verify_native_ui.SessionStore') as web,patch('verify_native_ui.NativeSessionStore') as native,\
                patch('verify_native_ui.NativeMetadataProbe',return_value=probe),\
                patch('verify_native_ui.subprocess.run',side_effect=error,return_value=child_result) as child,\
                redirect_stdout(io.StringIO()) as output:
            web.return_value.load.return_value=dict(vid='88008800')
            native.return_value.load.return_value=credentials
            code=main(['--saved-session','--lua-command','synthetic'])
        native.return_value.delete.assert_not_called();native.return_value.save.assert_not_called()
        self.assertEqual(credentials,{})
        self.assertEqual(samples,[])
        text=output.getvalue()
        for secret in ('private-access','private-refresh','private-title','private-output','private-device','88008800','99009900'):
            self.assertNotIn(secret,text)
        return code,json.loads(text),child

    def test_success_only_exports_schema_counts(self):
        child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(result()).encode(),stderr=b'private-output')
        code,report,called=self.invoke(child)
        self.assertEqual(code,0);self.assertEqual(report['result'],'OWNER_NATIVE_UI_READ_VERIFIED')
        payload=json.loads(called.call_args.kwargs['input'])
        self.assertEqual(payload['expected_metadata']['title'],'private-title')
        self.assertEqual(called.call_args.args[0],['synthetic'])

    def test_failure_stdout_and_stderr_never_leak(self):
        code,report,_=self.invoke(SimpleNamespace(returncode=1,stdout=b'private-output',stderr=b'private-title'))
        self.assertEqual(code,1);self.assertEqual(report['result'],'UNVERIFIED')

    def test_timeout_is_redacted_without_retry(self):
        code,report,child=self.invoke(error=subprocess.TimeoutExpired('private-output',120,output=b'private-access'))
        self.assertEqual(code,1);self.assertEqual(report['reason'],'native_ui_unverified');self.assertEqual(child.call_count,1)

    def test_repaint_warning_cannot_be_reported_as_pass(self):
        child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(result()).encode(),stderr=b'[WeRead] forceRePaint failed: private-title')
        code,report,_=self.invoke(child)
        self.assertEqual(code,1);self.assertEqual(report['result'],'UNVERIFIED')

    def test_known_stage_failure_retains_sanitized_counts(self):
        value=deepcopy(result());value.update(result='UNVERIFIED',phase='book',painted_views=3)
        code,report,_=self.invoke(SimpleNamespace(returncode=1,stdout=FRAME+json.dumps(value).encode(),stderr=b''))
        self.assertEqual(code,1);self.assertEqual(report['ui']['phase'],'book')


if __name__=='__main__':unittest.main()
