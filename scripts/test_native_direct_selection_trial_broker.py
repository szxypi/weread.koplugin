import unittest
from unittest.mock import Mock,patch

from native_direct_selection_trial_broker import execute
from secure_selection_trial import SelectionTrialStore
from test_secure_native_session import Backend
from test_selection_trial import fixture


class DirectSelectionBrokerTests(unittest.TestCase):
    def setup_trial(self):
        payload,plan=fixture();probe=Mock();probe.payload=payload;probe.plan=plan;probe.cleanup_posts=0
        store=SelectionTrialStore(Backend());receipt=store.prepare(plan.bound)
        source=dict(book_id=plan.bound['book_id'],uid=plan.bound['chapter_uid'],book_version=1,
            source_sha256=payload['source_raw_sha256'])
        child=Mock();child.poll.return_value=0
        return probe,store,receipt,source,child
    def run_frames(self,events,probe,store,receipt,source,child,report,armed=True,on_final=None):
        frames=Mock();frames.next.side_effect=events
        with patch('native_direct_selection_trial_broker.subprocess.Popen',return_value=child), \
             patch('native_direct_selection_trial_broker.Frames',return_value=frames), \
             patch('native_direct_selection_trial_broker.write_initial'), \
             patch('native_direct_selection_trial_broker.reply'),patch('native_direct_selection_trial_broker.stop'):
            execute(probe,{'vid':'900000'},store,receipt,['fake-runner'],source=source,armed=armed,report=report,on_final=on_final)
    def test_wrong_create_body_stops_with_durable_pending_intent(self):
        probe,store,receipt,source,child=self.setup_trial();report={}
        with self.assertRaises(ValueError):
            self.run_frames([('STEP',{'kind':'claim','seq':1,'body':{'bookId':'unrelated'}})],probe,store,receipt,source,child,report)
        self.assertEqual(store.read()[0]['phase'],'pending');self.assertEqual(store.read()[0]['reserved_posts'],4)
        self.assertEqual(report['claims'],0);self.assertTrue(report['no_automatic_replay'])
        with self.assertRaises(ValueError):
            self.run_frames([],probe,store,store.read()[1],source,child,{},True)
    def test_original_thought_id_cannot_be_accepted_as_new(self):
        probe,store,receipt,source,child=self.setup_trial();report={}
        body=probe.payload['selection_preview']['body']
        events=[('STEP',{'kind':'claim','seq':1,'body':body}),('STEP',{'kind':'verified','seq':1,'created_id':'original'})]
        with self.assertRaises(ValueError):self.run_frames(events,probe,store,receipt,source,child,report)
        self.assertEqual(store.read()[0]['native_steps'],0);self.assertEqual(report['claims'],1)
        probe.read_step.assert_not_called()
    def test_final_session_save_failure_keeps_pending_after_three_writes(self):
        probe,store,receipt,source,child=self.setup_trial();report={};child.wait.return_value=0
        probe.read_step.return_value=None
        probe.cleanup.side_effect=lambda _credentials,owner,r:owner.verified_cleanup(r)
        body=probe.payload['selection_preview']['body'];edited=__import__('annotation_experiment_model').note_text(probe.plan.bound['nonce'],True)
        events=[]
        for seq,request in ((1,body),(2,{'reviewId':'new-note','content':edited}),(3,{'reviewId':'new-note'})):
            events.extend([('STEP',{'kind':'claim','seq':seq,'body':request}),('STEP',{'kind':'verified','seq':seq,'created_id':'new-note'})])
        events.append(('RESULT',{'result':'PASS','profile_removed':True,'credential_file_audit':True,'installed_bytes_match':True,
            'steps':3,'posts':3,'blocked':False}))
        with self.assertRaises(RuntimeError):
            self.run_frames(events,probe,store,receipt,source,child,report,on_final=Mock(side_effect=RuntimeError('save failed')))
        self.assertEqual(store.read()[0]['phase'],'pending');self.assertEqual(store.read()[0]['native_steps'],3)
        self.assertEqual(report['account_data_posts_upper_bound'],3)

    def test_source_mismatch_fails_before_reservation(self):
        probe,store,receipt,source,child=self.setup_trial();source['source_sha256']='0'*64
        with self.assertRaises(ValueError):self.run_frames([],probe,store,receipt,source,child,{})
        self.assertEqual(store.read()[0]['phase'],'prepared')


if __name__=='__main__':unittest.main()
