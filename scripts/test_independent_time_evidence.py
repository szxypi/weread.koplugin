"""The newer capture has private, read-only and non-interchangeable proof."""
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_evidence import IndependentCaptureEvidence,FreshShelfEvidence,PreflightEvidence
from test_native_time_bundle_evidence import fresh_fixture
import verify_fresh_time_capture_readonly as reader


def fixture():
    bundle,grant,before,_old_report,now,pairs,shelves,_old=fresh_fixture()
    report=dict(result='CROSS_DAY_READONLY_VERIFIED',seconds=bundle['plan']['seconds'],completed_at=now,
                captured_native_baseline_matches=True,both_current_shelves_stable=True,two_statistics_reads_stable=True,
                saved_capture_unchanged=True,observed_months=len(before['months']),account_data_posts=0,
                authentication_posts=0,historical_accounting_verified=False,dispatch_capability=False,
                captured_web_shelf_comparable=False)
    return bundle,grant,before,report,now,pairs,shelves


class IndependentEvidenceTests(unittest.TestCase):
    def test_evidence_is_private_defensive_and_not_accepted_as_old_evidence(self):
        bundle,grant,before,report,_now,pairs,shelves=fixture()
        proof=IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves)
        self.assertNotIn(bundle['plan']['book_id'],repr(proof))
        self.assertNotIsInstance(proof,PreflightEvidence);self.assertNotIsInstance(proof,FreshShelfEvidence)
        result=proof.for_bundle(bundle,grant)
        self.assertEqual(result[0],report);self.assertEqual(result[1],before['snapshot'])
        result[1]['point']['chapter_offset']+=1
        self.assertEqual(proof.for_bundle(bundle,grant)[1],before['snapshot'])
        for key in ('send','request','claim','dispatch'):
            self.assertFalse(hasattr(proof,key))
        changed=deepcopy(grant);changed['accessToken']='other-synthetic'
        with self.assertRaises(ValueError):proof.for_bundle(bundle,changed)
        changed=deepcopy(bundle);changed['plan']['seconds']+=1
        with self.assertRaises(ValueError):proof.for_bundle(changed,grant)
        proof._value=(report,before,'a'*64,shelves,None)
        with self.assertRaises(ValueError):proof.for_bundle(bundle,grant)

    def test_invalid_report_and_wrong_catalog_are_rejected(self):
        for key,value in [('dispatch_capability',True),('account_data_posts',1),('captured_web_shelf_comparable',True),
                          ('completed_at',True),('observed_months',0),('saved_capture_unchanged',False)]:
            bundle,grant,before,report,_now,pairs,shelves=fixture();report[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves)
        bundle,grant,before,report,_now,pairs,shelves=fixture()
        pairs[1][1][0]['updated'][0]['chapterIdx']+=1
        with self.assertRaises(ValueError):
            IndependentCaptureEvidence(bundle,grant,report,before['snapshot'],before['months'],pairs,shelves)

    def test_real_reader_flow_delivers_only_in_memory_proof(self):
        bundle,grant,before,_report,now,pairs,_shelves=fixture();plan=bundle['plan']
        saved={'vid':plan['owner'],'cookies':{'wr_vid':plan['owner'],'wr_skey':'synthetic'}}
        session=Mock();session.load.side_effect=lambda:deepcopy(saved)
        native=Mock();native.load.side_effect=lambda _vid:deepcopy(grant)
        store=Mock();token=object();store.read.return_value=(bundle,token)
        shelf={'books':[{'bookId':plan['book_id'],'title':'Synthetic'}],'archive':[]}
        web=Mock();web.vid=plan['owner'];web.book_id=plan['book_id'];web.chapter=plan['chapter_uid'];web.shards={}
        web._time_catalog_pair=deepcopy(pairs[0]);web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True}
        web.request.return_value=shelf
        api=Mock();api.request.return_value=shelf
        statistics=Mock();statistics.request.return_value={}
        months=list(before['months'].values())
        with patch.object(reader,'xhtml_snapshot',return_value=before['snapshot']), \
             patch.object(reader,'statistics_projection',side_effect=months*2), \
             patch.object(reader,'save_refreshed_web_session'):
            proof=reader.run(store,session,native,clock=lambda:now,sleep=lambda _:None,
                             web_factory=lambda _book:web,api_factory=lambda *_:api,
                             statistics_factory=lambda:statistics,private_evidence=True)
        self.assertIsInstance(proof,IndependentCaptureEvidence)
        self.assertEqual(proof.for_bundle(bundle,grant)[1],before['snapshot'])
        self.assertEqual(web._time_catalog_pair,[])
        self.assertFalse(proof.for_bundle(bundle,grant)[0]['dispatch_capability'])

    def test_rejected_private_evidence_cannot_report_a_successful_preflight(self):
        bundle,grant,before,_report,now,pairs,_shelves=fixture();plan=bundle['plan']
        saved={'vid':plan['owner'],'cookies':{'wr_vid':plan['owner'],'wr_skey':'synthetic'}}
        session=Mock();session.load.side_effect=lambda:deepcopy(saved)
        native=Mock();native.load.side_effect=lambda _vid:deepcopy(grant)
        store=Mock();store.read.return_value=(bundle,object())
        shelf={'books':[{'bookId':plan['book_id']}],'archive':[]}
        web=Mock();web.book_id=plan['book_id'];web.chapter=plan['chapter_uid'];web.shards={}
        web._time_catalog_pair=deepcopy(pairs[0]);web._time_catalog_pair[1][0]['updated'][0]['chapterIdx']+=1
        web.inspect.return_value={'cloud_position_stable':True,'catalog_stable':True};web.request.return_value=shelf
        api=Mock();api.request.return_value=shelf
        with patch.object(reader,'xhtml_snapshot',return_value=before['snapshot']), \
             patch.object(reader,'statistics_projection',side_effect=list(before['months'].values())*2), \
             patch.object(reader,'save_refreshed_web_session'):
            value=reader.run(store,session,native,clock=lambda:now,sleep=lambda _:None,
                             web_factory=lambda _book:web,api_factory=lambda *_:api,
                             statistics_factory=Mock,private_evidence=True)
        self.assertIsInstance(value,dict);self.assertEqual(value['result'],'UNVERIFIED')
        self.assertFalse(value['dispatch_capability'])
        self.assertEqual(web._time_catalog_pair,[])


if __name__=='__main__':unittest.main()
