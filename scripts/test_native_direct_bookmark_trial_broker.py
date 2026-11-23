import unittest
from unittest.mock import Mock,patch

from native_direct_highlight_trial_broker import execute
from secure_bookmark_trial import BookmarkTrialStore
from test_secure_native_session import Backend
from test_selection_trial import fixture


class DirectBookmarkBrokerTests(unittest.TestCase):
    def setup_trial(self):
        payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.baseline.return_value=plan.baseline
        probe=Mock();probe.source=source;probe.body=dict(bookId=plan.context['bookId'],chapterUid=int(plan.context['chapterUid']),
            bookVersion=plan.context['bookVersion'],type=0,style=0,range='15',markText='Synthetic bookmark preview')
        probe.target=None;store=BookmarkTrialStore(Backend(),native=True)
        native=dict(book_id=plan.bound['book_id'],uid=plan.bound['chapter_uid'],book_version=1,source_sha256=payload['source_raw_sha256'])
        child=Mock();child.poll.return_value=0
        return probe,store,native,child

    def run_frames(self,events,probe,store,source,child,report):
        frames=Mock();frames.next.side_effect=events
        with patch('native_direct_highlight_trial_broker.subprocess.Popen',return_value=child), \
             patch('native_direct_highlight_trial_broker.Frames',return_value=frames), \
             patch('native_direct_highlight_trial_broker.write_initial'), \
             patch('native_direct_highlight_trial_broker.reply'),patch('native_direct_highlight_trial_broker.stop'):
            execute(probe,{'vid':'900000'},store,['fake'],source=source,armed=True,report=report,bookmark=True)

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
        self.assertEqual(store.read()[0]['phase'],'create_pending');probe.read.assert_not_called()

    def test_unconfirmed_deletion_is_not_replayed(self):
        probe,store,source,child=self.setup_trial();report={};target={'id':'new-bookmark','sha256':'a'*64}
        probe.read.side_effect=[(target,{}),(target,{}),(target,{}),ValueError('unconfirmed')]
        events=[('STEP',{'kind':'claim','seq':1,'body':probe.body}),('STEP',{'kind':'verified','seq':1,'created_id':'new-bookmark'}),
            ('STEP',{'kind':'claim','seq':2,'body':{'bookmarkIds':['new-bookmark']}}),('STEP',{'kind':'verified','seq':2,'created_id':'new-bookmark'})]
        with self.assertRaises(ValueError):self.run_frames(events,probe,store,source,child,report)
        self.assertEqual(store.read()[0]['phase'],'delete_pending');self.assertEqual(report['account_data_posts_upper_bound'],2)


if __name__=='__main__':unittest.main()
