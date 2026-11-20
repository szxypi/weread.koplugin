from contextlib import redirect_stderr, redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from verify_eink_login import NativeProbe
from verify_notebook_catalog import Probe, main, summarize
from notebook_catalog_model import project
from run_notebook_catalog_ui import FLAGS, FRAME, validate_stage


class NotebookCatalogTest(unittest.TestCase):
    def test_cached_samples_require_native_ui(self):
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
            main(['--saved-session','--cached-notes-sample'])

    def test_bulk_scope_requires_native_ui_and_excludes_other_sample(self):
        for args in (['--bulk-notes'],['--saved-session','--bulk-notes'],
                     ['--saved-session','--native-ui','--cached-notes-sample','--bulk-notes','--lua-command','fixture']):
            with patch('verify_notebook_catalog.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
                main(args)
            store.assert_not_called()

    def test_offline_default_has_no_network_or_keychain(self):
        with patch('verify_notebook_catalog.SessionStore') as store,patch('verify_notebook_catalog.Probe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_fixed_read_only_requests_and_bounded_cursor(self):
        probe=Probe();grant={'vid':'synthetic'}
        with patch.object(NativeProbe,'request',return_value={'books':[]}) as request:
            probe.read(grant,2);probe.read(grant,100);probe.read(grant,2,123)
            self.assertEqual(request.call_count,3)
            self.assertEqual(request.call_args.args[1],'https://i.weread.qq.com/user/notebooks?count=2&lastSort=123')
            self.assertIsNone(request.call_args.kwargs.get('body'))
            probe.read(grant,100,123)
            with self.assertRaises(ValueError):probe.read(grant,2)
        for count,last in ((1,None),(2,-1),(2,True),(2,'1'),(2,2**54)):
            with self.subTest(count=count,last=last),self.assertRaises(ValueError):Probe().read(grant,count,last)

    def test_shape_contains_no_book_data(self):
        value={'books':[{'bookId':'private-book','noteCount':1,'book':{'title':'private-title'}}],
               'hasMore':1,'totalBookCount':1}
        result=summarize(value)
        self.assertEqual(result['rows'],1);self.assertEqual(result['book_fields']['title'],1)
        self.assertNotIn('private-book',repr(result));self.assertNotIn('private-title',repr(result))
        for invalid in ({}, {'books':[None]}, {'books':[{}]*5001}):
            with self.assertRaises(ValueError):summarize(invalid)

    def test_full_catalog_projection_rejects_partial_and_conflicting_rows(self):
        row=dict(bookId='CB_example',book=dict(bookId='CB_example',title='Synthetic',author='Author',token='discard'),
                 noteCount=2,reviewCount=1,bookmarkCount=0,sort=10,token='discard')
        source=dict(books=[row],totalBookCount=1,synckey=100)
        projected=project(source,1000)
        self.assertEqual(projected['books'][0]['bookId'],'CB_example')
        self.assertNotIn('discard',repr(projected))
        for changed in (dict(source,totalBookCount=2),dict(source,hasMore=1),dict(source,books=[row,row],totalBookCount=2),
                        dict(source,books=[dict(row,bookId='42')]),dict(source,books=[dict(row,noteCount=True)])):
            with self.subTest(changed=changed),self.assertRaises(ValueError):project(changed,1000)
        self.assertEqual(project(dict(books=[],totalBookCount=0),1000)['books'],[])

    def test_ui_report_checks_worker_and_offline_scope(self):
        stage=dict.fromkeys(FLAGS,True)
        stage.update(result='PASS',mode='live',phase='complete',pages=1,books=1,requests=1,forbidden=0,failed_line=0)
        validate_stage(stage,'live',1)
        for field,value in (('requests',2),('forbidden',1),('credential_audit',False),('books',0),('failed_line',5)):
            with self.subTest(field=field),self.assertRaises(ValueError):validate_stage(dict(stage,**{field:value}),'live',1)
        with self.assertRaises(ValueError):validate_stage(stage,'reopen',1)
        validate_stage(dict(stage,mode='reopen',requests=0),'reopen',1)

    def test_bulk_report_requires_complete_sets_and_no_offline_reads(self):
        stage=dict.fromkeys(FLAGS,True)
        stage.update(result='PASS',mode='live',phase='complete',pages=1,books=1,requests=1,forbidden=0,failed_line=0,
                     bulk_notes=dict(books=1,saved=2,skipped=0,requests=3,menu_started=True,cache_verified=True,
                                     resume_checked=True,resume_requests=1))
        validate_stage(stage,'live',1,bulk_notes=True)
        for key,bad in (('books',0),('saved',1),('skipped',True),('requests',2),('requests',12),
                        ('menu_started',False),('cache_verified',False),('resume_checked',False),('resume_requests',0),('title','private')):
            row=dict(stage,bulk_notes=dict(stage['bulk_notes'],**{key:bad}))
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(row,'live',1,bulk_notes=True)
        with self.assertRaises(ValueError):validate_stage(dict(stage,bulk_notes=dict(stage['bulk_notes'],skipped=1)),
                                                          'live',1,bulk_notes=True)
        offline=dict(stage,mode='reopen',requests=0,bulk_notes=dict(stage['bulk_notes'],menu_started=False,requests=0,
                                                                    resume_checked=False,resume_requests=0))
        validate_stage(offline,'reopen',1,bulk_notes=True)
        offline['bulk_notes']['requests']=1
        with self.assertRaises(ValueError):validate_stage(offline,'reopen',1,bulk_notes=True)

    def test_real_ui_success_and_failure_do_not_export_private_values(self):
        raw=dict(books=[dict(bookId='123',book=dict(bookId='123',title='private-title',author='Author'),
                        noteCount=1,reviewCount=0,bookmarkCount=0,sort=123)],totalBookCount=1)
        grant={'vid':'123','accessToken':'private-access'};saved={'vid':'123'}
        expected=project(raw,1)
        stage=dict.fromkeys(FLAGS,True)
        stage.update(result='PASS',mode='live',phase='complete',pages=1,books=1,requests=1,forbidden=0,failed_line=0)
        ui=dict(result='PASS',profile_removed=True,installed_bytes_match=True,installed_files=1,
                stages=[stage,dict(stage,mode='reopen',requests=0)])
        payload=dict(model=expected,native=expected,requests=1,ui=ui)
        for fail in (False,True):
            child=SimpleNamespace(returncode=int(fail),stdout=FRAME+json.dumps(payload).encode())
            with patch('verify_notebook_catalog.SessionStore') as web,patch('verify_notebook_catalog.NativeSessionStore') as native,\
                    patch('verify_notebook_catalog.Probe') as probe,patch('verify_notebook_catalog.subprocess.run',return_value=child),\
                    redirect_stdout(io.StringIO()) as out:
                web.return_value.load.return_value=dict(saved);native.return_value.load.return_value=dict(grant)
                probe.return_value.read.return_value=raw;probe.return_value.report={'stages':[]}
                result=main(['--saved-session','--native-ui','--lua-command','fixture'])
            self.assertEqual(result,int(fail));report=json.loads(out.getvalue())
            self.assertNotIn('private-title',repr(report));self.assertNotIn('private-access',repr(report))
            self.assertEqual(report['result'],'UNVERIFIED' if fail else 'OBSERVED')
            if not fail:self.assertTrue(report['native_ui_verified'])

    def test_bulk_ui_passes_scope_privately_and_reports_only_fixed_diagnostics(self):
        raw=dict(books=[dict(bookId='123',book=dict(bookId='123',title='private-title',author='Author'),
                             noteCount=1,reviewCount=0,bookmarkCount=0,sort=123)],totalBookCount=1)
        expected=project(raw,1);grant={'vid':'123','accessToken':'private-access'};saved={'vid':'123'}
        stage=dict.fromkeys(FLAGS,True)
        stage.update(result='PASS',mode='live',phase='complete',pages=1,books=1,requests=1,forbidden=0,failed_line=0,
                     bulk_notes=dict(books=1,saved=2,skipped=0,requests=3,menu_started=True,cache_verified=True,
                                     resume_checked=True,resume_requests=1))
        reopen=dict(stage,mode='reopen',requests=0,bulk_notes=dict(stage['bulk_notes'],requests=0,menu_started=False,
                                                                   resume_checked=False,resume_requests=0))
        ui=dict(result='PASS',profile_removed=True,installed_bytes_match=True,installed_files=1,stages=[stage,reopen])
        result=dict(model=expected,native=expected,requests=1,ui=ui)
        child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(result).encode())
        with patch('verify_notebook_catalog.SessionStore') as web,patch('verify_notebook_catalog.NativeSessionStore') as native,\
                patch('verify_notebook_catalog.Probe') as probe,patch('verify_notebook_catalog.subprocess.run',return_value=child) as run,\
                redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(saved);native.return_value.load.return_value=dict(grant)
            probe.return_value.read.return_value=raw;probe.return_value.report={'stages':[]}
            self.assertEqual(main(['--saved-session','--native-ui','--bulk-notes','--lua-command','fixture']),0)
        self.assertTrue(json.loads(run.call_args.kwargs['input'])['bulk_notes'])
        text=out.getvalue();self.assertNotIn('private-title',text);self.assertNotIn('private-access',text)
        report=json.loads(text);self.assertEqual(report['bulk_diagnostics'][0]['saved'],2)


if __name__=='__main__':unittest.main()
