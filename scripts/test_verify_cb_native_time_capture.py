"""Synthetic end-to-end checks for read-only CB capture orchestration."""
import base64,copy,io,json,unittest,zipfile
from contextlib import nullcontext,redirect_stderr,redirect_stdout
from unittest.mock import patch

from native_time_capture_bundle import CaptureBundleStore
from test_cb_native_time_capture import fixture
from test_secure_native_session import Backend
import verify_cb_native_time_capture as task


class CaptureOrchestrationTests(unittest.TestCase):
    def test_offline_default_and_incomplete_cli_do_not_touch_stores(self):
        with patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in (['--saved-session'],['--capture'],['--native-ui-command','fake']):
            with self.subTest(args=args),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_capture_save_and_changed_or_unverified_readback(self):
        for mode in ('success','changed','runner_failed','missing_evidence'):
            with self.subTest(mode=mode):self.run_case(mode)

    def test_existing_capture_stops_before_session_or_network(self):
        from unittest.mock import Mock
        bundle=Mock();bundle.read.return_value=({'saved':True},object());session=Mock();native=Mock()
        with patch.object(task,'CaptureWeb') as web,patch.object(task,'execute') as execute:
            result=task.run(session,native,bundle,['isolated-runner'],1)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(result['reason'],'cb_capture/already_saved')
        session.load.assert_not_called();native.load.assert_not_called();web.assert_not_called();execute.assert_not_called()

    def run_case(self,mode):
        plan,proof,_,_,_=fixture();book=plan['book_id'];owner=plan['owner']
        with zipfile.ZipFile(io.BytesIO(base64.b64decode(plan['archive_base64']))) as archive:
            text=archive.read('OEBPS/weread-position/raw-'+plan['raw_sha256']+'.txt').decode()
        chapters=[dict(chapterUid=2,chapterIdx=2,wordCount=500,title='Synthetic chapter')]
        record=dict(bookId=book,book=dict(bookId=book,bookVersion=7),updated=chapters)
        shelf=dict(books=[dict(bookId=book,secret=0,finishReading=0)],archive=[])
        progress=dict(book=dict(bookId=book,chapterUid=2,chapterIdx=2,chapterOffset=10,progress=20,
                                summary='Synthetic full summary',readingTime=10,recordReadingTime=0,ttsTime=0))
        sample=dict(book_id=book,chapter_uid='2',source_format='web_xhtml',source=text,source_text='synthetic content '*3,
            source_raw_sha256=plan['raw_sha256'],source_sample_offset=0,shelf_ids=[book],shelf_books=1,chapters=chapters)
        credentials=dict(vid=owner,deviceId='eink334691225'+'1'*19,accessToken='synthetic-access',refreshToken='synthetic-refresh')
        cookies={'wr_vid':owner,'wr_skey':'synthetic-private-cookie'}
        class Session:
            def load(self):return dict(vid=owner,cookies=dict(cookies))
        class NativeStore:
            def load(self,_owner):return dict(credentials)
        class FakeWeb:
            counter=0
            def __init__(self):
                self.after=FakeWeb.counter>0;FakeWeb.counter+=1;self.samples=[];self.progress={};self.catalogs=[];self.shelf=None
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def populate(self):
                current=copy.deepcopy(progress)
                if mode=='changed' and self.after:current['book']['summary']='changed'
                self.shelf=copy.deepcopy(shelf);self.catalogs=[dict(data=[copy.deepcopy(record)]),dict(data=[copy.deepcopy(record)])]
                self.progress[(book,'progress_before')]=current;self.progress[(book,'progress_after')]=copy.deepcopy(current)
                self.samples=[copy.deepcopy(sample)]
                return self.samples[0]
            def prepare(self,index):assert index==1;return [self.populate()]
            def inspect(self,identity):assert identity==book;return self.populate()
            def request(self,stage,_url):assert stage=='shelf';self.shelf=copy.deepcopy(shelf);return self.shelf
        class FakeNative:
            def __init__(self,_grant,identity):assert identity==book
            def request(self,stage,_url,**_kwargs):
                if stage=='cb_capture_progress':return copy.deepcopy(progress)
                if stage=='cb_capture_info':return dict(bookId=book,version=7)
                if stage=='cb_capture_shelf':return copy.deepcopy(shelf)
                raise AssertionError(stage)
        def execute(payload,_command):
            if mode=='runner_failed':raise ValueError('synthetic')
            captured=copy.deepcopy(plan);captured.update(device_sha256=payload['native_time_capture']['device_sha256'],
                                                        baseline_sha256=payload['native_time_capture']['baseline_sha256'])
            return dict(result='PASS',capture=captured,sqlite_evidence=None if mode=='missing_evidence' else copy.deepcopy(proof),
                        cookies=dict(cookies),profile_removed=True)
        parts={};backend=Backend();chunks=lambda index:parts.setdefault(index,Backend())
        bundle=CaptureBundleStore(backend,chunks=chunks,lock=nullcontext,imported=True)
        with patch.object(task,'CaptureWeb',FakeWeb),patch.object(task,'Native',FakeNative),patch.object(task,'execute',side_effect=execute),\
             patch.object(task,'save_refreshed_web_session',return_value=False):
            result=task.run(Session(),NativeStore(),bundle,['isolated-runner'],1,clock=lambda:plan['ended_at']+1)
        self.assertEqual(result['result'],'CB_NATIVE_WINDOW_CAPTURED' if mode=='success' else 'UNVERIFIED')
        self.assertEqual(result['account_data_posts'],0);self.assertEqual(result['authentication_posts'],0)
        self.assertNotIn(book,json.dumps(result));self.assertNotIn(cookies['wr_skey'],json.dumps(result))
        self.assertEqual(bundle.read()[0] is not None,mode=='success')


if __name__=='__main__':unittest.main()
