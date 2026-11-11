"""Synthetic three-write protocol, durable phases and redaction; no network."""
from contextlib import redirect_stdout,redirect_stderr
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from annotation_experiment_model import bind,context,digest,fingerprint,note_text,expected_new,validate_plan
from secure_annotation_experiment import AnnotationExperimentStore,Receipt
from secure_weread_session import StoreError
from test_secure_native_session import Backend,credentials
from test_eink_login import Opener
from verify_annotation_experiment import AnnotationProbe,BASE,main


def shelf():return dict(books=[dict(bookId='41',title='Private title',finishReading=0,secret=0)])
def notebooks():return dict(books=[dict(bookId='41',reviewCount=1)])
def position(offset=100):return dict(book=dict(bookId='41',chapterUid=2,chapterIdx=2,chapterOffset=offset,progress=37.5))
def marks():return dict(bookId='41',updated=[dict(bookmarkId='synthetic-mark',bookId='41',type=1,chapterUid=2,chapterIdx=2,
                                              markText='Private quote',range='12-25')],chapters=[dict(chapterUid=2,title='Private chapter')])
def info():return dict(bookId='41',version=77)
def note(identity,content,private=1):
    return dict(reviewId=identity,review=dict(reviewId=identity,bookId='41',userVid=900000,type=1,chapterUid=2,chapterIdx=2,
                abstract='Private quote',range='12-25',content=content,isPrivate=private,createTime=1000))
def thoughts(new=None):
    return dict(totalCount=1+(new is not None),hasMore=0,reviews=[note('existing-note','Private original thought')]+([new] if new else []))
def observation(new=None,offset=100):return [shelf(),thoughts(new),marks(),position(offset)]
def preparation():return [shelf(),notebooks(),*observation(),marks(),info(),*observation()]


