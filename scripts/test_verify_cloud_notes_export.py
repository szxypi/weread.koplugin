"""Independent comparison and default-offline boundary for note export."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import verify_cloud_notes_export as task


class VerifyCloudNotesExportTests(unittest.TestCase):
    def fixture(self):
        marks={'fetched_at':1000,'chapters':[{'chapterUid':2,'title':'Synthetic chapter'}],
               'updated':[{'bookmarkId':'private-id','type':1,'chapterUid':2,'markText':'Quote\r\n<script> [link](x)',
                           'abstract':'Different excerpt','style':1,'colorStyle':3,'range':'1-2'}]}
        thoughts={'fetched_at':1001,'reviews':[{'reviewId':'private-thought','content':'Synthetic thought',
                   'abstract':'Quoted text','isPrivate':1,'chapterUid':2,'chapterName':''}]}
        left,right=task.expected_rows(marks,thoughts)
        markdown=''.join(task.quoted(value) for value in ('Quote\r\n<script> [link](x)','Different excerpt','Quoted text','Synthetic thought'))
        exported={'schema':1,'source':'WeRead','book':{'title':'Synthetic export','author':'','exported_at':'synthetic'},
                  'snapshots':{'marks':{'available':True,'fetched_at':1000},'thoughts':{'available':True,'fetched_at':1001}},
                  'marks':left,'thoughts':right}
        return marks,thoughts,{'result':'PASS','count':2,'json':exported,'markdown':markdown}

    def test_default_never_loads_credentials_or_runs_a_process(self):
        with patch.object(task,'SessionStore') as session,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_exact_json_and_markdown_comparison(self):
        marks,thoughts,value=self.fixture()
        raw=task.FRAME+json.dumps(value).encode()
        self.assertEqual(task.compare(raw,marks,thoughts),(1,1))
        self.assertEqual(value['json']['thoughts'][0]['chapter'],'')
        for mode in ('missing_quote','wrong_count','wrong_visibility','extra_identifier','private_book_field','wrong_snapshot'):
            changed=deepcopy(value)
            if mode=='missing_quote':changed['markdown']='unrelated'
            elif mode=='wrong_count':changed['count']=True
            elif mode=='wrong_visibility':changed['json']['thoughts'][0]['visibility']='public'
            elif mode=='extra_identifier':changed['json']['marks'][0]['bookmarkId']='private-id'
            elif mode=='private_book_field':changed['json']['book']['book_id']='private'
            else:changed['json']['snapshots']['thoughts']['available']=False
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                task.compare(task.FRAME+json.dumps(changed).encode(),marks,thoughts)
        with self.assertRaises(ValueError):task.compare(b'missing',marks,thoughts)

    def test_native_ui_only_receives_offline_credentials_and_redacts_notes(self):
        marks,thoughts,value=self.fixture()
        stage={'result':'PASS','phase':'complete','failed_line':0,'requests':0,'forbidden':0}
        ui=dict(result='PASS',profile_removed=True,stages=[stage,stage],offline_network_guard=True,
                independent_reopen=True,temporary_files_removed=True)
        child=SimpleNamespace(returncode=0,stdout=task.UI_FRAME+json.dumps(ui).encode()+task.FRAME+json.dumps(value).encode())
        api=SimpleNamespace(request=lambda stage,*_args,**_kwargs: {'books':[{'bookId':'900001'}]} if stage.startswith('shelf') else {})
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as native,\
                patch.object(task,'NativeProbe',return_value=api),patch.object(task,'project',return_value=marks),\
                patch.object(task,'complete',return_value=thoughts),patch.object(task,'state_hash',return_value='unchanged'),\
                patch.object(task.subprocess,'run',return_value=child) as execute,redirect_stdout(io.StringIO()) as output:
            session.return_value.load.return_value={'vid':'900000'}
            native.return_value.load.return_value={'vid':'900000','accessToken':'private-real-token'}
            self.assertEqual(task.main(['--saved-session','--native-ui','--lua-command','runner']),0)
        sent=json.loads(execute.call_args.kwargs['input'])
        self.assertEqual(sent['credentials']['accessToken'],'offline-access')
        self.assertNotIn('private-real-token',json.dumps(sent))
        self.assertNotIn('Synthetic thought',output.getvalue())
        report=json.loads(output.getvalue())
        self.assertTrue(report['native_ui']['independent_reopen'])
        self.assertTrue(report['private_notes_only_on_tmpfs'])

    def test_native_ui_cannot_run_without_a_session(self):
        with self.assertRaises(SystemExit):task.main(['--native-ui'])


if __name__=='__main__':unittest.main()
