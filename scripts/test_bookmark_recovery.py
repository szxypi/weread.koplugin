"""Reconstruct one pending point and consume only its unused deletion slot."""
from copy import deepcopy
import unittest
from unittest.mock import patch
import test_bookmark_trial as fixtures
from bookmark_trial_model import observe
from bookmark_trial_recovery import isolate_added,resume_delete
from bookmark_trial_recovery import reconcile_deleted,finish_reconcile
from annotation_experiment_model import digest


class BookmarkRecoveryTests(unittest.TestCase):
    def fixture(self):return fixtures.BookmarkTrialTests().fixture()

    def test_isolation_requires_exact_original_hashes(self):
        _p,_source,_store,plan,added=self.fixture()
        target,original=isolate_added(added['marks'],plan.bound)
        self.assertEqual(target['id'],'new-bookmark');self.assertEqual(original,plan.baseline['marks'])
        for change in ('original','extra','type','descriptor'):
            bad=deepcopy(added['marks'])
            if change=='original':bad['updated']['old-mark']['markText']='changed'
            elif change=='extra':bad['updated']['another']=dict(bad['updated']['new-bookmark'],bookmarkId='another')
            elif change=='type':bad['updated']['new-bookmark']['type']=1
            else:bad['chapters']['99']=dict(chapterUid=99,title='Other new chapter')
            with self.subTest(change=change),self.assertRaises(ValueError):isolate_added(bad,plan.bound)

    def test_resume_uses_only_remaining_deletion_once(self):
        p,source,store,plan,added=self.fixture();p.receipt=store.reserve(p.bound);p.posts=1;p.target=observe(plan.baseline,added,p.body)
        source.notes.observe.side_effect=[added,plan.baseline]
        with patch('verify_owner_reading.reading_position',return_value=plan.web_position):result=resume_delete(p,{})
        self.assertEqual(result['account_data_posts'],1);self.assertFalse(result['create_replayed']);self.assertEqual(store.read(),(None,None))
        self.assertEqual(source.writer.request.call_count,1)
        self.assertEqual(source.writer.request.call_args.args[1],'https://i.weread.qq.com/book/removeBookmark')
        with self.assertRaises(ValueError):resume_delete(p,{})

    def test_changed_new_target_never_dispatches_remaining_delete(self):
        p,source,store,plan,added=self.fixture();p.receipt=store.reserve(p.bound);p.posts=1;p.target=observe(plan.baseline,added,p.body)
        added['marks']['updated']['new-bookmark']['createTime']=9;source.notes.observe.return_value=added
        with self.assertRaises(ValueError):resume_delete(p,{})
        source.writer.request.assert_not_called();self.assertEqual(store.read()[0]['phase'],'created')

    def test_ambiguous_delete_stays_pending_and_cannot_be_sent_again(self):
        p,source,store,plan,added=self.fixture();p.receipt=store.reserve(p.bound);p.posts=1;p.target=observe(plan.baseline,added,p.body)
        source.notes.observe.return_value=added
        with self.assertRaises(ValueError):resume_delete(p,{})
        self.assertEqual(source.writer.request.call_count,1);self.assertEqual(store.read()[0]['phase'],'delete_pending')
        with self.assertRaises(ValueError):resume_delete(p,{})
        self.assertEqual(source.writer.request.call_count,1)

    def pending_delete(self):
        p,source,store,plan,added=self.fixture();receipt=store.reserve(p.bound)
        target=observe(plan.baseline,added,p.body);receipt=store.advance(receipt,'created',target=target);store.advance(receipt,'delete_pending')
        source.notes.observe.return_value=plan.baseline
        return p,source,store,plan

    def test_ambiguous_deletion_can_be_cleared_readonly_after_exact_restoration(self):
        p,source,store,plan=self.pending_delete();identity=dict(vid=plan.bound['owner'])
        with patch('bookmark_trial_recovery.decode_content_shards',return_value=p.raw):
            recovered=reconcile_deleted(identity,identity,store,digest(store.read()[0]['plan']),source)
        with patch('verify_owner_reading.reading_position',return_value=plan.web_position):result=finish_reconcile(recovered,identity)
        self.assertEqual(result['account_data_posts'],0);self.assertFalse(result['delete_replayed']);self.assertEqual(store.read(),(None,None))
        source.writer.request.assert_not_called()

    def test_reconcile_refuses_wrong_intent_and_moved_web_position(self):
        p,source,store,plan=self.pending_delete();identity=dict(vid=plan.bound['owner'])
        with self.assertRaises(ValueError):reconcile_deleted(identity,identity,store,'0'*64,source)
        with patch('bookmark_trial_recovery.decode_content_shards',return_value=p.raw):
            recovered=reconcile_deleted(identity,identity,store,digest(store.read()[0]['plan']),source)
        with patch('verify_owner_reading.reading_position',return_value={'changed':True}),self.assertRaises(ValueError):finish_reconcile(recovered,identity)
        self.assertEqual(store.read()[0]['phase'],'delete_pending');source.writer.request.assert_not_called()


if __name__=='__main__':unittest.main()