class AnnotationTests(unittest.TestCase):
    def fixture(self,tail=()):
        opener=Opener([*preparation(),*tail]);probe=AnnotationProbe(opener,sleep=lambda _delay:None)
        with patch('verify_annotation_experiment.secrets.token_hex',return_value='a'*32):plan=probe.prepare(credentials())
        store=AnnotationExperimentStore(Backend());receipt=store.prepare(plan.bound)
        return probe,opener,plan,store,receipt

    def complete_tail(self,create_ack=None,edit_ack=None,delete_ack=None):
        created=note('new-test',note_text('a'*32));edited=note('new-test',note_text('a'*32,True))
        return [*observation(),create_ack if create_ack is not None else dict(reviewId='new-test'),*observation(created),
                *observation(created),edit_ack if edit_ack is not None else dict(succ=1),*observation(edited),
                *observation(edited),delete_ack if delete_ack is not None else dict(succ=1),*observation(),*observation()]

    def test_create_edit_delete_uses_only_the_new_private_target(self):
        probe,opener,plan,store,receipt=self.fixture(self.complete_tail())
        probe.run(credentials(),plan,store,receipt,confirmed=True)
        posts=[request for request in opener.requests if request.get_method()=='POST']
        self.assertEqual([p.full_url for p in posts],[BASE+'/review/add',BASE+'/review/useredit',BASE+'/review/delete'])
        bodies=[json.loads(p.data) for p in posts]
        self.assertEqual(bodies[0],dict(plan.context,content=note_text('a'*32)))
        self.assertEqual(bodies[1],dict(reviewId='new-test',content=note_text('a'*32,True)))
        self.assertEqual(bodies[2],dict(reviewId='new-test'))
        self.assertTrue(all('existing-note' not in json.dumps(body) for body in bodies))
        self.assertEqual(probe.report['data_writes_attempted'],3);self.assertFalse(store.pending())
        self.assertEqual(len(probe.report['steps_verified']),3)
        self.assertTrue(all(r.get_header('Cookie') is None and r.get_header('Authorization') is None for r in opener.requests))
        self.assertTrue(all(r.get_header('Vid')=='900000' and r.get_header('Accesstoken')==credentials()['accessToken'] for r in opener.requests))
        public=json.dumps(probe.report)
        for private in ['existing-note','new-test','Private title','Private quote','Private original thought',credentials()['accessToken']]:self.assertNotIn(private,public)
        before=len(opener.requests)
        with self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
        self.assertEqual(len(opener.requests),before)

    def test_missing_or_lost_ack_never_replays_but_independent_reads_can_confirm(self):
        probe,opener,plan,store,receipt=self.fixture(self.complete_tail(create_ack={},edit_ack=TimeoutError(),delete_ack=TimeoutError()))
        probe.run(credentials(),plan,store,receipt,confirmed=True)
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),3);self.assertFalse(store.pending())
        self.assertEqual(sum(row.get('unrecognized_or_lost',False) for row in probe.report['receipt_shapes']),2)

    def test_unconfirmed_owner_or_changed_plan_cannot_dispatch(self):
        for mode in ['unconfirmed','owner','plan','context','baseline']:
            probe,opener,plan,store,receipt=self.fixture();grant=credentials()
            if mode=='owner':grant['vid']='900099'
            elif mode=='plan':plan.bound['position_sha256']='b'*64
            elif mode=='context':plan.context['isPrivate']=0
            elif mode=='baseline':plan.baseline['thoughts'].clear()
            with self.subTest(mode=mode),self.assertRaises(ValueError):probe.run(grant,plan,store,receipt,confirmed=mode!='unconfirmed')
            self.assertFalse(any(r.get_method()=='POST' for r in opener.requests))
            self.assertEqual(store.read()[0]['phase'],'prepared')

    def test_original_data_or_position_change_aborts_before_any_write(self):
        for kind in ['note','mark','position','shelf']:
            before=observation()
            if kind=='note':before[1]['reviews'][0]['review']['content']='External edit'
            elif kind=='mark':before[2]['updated'][0]['markText']='External edit'
            elif kind=='position':before[3]=position(101)
            else:before[0]['books'][0]['secret']=1
            probe,opener,plan,store,receipt=self.fixture(before)
            with self.subTest(kind=kind),self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
            self.assertEqual(probe.report['data_writes_attempted'],0);self.assertEqual(store.read()[0]['phase'],'prepared')

    def test_unconfirmed_creation_retains_one_consumed_lease_and_blocks_new_apply(self):
        probe,opener,plan,store,receipt=self.fixture([*observation(),TimeoutError(),*observation(),*observation(),*observation()])
        with self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
        self.assertEqual(store.read()[0]['phase'],'create_pending');self.assertEqual(store.read()[0]['posts'],1)
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)
        with self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1)

    def test_nonprivate_foreign_or_unexpected_new_record_stops_after_create(self):
        for mode in ['public','other_text','other_id_duplicate','old_note_changed']:
            new=note('new-test',note_text('a'*32));after=observation(new)
            if mode=='public':new['review']['isPrivate']=0
            elif mode=='other_text':new['review']['content']='External note'
            elif mode=='other_id_duplicate':after[1]['reviews'].append(note('extra-note','External note'));after[1]['totalCount']=3
            else:after[1]['reviews'][0]['review']['content']='Changed original'
            probe,opener,plan,store,receipt=self.fixture([*observation(),dict(succ=1),*after])
            with self.subTest(mode=mode),self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
            self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),1);self.assertEqual(store.read()[0]['phase'],'create_pending')

    def test_readback_convergence_does_not_duplicate_posts(self):
        tail=self.complete_tail();tail[5:5]=observation() # first create read returns the old list
        probe,opener,plan,store,receipt=self.fixture(tail)
        probe.run(credentials(),plan,store,receipt,confirmed=True)
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),3)

    def test_edit_failure_retains_created_target_and_never_deletes_it(self):
        created=note('new-test',note_text('a'*32))
        tail=[*observation(),{},*observation(created),*observation(created),TimeoutError(),*observation(created),*observation(created),*observation(created)]
        probe,opener,plan,store,receipt=self.fixture(tail)
        with self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
        state,_raw=store.read();self.assertEqual(state['phase'],'edit_pending');self.assertEqual(state['created_id'],'new-test')
        self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),2)

    def test_delete_failure_and_final_mismatch_keep_durable_marker(self):
        for final in [False,True]:
            tail=self.complete_tail();edited=note('new-test',note_text('a'*32,True))
            if not final:tail=tail[:-8]+[*observation(edited),*observation(edited),*observation(edited)]
            else:tail[-1]=position(101)
            probe,opener,plan,store,receipt=self.fixture(tail)
            with self.assertRaises(ValueError):probe.run(credentials(),plan,store,receipt,confirmed=True)
            self.assertEqual(sum(r.get_method()=='POST' for r in opener.requests),3)
            self.assertEqual(store.read()[0]['phase'],'deleted' if final else 'delete_pending')

    def test_request_guard_refuses_even_forged_dispatch_for_unrelated_url(self):
        probe,opener,plan,store,receipt=self.fixture()
        probe.store=store;probe.receipt=store.advance(receipt,'prepared','create_pending');probe.confirmed=True
        body=dict(bookIds=['41']);probe.dispatch=('evil',BASE+'/shelf/delete',digest(body),'create_pending')
        with self.assertRaises(ValueError):probe.request('evil',BASE+'/shelf/delete',body,credentials())
        self.assertEqual(probe.report['data_writes_attempted'],0)
        with self.assertRaises(ValueError):probe.request('blocked',BASE+'/login',{},credentials())

    def test_stores_are_separate_and_phases_survive_reopen_without_replay(self):
        probe,_opener,plan,store,receipt=self.fixture();backend=store.backend
        with self.assertRaises(StoreError):store.prepare(plan.bound)
        with self.assertRaises(StoreError):store.finish(receipt)
        pending=store.advance(receipt,'prepared','create_pending');reopened=AnnotationExperimentStore(backend)
        self.assertEqual(reopened.read()[0]['phase'],'create_pending')
        self.assertFalse(reopened.owns(receipt));self.assertTrue(reopened.owns(pending))
        with self.assertRaises(StoreError):reopened.advance(pending,'prepared','create_pending')
        with self.assertRaises(StoreError):reopened.finish(pending,discard_prepared=True)
        self.assertNotIn(plan.bound['nonce'],repr(pending));self.assertNotIn('book_id',repr(pending));self.assertNotIn('Private',backend.data.decode())

    def test_schema_readback_corruption_and_target_switch_are_rejected(self):
        probe,_opener,plan,store,receipt=self.fixture();original=store.backend.data
        for field,bad in [('schema',True),('posts',1),('maximum_posts',4),('scope','foreign'),('phase','unknown'),('created_id','existing-note')]:
            value=json.loads(original);value[field]=bad;store.backend.data=json.dumps(value).encode()
            with self.subTest(field=field),self.assertRaises(StoreError):store.pending()
        store.backend.data=original;store.finish(receipt,discard_prepared=True);self.assertFalse(store.pending())
        backend=Backend();backend.load=lambda:None
        with self.assertRaises(StoreError):AnnotationExperimentStore(backend).prepare(plan.bound)
        for field,bad in [('review_count',True),('nonce','bad'),('protocol','old'),('context_sha256','bad')]:
            with self.assertRaises(ValueError):validate_plan(dict(plan.bound,**{field:bad}))

    def test_prepared_cli_is_local_only_and_apply_binds_the_saved_scope(self):
        backend=Backend();store=AnnotationExperimentStore(backend)
        prepare_opener=Opener(preparation());prepare_probe=AnnotationProbe(prepare_opener,sleep=lambda _delay:None)
        credential=credentials()
        with patch('verify_annotation_experiment.SessionStore') as web,patch('verify_annotation_experiment.NativeSessionStore') as native,\
                patch('verify_annotation_experiment.AnnotationExperimentStore',return_value=store),\
                patch('verify_annotation_experiment.FinishExperimentStore') as other1,patch('verify_annotation_experiment.ShelfExperimentStore') as other2,\
                patch('verify_annotation_experiment.PositionExperimentStore') as other3,\
                patch('verify_annotation_experiment.AnnotationProbe',return_value=prepare_probe),\
                patch('verify_annotation_experiment.secrets.token_hex',return_value='a'*32),redirect_stdout(io.StringIO()) as output:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=credential
            for item in (other1,other2,other3):item.return_value.pending.return_value=False
            self.assertEqual(main(['--saved-session','--prepare']),0)
        report=json.loads(output.getvalue());self.assertEqual(report['intent_state'],'prepared');self.assertEqual(credential,{})
        self.assertTrue(all(r.get_method()=='GET' for r in prepare_opener.requests))
        state,_receipt=store.read();expected=fingerprint(state['plan']);self.assertEqual(report['intent_fingerprint'],expected)
        existing_prepare=[shelf(),*observation(),marks(),info(),*observation()]
        opener=Opener([*existing_prepare,*self.complete_tail()]);probe=AnnotationProbe(opener,sleep=lambda _delay:None)
        with patch('verify_annotation_experiment.SessionStore') as web,patch('verify_annotation_experiment.NativeSessionStore') as native,\
                patch('verify_annotation_experiment.AnnotationExperimentStore',return_value=store),\
                patch('verify_annotation_experiment.FinishExperimentStore') as other1,patch('verify_annotation_experiment.ShelfExperimentStore') as other2,\
                patch('verify_annotation_experiment.PositionExperimentStore') as other3,\
                patch('verify_annotation_experiment.AnnotationProbe',return_value=probe),redirect_stdout(io.StringIO()) as output:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=credentials()
            for item in (other1,other2,other3):item.return_value.pending.return_value=False
            self.assertEqual(main(['--saved-session','--apply','--expected-intent',expected]),0)
        self.assertFalse(store.pending());self.assertEqual(json.loads(output.getvalue())['intent_state'],'cleared')
        for private in ['Private quote','Private original thought','new-test','existing-note','900000']:
            self.assertNotIn(private,output.getvalue())

    def test_pending_check_never_writes_and_rejects_a_foreign_owner_before_http(self):
        probe,_opener,plan,store,receipt=self.fixture()
        store.advance(receipt,'prepared','create_pending')
        for owner in ['900000','900099']:
            opener=Opener(observation());read_probe=AnnotationProbe(opener,sleep=lambda _delay:None)
            with patch('verify_annotation_experiment.SessionStore') as web,patch('verify_annotation_experiment.NativeSessionStore') as native,\
                    patch('verify_annotation_experiment.AnnotationExperimentStore',return_value=store),\
                    patch('verify_annotation_experiment.AnnotationProbe',return_value=read_probe),redirect_stdout(io.StringIO()) as output:
                web.return_value.load.return_value=dict(vid=owner);native.return_value.load.return_value=dict(credentials(),vid=owner)
                self.assertEqual(main(['--saved-session','--check-pending']),0 if owner=='900000' else 1)
            self.assertTrue(all(r.get_method()=='GET' for r in opener.requests))
            if owner!='900000':self.assertEqual(len(opener.requests),0)
            self.assertEqual(store.read()[0]['phase'],'create_pending')

    def test_default_and_invalid_flags_never_open_credentials_or_intents(self):
        with patch('verify_annotation_experiment.SessionStore') as web,patch('verify_annotation_experiment.NativeSessionStore') as native,\
                patch('verify_annotation_experiment.AnnotationExperimentStore') as intents,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0)
        web.assert_not_called();native.assert_not_called();intents.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
        for args in [['--apply'],['--saved-session','--apply'],['--expected-intent','a'*64],['--prepare'],['--saved-session','--apply','--prepare']]:
            with self.subTest(args=args),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)


if __name__=='__main__':unittest.main()
