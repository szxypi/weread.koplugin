"""Synthetic tests for existing-book source and no-replay write boundaries."""
import copy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from cb_cloud_position import observed
from cb_existing_position_intent import Intent
from cb_existing_position_transport import Probe,signed_body
from secure_weread_session import StoreError
from test_cb_full_summary_payload import sample
import verify_cb_existing_position_trial as task


class MemoryBackend:
    def __init__(self):self.data=None
    def load(self):return self.data
    def save(self,value):self.data=value


class Fake(Probe):
    def __init__(self,plan,raw,*,fail=None,mutate=None):
        self.backend=MemoryBackend();intent=Intent(backend=self.backend)
        reserved=intent.reserve('900000',plan['book_id'],'a'*32,'b'*64)
        super().__init__(plan,'900000',[dict(chapterUid=2,chapterIdx=2)],intent,reserved)
        self.authenticated=True;self.set_cookie('wr_vid','900000');self.current=copy.deepcopy(raw['book'])
        self.fail,self.mutate=fail,mutate;self.sent=[]
    def request(self,stage,url,body=None,**_options):
        self.guard(stage,url,body)
        if stage=='progress_after':return {'book':copy.deepcopy(self.current)}
        self.sent.append(stage)
        if stage!='write_enter':
            self.current.update(chapterOffset=body['co'],summary=body['sm'],progress=body['pr'])
        if stage==self.mutate:self.current['summary']='changed externally'
        return {} if stage==self.fail else {'succ':1}


class TestExistingPosition(unittest.TestCase):
    def setUp(self):
        self.plan,self.raw=sample();summary=self.raw['book']['summary']
        self.plan['baseline']['summary']=summary;self.plan['target']['summary']=summary
        self.chapters=[dict(chapterUid=2,chapterIdx=2)]
        self.baseline=observed(self.raw,self.plan['book_id'],self.chapters,'web')

    def test_offline_does_not_access_credentials_or_network(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Web') as web,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();web.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_candidate_requires_original_source_and_exact_catalog_index(self):
        source='<html><body><p>Unique synthetic position with sufficiently long nearby context.</p></body></html>'
        item=dict(book_id=self.plan['book_id'],chapter_uid='2',source_format='web_xhtml',source=source,
                  source_raw_sha256='a'*64,chapters=self.chapters,context=self.plan['context'])
        selected=task.choose(item,self.raw)
        self.assertIsNotNone(selected)
        plan,models=selected
        self.assertEqual(len(models),4)
        self.assertEqual(plan['baseline']['summary'],self.raw['book']['summary'])
        self.assertEqual(plan['target']['summary'],self.raw['book']['summary'])
        self.assertEqual(models[2]['options']['chapter_offset'],plan['baseline']['chapter_offset']+1)
        item['chapters']=[dict(chapterUid=2,chapterIdx=3)]
        self.assertIsNone(task.choose(item,self.raw))
        item['chapters']=self.chapters;item['source']=source+source
        self.assertIsNone(task.choose(item,self.raw))

    def test_complete_preserves_full_summary_and_original_observation(self):
        probe=Fake(self.plan,self.raw);result=probe.execute(self.baseline)
        self.assertEqual(result,dict(result='PASS',writes=4,entered=True,same=True,advanced=True,restored=True))
        self.assertEqual(probe.position_observation(),self.baseline)
        self.assertEqual(probe.current['summary'],self.raw['book']['summary'])
        for stage in ('write_enter','write_same','write_probe','write_restore'):
            self.assertEqual(signed_body(self.plan,stage)['sm'],self.raw['book']['summary'])
        with self.assertRaises(StoreError):probe.intent.reserve('900000',self.plan['book_id'],'b'*32,'b'*64)

    def test_unknown_effect_and_concurrent_change_stop_without_retry(self):
        for stage,count in (('write_enter',1),('write_same',2),('write_probe',3),('write_restore',4)):
            probe=Fake(self.plan,self.raw,fail=stage);result=probe.execute(self.baseline)
            self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(result['writes'],count)
            self.assertEqual(len(probe.sent),count)
            with self.assertRaises(ValueError):probe.send(stage)
        probe=Fake(self.plan,self.raw,mutate='write_same');result=probe.execute(self.baseline)
        self.assertEqual(result['writes'],2);self.assertFalse(result['advanced'])

    def test_changed_baseline_and_foreign_journal_prevent_writes(self):
        probe=Fake(self.plan,self.raw);probe.current['summary']='concurrent'
        self.assertEqual(probe.execute(self.baseline)['writes'],0)
        probe=Fake(self.plan,self.raw);probe.backend.data=b'changed'
        self.assertEqual(probe.execute(self.baseline)['writes'],0)
        self.assertEqual(probe.sent,[])

    def test_claim_order_and_exact_receipt_are_durable(self):
        backend=MemoryBackend();intent=Intent(backend=backend)
        record=intent.reserve('900000',self.plan['book_id'],'a'*32,'b'*64)
        with self.assertRaises(StoreError):intent.claim(record,'write_probe')
        receipt=intent.claim(record,'write_enter');self.assertTrue(intent.verify(record,receipt))
        self.assertFalse(intent.verify(dict(record,claimed=0),receipt))
        self.assertFalse(intent.verify(record,b'forged'))
        with self.assertRaises(StoreError):intent.reserve('900000',self.plan['book_id'],'b'*32,'b'*64)


if __name__=='__main__':unittest.main()
