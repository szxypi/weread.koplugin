import unittest
from unittest.mock import Mock,patch

from highlight_trial_model import request
from native_direct_highlight_trial_broker import execute
from secure_highlight_trial import HighlightTrialStore
from test_secure_native_session import Backend
from test_selection_trial import fixture


class DirectHighlightBrokerTests(unittest.TestCase):
    def setup_trial(self):
        payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.baseline.return_value=plan.baseline
        probe=Mock();probe.source=source;probe.body=request(plan.context);probe.target=None
        store=HighlightTrialStore(Backend(),native=True)
        native=dict(book_id=plan.bound['book_id'],uid=plan.bound['chapter_uid'],book_version=1,source_sha256=payload['source_raw_sha256'])
        child=Mock();child.poll.return_value=0
        return probe,store,native,child
    def run_frames(self,events,probe,store,source,child,report,armed=True):
        frames=Mock();frames.next.side_effect=events
        with patch('native_direct_highlight_trial_broker.subprocess.Popen',return_value=child), \
             patch('native_direct_highlight_trial_broker.Frames',return_value=frames), \
             patch('native_direct_highlight_trial_broker.write_initial'), \
             patch('native_direct_highlight_trial_broker.reply'),patch('native_direct_highlight_trial_broker.stop'):
            execute(probe,{'vid':'900000'},store,['fake'],source=source,armed=armed,report=report)
    def test_wrong_body_keeps_pending_and_blocks_replay(self):
        probe,store,source,child=self.setup_trial();report={}
        with self.assertRaises(ValueError):
            self.run_frames([('STEP',{'kind':'claim','seq':1,'body':{'bookId':'other'}})],probe,store,source,child,report)
        self.assertEqual(store.read()[0]['phase'],'create_pending');self.assertEqual(report['claims'],0)
        with self.assertRaises(ValueError):self.run_frames([],probe,store,source,child,{})
    def test_original_mark_cannot_be_selected_for_removal(self):
        probe,store,source,child=self.setup_trial();report={}
        events=[('STEP',{'kind':'claim','seq':1,'body':probe.body}),('STEP',{'kind':'verified','seq':1,'created_id':'old-mark'})]
        with self.assertRaises(ValueError):self.run_frames(events,probe,store,source,child,report)
        self.assertEqual(store.read()[0]['phase'],'create_pending');self.assertEqual(report['claims'],1)
        probe.read.assert_not_called()
    def test_source_mismatch_rejected_before_reservation(self):
        probe,store,source,child=self.setup_trial();source['source_sha256']='0'*64
        with self.assertRaises(ValueError):self.run_frames([],probe,store,source,child,{})
        self.assertEqual(store.read(),(None,None))
    def test_unconfirmed_deletion_stays_pending(self):
        probe,store,source,child=self.setup_trial();report={}
        target={'id':'new-mark','sha256':'a'*64};probe.read.side_effect=[(target,{}),(target,{}),(target,{}),ValueError('no independent confirmation')]
        events=[('STEP',{'kind':'claim','seq':1,'body':probe.body}),('STEP',{'kind':'verified','seq':1,'created_id':'new-mark'}),
            ('STEP',{'kind':'claim','seq':2,'body':{'bookmarkIds':['new-mark']}}),('STEP',{'kind':'verified','seq':2,'created_id':'new-mark'})]
        with self.assertRaises(ValueError):self.run_frames(events,probe,store,source,child,report)
        self.assertEqual(store.read()[0]['phase'],'delete_pending');self.assertEqual(report['account_data_posts_upper_bound'],2)


if __name__=='__main__':unittest.main()
