"""Synthetic own-mark contract, request boundaries, and redacted diagnostics."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from my_cloud_marks_model import project
from verify_my_cloud_marks import MarksProbe,main,BASE
from run_my_cloud_marks_ui import validate_stage,FLAGS


def source():
    return dict(bookId='900001',updated=[dict(bookmarkId='synthetic-mark',bookId='900001',userVid='900000',
                markText='合成引用\n第二行',abstract='摘要',range='12-23',chapterUid=7,type=1,style=1,createTime=123,
                private='discard')],chapters=[dict(chapterUid=7,title='合成章节')],accessToken='discard')


class MarksTests(unittest.TestCase):
    def test_projection_is_display_only_and_does_not_mutate(self):
        raw=source();before=deepcopy(raw);out=project(raw,'900001','900000',1000)
        self.assertEqual(raw,before)
        self.assertEqual(out,dict(schema=1,book_id='900001',fetched_at=1000,
            updated=[dict(bookmarkId='synthetic-mark',markText='合成引用\n第二行',abstract='摘要',range='12-23',chapterUid=7,type=1,style=1,createTime=123)],
            chapters=[dict(chapterUid=7,title='合成章节')]))
        self.assertEqual(project(dict(updated=[]),'900001',None,1)['updated'],[])

    def test_rejects_wrong_scope_partial_malformed_and_oversized(self):
        cases=[]
        for key,value in [('bookId','900002'),('vid','900002'),('hasMore',1),('errcode',False),('succ',False),('updated',{}),('chapters',None)]:
            raw=source();raw[key]=value;cases.append(raw)
        for key,value in [('bookmarkId','bad id'),('bookId','900002'),('userVid','900002'),('markText','x\x00'),
                          ('markText','x'*131073),('chapterUid',True),('type',-1),('range',33),('createTime',float('inf'))]:
            raw=source();raw['updated'][0][key]=value;cases.append(raw)
        raw=source();raw['updated']*=2;cases.append(raw)
        raw=source();raw['chapters']*=2;cases.append(raw)
        raw=source();raw['updated']=[dict(bookmarkId=f'synthetic-{i}') for i in range(5001)];cases.append(raw)
        for raw in cases:
            with self.subTest(keys=list(raw)),self.assertRaises((ValueError,UnicodeError)):project(raw,'900001','900000',1)
        for identity,now in [('0',1),('CB_Synthetic',1),('900001',True),('900001',0),('900001',float('nan'))]:
            with self.assertRaises(ValueError):project(source(),identity,'900000',now)

    def test_default_does_not_load_credentials_or_use_network(self):
        with patch('verify_my_cloud_marks.SessionStore') as web,patch('verify_my_cloud_marks.NativeSessionStore') as native,\
                patch('verify_my_cloud_marks.MarksProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        web.assert_not_called();native.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_guard_rejects_mutations_other_books_extra_parameters_and_retries(self):
        probe=MarksProbe();probe.identity='900001'
        for stage,url,body in [('marks',BASE+'/book/bookmarklist?bookId=900002&synckey=0',None),
                ('marks',BASE+'/book/bookmarklist?bookId=900001&synckey=1',None),('marks',BASE+'/book/bookmarklist?bookId=900001&synckey=0',{}),
                ('write',BASE+'/book/addBookmark',{}),('marks','https://evil.invalid/book/bookmarklist?bookId=900001&synckey=0',None)]:
            with self.assertRaises(ValueError):probe.request(stage,url,body)
        self.assertEqual(probe.calls,0)
        probe.calls=5
        with self.assertRaises(ValueError):probe.request('shelf',BASE+'/shelf/sync')

    def test_readonly_preparation_and_position_change_detection(self):
        shelf=dict(books=[dict(bookId='900001')]);notebooks=dict(books=[dict(bookId='900001',bookmarkCount=1)])
        for after in [dict(chapterUid=7,chapterOffset=12),dict(chapterUid=7,chapterOffset=13)]:
            probe=MarksProbe()
            with patch.object(probe,'request',side_effect=[shelf,notebooks,dict(chapterUid=7,chapterOffset=12),source(),after]) as req:
                if after['chapterOffset']==12:
                    result=probe.prepare(dict(vid='900000'))
                    self.assertTrue(result['position_unchanged']);self.assertTrue(result['declared_count_matches'])
                    self.assertNotIn('900001',json.dumps(result))
                else:
                    with self.assertRaisesRegex(ValueError,'position_changed'):probe.prepare(dict(vid='900000'))
            self.assertEqual(req.call_count,5)
            self.assertTrue(all(call.kwargs.get('credentials')==dict(vid='900000') for call in req.call_args_list))

    def test_native_ui_receipt_checks_every_flag_and_exact_counts(self):
        row=dict.fromkeys(FLAGS,True)
        row.update(result='PASS',mode='live',phase='complete',screenshots=0,pages=5,quotes=52,requests=1,forbidden=0,failed_line=0,fault_cases=0)
        self.assertEqual(validate_stage(row,'live',52),row)
        for key,value in [('requests',0),('requests',True),('quotes',51),('pages',0),('screenshots',1),('forbidden',1),
                          ('fault_cases',1),('failed_line',1),('result','UNVERIFIED'),('mode','reopen'),('phase','init')]+[(key,False) for key in FLAGS]:
            bad=dict(row);bad[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate_stage(bad,'live',52)
        row.update(mode='reopen',requests=0)
        self.assertEqual(validate_stage(row,'reopen',52),row)
        bad=dict(row,extra='private')
        with self.assertRaises(ValueError):validate_stage(bad,'reopen',52)

    def test_child_failure_redacted_and_store_kept(self):
        credentials=dict(vid='900000',accessToken='private-synthetic-access')
        probe=SimpleNamespace(prepare=lambda *_:dict(marks=1),source=source(),identity='900001',model=dict(fetched_at=1000),
                              book={},baseline={},report=dict(stages=[]))
        with patch('verify_my_cloud_marks.SessionStore') as web,patch('verify_my_cloud_marks.NativeSessionStore') as native,\
                patch('verify_my_cloud_marks.MarksProbe',return_value=probe),\
                patch('verify_my_cloud_marks.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'private-synthetic-output')),\
                redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=credentials
            self.assertEqual(main(['--saved-session','--native-http','--lua-command','synthetic']),1)
        native.return_value.delete.assert_not_called();self.assertEqual(credentials,{})
        self.assertEqual(probe.source,None)
        for value in ['900001','900000','private-synthetic-access','private-synthetic-output','合成引用']:self.assertNotIn(value,out.getvalue())


if __name__=='__main__':unittest.main()
