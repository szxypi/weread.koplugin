"""Offline boundaries for off-shelf home acceptance; no account credentials."""
import contextlib
import copy
import io
import json
import unittest
from unittest.mock import patch

import verify_owner_home_recent as probe
from mock_weread import chapter_html,shards
from verify_web_source_progress import PreflightError


class FakeWeb:
    def __init__(self):
        self.book_id=None;self.chapter=None;self.stages=[];self.changed=False
        self.source=chapter_html(1);self.parts=dict(zip(('e_0','e_1','e_3'),shards(self.source,3)))
        self.catalog={'data':[{'bookId':'900001','updated':[{'chapterUid':1,'title':'Synthetic','wordCount':1000}]}]}
        state={'reader':{'bookInfo':{'bookId':'900001','title':'Synthetic','author':'Example'},
                         'psvts':'test-session','currentChapter':{'chapterUid':1},'progress':{}}}
        self.html='<script>window.__INITIAL_STATE__='+json.dumps(state)+';(function(){})();</script>'
    def request(self,stage,_url,body=None,**_kwargs):
        self.stages.append(stage)
        if stage in ('progress_before','progress_after'):return {'synthetic':True}
        if stage in ('reader_root','reader'):return self.html
        if stage in ('catalog_before','catalog_after'):
            if stage=='catalog_after' and self.changed:return {'data':[]}
            return copy.deepcopy(self.catalog)
        return self.parts[stage]


def sample(free=True):
    return {'book_id':'900001','expected':{'chapters':[{'uid':1,'free_or_owned':free}]}}


class OwnerHomeRecentTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(probe,'SessionStore',side_effect=AssertionError('unexpected credentials')):
            with contextlib.redirect_stdout(io.StringIO()) as out:self.assertEqual(probe.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):probe.main(['--store-search'])
        for option in ('--with-cover','--with-marks'):
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):probe.main([option])

    def test_shelf_ids_are_bounded_and_unique(self):
        self.assertEqual(probe.ids({'books':[{'bookId':123},{'bookId':'CB_Valid'}]}),['123','CB_Valid'])
        for value in ({'books':[]},{'books':[{'bookId':'x-y'}]},{'books':[{'bookId':'1'},{'bookId':'1'}]},{}):
            with self.subTest(value=value),self.assertRaises(ValueError):probe.ids(value)

    def test_candidate_checks_access_and_stable_sources(self):
        web=FakeWeb()
        with patch.object(probe,'observation',return_value={'position_present':False}):
            result=probe.candidate(web,sample())
        self.assertIsNotNone(result)
        self.assertEqual(result[0]['chapter_uid'],'1')
        self.assertEqual(result[0]['off_shelf_row']['bookId'],'900001')
        self.assertIn('catalog_after',web.stages)
        web=FakeWeb()
        with patch.object(probe,'observation',return_value={'position_present':False}):
            self.assertIsNone(probe.candidate(web,sample(False)))
        self.assertNotIn('e_0',web.stages)
        web=FakeWeb();web.changed=True
        with patch.object(probe,'observation',return_value={'position_present':False}):
            self.assertIsNone(probe.candidate(web,sample()))
        web=FakeWeb()
        with patch.object(probe,'observation',side_effect=[{'position_present':False},{'position_present':True}]):
            self.assertIsNone(probe.candidate(web,sample()))
        web=FakeWeb();web.catalog['data'][0]['updated'][0]['wordCount']=0
        with patch.object(probe,'observation',return_value={'position_present':False}):
            self.assertIsNone(probe.candidate(web,sample()))
        self.assertNotIn('e_0',web.stages)

    def test_http_failure_does_not_get_reclassified_as_no_candidate(self):
        web=FakeWeb()
        def denied(*_args,**_kwargs):raise PreflightError('http_rejected')
        web.request=denied
        with self.assertRaises(PreflightError):probe.candidate(web,sample())

    def test_reader_root_scope_does_not_allow_other_books(self):
        web=probe.Probe();web.authenticated=True;web.book_id='900001'
        web.guard('reader_root',probe.reader_url_for('900001'),None)
        for url in (probe.reader_url_for('900002'),probe.reader_url_for('900001',1)):
            with self.assertRaises(PreflightError):web.guard('reader_root',url,None)
        with self.assertRaises(PreflightError):web.guard('reader_root',probe.reader_url_for('900001'),{'bookId':'900001'})
        web.close()


if __name__=='__main__':unittest.main()
