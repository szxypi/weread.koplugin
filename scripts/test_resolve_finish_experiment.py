"""Offline single-restoration boundaries; never uses real credentials/network."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
import unittest
from unittest.mock import patch

from resolve_finish_experiment import ResolveProbe,main,observation,receipt_shape
from secure_finish_experiment import FinishExperimentStore,Receipt
from secure_weread_session import StoreError
from test_eink_login import Opener
from test_finish_roundtrip import shelf,position,bound
from test_secure_native_session import Backend,credentials
from verify_eink_login import BASE
from verify_finish_roundtrip import FinishError,shelf_flags,point


class RestorationTests(unittest.TestCase):
    def fixture(self,responses):
        store=FinishExperimentStore(Backend());receipt=store.begin(bound());opener=Opener(responses)
        probe=ResolveProbe(credentials(),bound(),opener,sleep=lambda _seconds:None)
        return probe,opener,store,receipt

    def test_only_cancel_body_once_and_independent_final_permit_cleanup(self):
        probe,opener,store,receipt=self.fixture([shelf(True),position(),dict(status=0,finishedDate=0),shelf(),position(),shelf(),position()])
        latest,after=probe.restore(credentials(),store,receipt)
        self.assertTrue(after['original_flags_restored'] and after['position_unchanged'])
        self.assertFalse(probe.report['acknowledgement_recognized'])
        self.assertEqual(probe.report['receipt_shape']['status_enum'],'0')
        posts=[r for r in opener.requests if r.get_method()=='POST'];self.assertEqual(len(posts),1)
        self.assertEqual(json.loads(posts[0].data),dict(bookId='41',auto=0,finishInfo=0,isCancel=1,status=4))
        self.assertTrue(store.pending());store.finish(latest,restored_verified=True);self.assertFalse(store.pending())

    def test_lost_response_still_needs_full_independent_restoration(self):
        probe,_opener,store,receipt=self.fixture([shelf(True),position(),TimeoutError('private'),shelf(),position(),shelf(),position()])
        latest,after=probe.restore(credentials(),store,receipt)
        self.assertTrue(after['original_flags_restored']);store.finish(latest,restored_verified=True)
        self.assertEqual(probe.report['data_writes_attempted'],1)

    def test_unknown_restoration_survives_fresh_service_and_never_replays(self):
        probe,opener,store,receipt=self.fixture([shelf(True),position(),TimeoutError(),*([shelf(True),position()]*3)])
        with self.assertRaises(FinishError):probe.restore(credentials(),store,receipt)
        value,raw=store._load();self.assertIn('restore',value)
        with self.assertRaisesRegex(StoreError,'finish_restore_unconfirmed'):store.begin_restore(Receipt(raw))
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)

    def test_original_state_already_restored_is_zero_post(self):
        probe,opener,store,receipt=self.fixture([shelf(),position()])
        latest,after=probe.restore(credentials(),store,receipt)
        self.assertEqual(latest,receipt);self.assertTrue(after['original_flags_restored'])
        self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))

    def test_changed_other_state_or_position_stops_before_lease_and_post(self):
        other=shelf(True);other['books'][1]['finishReading']=0
        for books,raw in [(other,position()),(shelf(True),position(101))]:
            probe,opener,store,receipt=self.fixture([books,raw])
            with self.assertRaises(FinishError):probe.restore(credentials(),store,receipt)
            self.assertNotIn('restore',store._load()[0]);self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))

    def test_final_mismatch_keeps_single_restore_marker(self):
        probe,opener,store,receipt=self.fixture([shelf(True),position(),dict(succ=1),shelf(),position(),shelf(True),position()])
        with self.assertRaises(FinishError):probe.restore(credentials(),store,receipt)
        self.assertIn('restore',store._load()[0]);self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)

    def test_missing_target_is_not_mistaken_for_unchanged_members(self):
        flags,_rows=shelf_flags(dict(books=[shelf()['books'][1]]))
        value=observation(flags,point(position(),'41'),bound())
        self.assertFalse(value['target_present'] or value['unrelated_flags_and_members_unchanged'] or value['original_flags_restored'])

    def test_no_finish_or_unrelated_request_or_foreign_grant(self):
        probe,opener,store,receipt=self.fixture([]);probe.lease=lambda:True
        for url,body in [(BASE+'/login',{}),(BASE+'/book/markstatus',dict(bookId='41',auto=0,finishInfo=0,isCancel=0,status=4)),
                         (BASE+'/book/markstatus',dict(bookId='41',auto=0,finishInfo=0,isCancel=True,status=4))]:
            with self.assertRaises(FinishError):probe.request('finish_restore_once',url,body,credentials())
        with self.assertRaises(FinishError):probe.request('read',BASE+'/shelf/sync',credentials=dict(credentials(),accessToken='replaced'))
        self.assertEqual(len(opener.requests),0);self.assertTrue(store.owns(receipt))

    def test_lease_is_exclusive_durable_and_old_receipt_cannot_clear_it(self):
        store=FinishExperimentStore(Backend());old=store.begin(bound());latest=store.begin_restore(old)
        self.assertTrue(store.owns(latest));self.assertFalse(store.owns(old))
        with self.assertRaises(StoreError):store.finish(old,restored_verified=True)
        with self.assertRaises(StoreError):store.begin_restore(latest)
        value,raw=store._load();self.assertEqual(value['restore']['maximum_posts'],1)
        for field,bad in [('maximum_posts',2),('attempt','bad'),('started_at','')]:
            modified=json.loads(raw);modified['restore'][field]=bad;store.backend.data=json.dumps(modified).encode()
            with self.assertRaises(StoreError):store.pending()
        store.backend.data=raw;store.finish(latest,restored_verified=True)

    def test_receipt_shape_does_not_export_response_identifiers_or_dates(self):
        value=receipt_shape(dict(status=0,bookId='private-id',finishedDate=1234567890,unknown='private-token'),'private-id')
        self.assertTrue(value['returned_book_id_matches']);self.assertEqual(value['status_enum'],'0')
        self.assertEqual(receipt_shape(dict(status=7),'private-id')['status_enum'],'7')
        self.assertEqual(receipt_shape(dict(status=1234567890),'private-id')['status_enum'],'other')
        for private in ['private-id','1234567890','private-token']:self.assertNotIn(private,json.dumps(value))

    def test_offline_and_invalid_restore_flags_do_not_open_any_store(self):
        with patch('resolve_finish_experiment.FinishExperimentStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in [['--restore-once'],['--saved-session','--restore-once'],['--expected-intent','a'*64]]:
            with patch('resolve_finish_experiment.FinishExperimentStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)
            store.assert_not_called()


if __name__=='__main__':unittest.main()
