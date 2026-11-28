"""Synthetic, offline tests of fixture-only no-replay write boundaries."""
import copy
import unittest
from cb_fixture_position import LONG_SUMMARY,STAGES,body,plan
from cb_fixture_position_intent import Intent
from cb_fixture_position_transport import Probe
from secure_weread_session import StoreError
from test_cb_fixture_position import fixture
from verify_position_roundtrip import WRITE_URL
from verify_web_source_progress import BASE


class MemoryBackend:
    def __init__(self):self.data=None
    def load(self):return self.data
    def save(self,value):self.data=value


class FakeProbe(Probe):
    def __init__(self,p,*,fail=None,truncate=False,authority=lambda:True):
        super().__init__(p,'900000',authority);self.authenticated=True;self.set_cookie('wr_vid','900000')
        self.current=dict(bookId=p['book'],chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary='')
        self.sent=[];self.fail=fail;self.truncate=truncate
    def request(self,stage,url,value=None,**_kwargs):
        self.guard(stage,url,value)
        if stage=='progress_after':return dict(book=copy.deepcopy(self.current))
        self.sent.append(stage)
        if stage!='enter':
            self.current.update(chapterUid=self.plan['chapter'],chapterIdx=self.plan['index'],chapterOffset=value['co'],
                                progress=value['pr'],summary=value['sm'][:20] if self.truncate else value['sm'])
        if stage==self.fail:return {}
        return dict(succ=1)


class TestFixtureTransport(unittest.TestCase):
    def setUp(self):
        book,sample=fixture();self.plan=plan(book,sample)
        self.baseline=dict(chapter_uid=0,chapter_offset=0,raw_percent=0)

    def test_one_shot_intent_cannot_rearm_or_change_target(self):
        store=Intent(backend=MemoryBackend());receipt=store.reserve('900000',self.plan['book'],'a'*32)
        self.assertTrue(store.verify(receipt,'900000',self.plan['book'],'a'*32))
        self.assertFalse(store.verify(receipt,'900000','CB_Other','a'*32))
        self.assertFalse(store.verify(receipt,'900001',self.plan['book'],'a'*32))
        with self.assertRaises(StoreError):store.reserve('900000',self.plan['book'],'a'*32)

    def test_complete_and_truncated_summary_are_distinguished(self):
        for truncate in (False,True):
            web=FakeProbe(self.plan,truncate=truncate);result=web.execute(self.baseline)
            self.assertEqual(result['result'],'PASS');self.assertEqual(result['writes'],4)
            self.assertEqual(web.sent,list(STAGES));self.assertTrue(result['source_position_verified'] and result['restored'])
            for key in ('long_summary_retained_at_same','long_summary_retained_at_probe','long_summary_retained_at_restore'):
                self.assertEqual(result[key],not truncate)

    def test_unconfirmed_write_stops_without_retry_or_cleanup_authority(self):
        web=FakeProbe(self.plan,fail='probe');result=web.execute(self.baseline)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(result['writes'],3)
        self.assertEqual(web.sent,['enter','same','probe']);self.assertFalse(result['restored'])
        with self.assertRaises(ValueError):web.send('probe')

    def test_foreign_or_unowned_request_is_rejected(self):
        web=FakeProbe(self.plan,authority=lambda:False)
        with self.assertRaises(ValueError):web.send('enter')
        self.assertEqual(web.sent,[]);self.assertEqual(web.attempted,1)
        web=FakeProbe(self.plan);web.attempted=1;value=body(self.plan,'enter');web.pending=('enter','invalid')
        with self.assertRaises(ValueError):web.guard('enter',WRITE_URL,value)
        with self.assertRaises(Exception):web.guard('other',BASE+'/web/book/read',value)

    def test_baseline_change_prevents_every_write(self):
        web=FakeProbe(self.plan);web.current['chapterUid']=55
        result=web.execute(self.baseline)
        self.assertEqual(result['writes'],0);self.assertEqual(web.sent,[])


if __name__=='__main__':unittest.main()
