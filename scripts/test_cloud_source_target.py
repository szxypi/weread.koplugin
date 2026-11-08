"""Cloud read target boundaries; private synthetic source never enters reports."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from mock_weread import shards
from test_web_source_progress import Opener,BOOK,VID
from verify_cloud_source_target import inspect,main,project
from verify_web_source_progress import PreflightError,WebSourceProbe

SOURCE='<html><body><p>Private source canary: unique local target.</p></body></html>'
POINT=dict(bookId=BOOK,chapterUid=2,chapterOffset=20,progress=32)
READER=dict(bookInfo=dict(bookId=BOOK),currentChapter=dict(chapterUid=2),progress=dict(book=POINT),psvts='synthetic-context')


class CloudTargetTests(unittest.TestCase):
    def test_default_is_offline_and_report_has_no_private_data(self):
        with patch('verify_cloud_source_target.SessionStore') as store,patch('verify_cloud_source_target.WebSourceProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['network_requests'],0)
        self.assertNotIn('canary',out.getvalue())

    def test_projection_is_source_bound_and_never_upload_verified(self):
        value=project(BOOK,dict(book=POINT),READER,SOURCE,dict(book=POINT))
        self.assertEqual(value['chapter_offset'],20)
        self.assertEqual(value['raw_bytes'],len(SOURCE.encode()))
        self.assertEqual(len(value['raw_sha256']),64)
        self.assertFalse(value['upload_verified'])
        self.assertNotIn('source',value)

    def test_changed_cloud_or_reader_identity_is_rejected(self):
        for field in ('chapterUid','chapterOffset','progress'):
            later=dict(POINT);later[field]+=1
            with self.assertRaisesRegex(PreflightError,'cloud_target_changed'):
                project(BOOK,dict(book=POINT),READER,SOURCE,dict(book=later))
        for field in ('bookInfo','currentChapter','progress'):
            reader=deepcopy(READER);reader[field]={}
            with self.assertRaises(PreflightError):project(BOOK,dict(book=POINT),reader,SOURCE,dict(book=POINT))

    def test_api_rejections_and_foreign_reader_stop_before_shard_reads(self):
        for code in (-1,False,'bad'):
            with self.assertRaises(PreflightError):project(BOOK,dict(book=POINT,errcode=code),READER,SOURCE,dict(book=POINT))
        reader=deepcopy(READER);reader['bookInfo']['bookId']='900002'
        html=('<script>window.__INITIAL_STATE__='+json.dumps(dict(reader=reader))+';(function(){})();</script>').encode()
        opener=Opener([dict(book=POINT),html])
        probe=WebSourceProbe(opener);probe.vid,probe.authenticated=VID,True
        with self.assertRaises(PreflightError):inspect(probe,BOOK)
        self.assertEqual(len(opener.calls),2)

    def test_unresolvable_offset_never_snaps_to_a_nearby_character(self):
        for offset in (0,1,10,len(SOURCE)+100):
            point=dict(POINT,chapterOffset=offset);reader=deepcopy(READER);reader['progress']=dict(book=point)
            with self.assertRaises(PreflightError):project(BOOK,dict(book=point),reader,SOURCE,dict(book=point))
        with self.assertRaisesRegex(PreflightError,'cloud_source_invalid'):
            project(BOOK,dict(book=POINT),READER,'x'*(2*1024*1024+1),dict(book=POINT))

    def ready(self):
        html=('<script>window.__INITIAL_STATE__='+json.dumps(dict(reader=READER))+';(function(){})();</script>').encode()
        opener=Opener([dict(book=POINT),html,*(p.encode() for p in shards(SOURCE)),dict(book=POINT)])
        probe=WebSourceProbe(opener);probe.vid,probe.authenticated=VID,True
        return probe,opener

    def test_six_fixed_reads_without_account_mutation(self):
        probe,opener=self.ready();target,sample=inspect(probe,BOOK)
        self.assertEqual(target,sample['expected'])
        self.assertEqual(len(opener.calls),6)
        self.assertEqual([call[0].get_method() for call in opener.calls],['GET','GET','POST','POST','POST','GET'])
        self.assertFalse(any('/read'==call[0].full_url[-5:] for call in opener.calls))

    def test_child_failure_is_generic_and_never_echoes_private_output(self):
        probe,_opener=self.ready()
        saved=dict(vid=VID,cookies={})
        with patch('verify_cloud_source_target.SessionStore') as store,patch('verify_cloud_source_target.WebSourceProbe',return_value=probe),patch.object(probe,'verify_account'),patch('verify_cloud_source_target.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'PRIVATE_SOURCE',stderr=b'PRIVATE_COOKIE')),redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=saved
            self.assertEqual(main(['--saved-session','--book-id',BOOK,'--lua-command','local-probe']),1)
        self.assertEqual(json.loads(out.getvalue())['reason'],'cloud_lua_probe_failed')
        self.assertNotIn('PRIVATE',out.getvalue());self.assertNotIn('canary',out.getvalue())


if __name__=='__main__':unittest.main()
