"""Offline four-slot ownership, new-record cleanup, and handshake boundaries."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch

from annotation_experiment_model import digest,note_text
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore,Receipt
from secure_weread_session import StoreError
from selection_trial_model import bind,fingerprint,observe,restored
from selection_trial_probe import Plan,SelectionProbe
from test_owner_selection_preview import payload
from test_owner_reading import stage,COOKIES
from test_secure_native_session import Backend
import verify_selection_trial as task
import run_native_selection_trial as native


def fixture():
    p=payload();p.update(source_text='Synthetic source text in the selected chapter.',source_sample_offset=0,shelf_ids=['41'],shelf_books=1)
    cfg=p['selection_preview'];context={k:v for k,v in cfg['body'].items() if k!='content'}
    baseline=dict(thoughts={'original':dict(reviewId='original',content='Existing private thought')},
        marks=dict(updated={'old-mark':dict(bookmarkId='old-mark',type=1,chapterUid=2,range='1-2',markText='Existing quote')},chapters={}),
        shelf={'41':dict(secret=0)},position=dict(chapter_uid='2',chapter_idx=2,chapter_offset=12,percent=30))
    chapters=[dict(chapterUid=2,chapterIdx=2,title='Synthetic chapter')];point=dict(chapter='2',offset=12,percent=30)
    bound=bind('900000',p,context,baseline,chapters,point,'1'*32)
    return p,Plan(bound,context,baseline,chapters,point)


def changed(plan,step=1,mark=False,chapter=False):
    value=deepcopy(plan.baseline)
    if step!=3:value['thoughts']['new-note']=dict(reviewId='new-note',content=note_text('1'*32,step==2),isPrivate=1,type=1,
        chapterUid=2,range=plan.context['range'],abstract=plan.context['abstract'])
    if mark:value['marks']['updated']['new-mark']=dict(bookmarkId='new-mark',type=1,chapterUid=2,range=plan.context['range'],markText=plan.context['abstract'],style=1)
    if chapter:value['marks']['chapters']['2']='Synthetic chapter'
    return value


def runner(armed):
    basic=stage();addon=dict.fromkeys(native.FLAGS,True)
    addon.update(permit_writes=armed,cache_verified=armed,local_pending_kept=not armed,dispatch_blocked=not armed,steps=3 if armed else 0,
        native_gets=11 if armed else 7,native_posts=3 if armed else 0,blocked_posts=0 if armed else 1,native_denied=0,failed_line=0,phase='complete')
    basic['selection_trial']=addon
    return dict(result='PASS',profile_removed=True,installed_files=236,installed_bytes_match=True,stage=basic,cookies=COOKIES.copy())


class TrialTests(unittest.TestCase):
    def store(self):
        p,plan=fixture();store=SelectionTrialStore(Backend());receipt=store.prepare(plan.bound);return p,plan,store,receipt

    def test_protocol_is_distinct_and_old_receipts_or_plans_cannot_arm(self):
        _p,plan,store,receipt=self.store()
        with self.assertRaises(StoreError):store.claim(__import__('secure_native_thought_trial').Receipt(receipt.raw))
        with self.assertRaises(ValueError):NativeThoughtTrialStore(Backend()).prepare(plan.bound)
        bad=deepcopy(plan.bound);bad['protocol']='private-thought-create-edit-delete-v1'
        with self.assertRaises(ValueError):store.prepare(bad)

    def test_four_slots_reserved_before_native_steps_and_optional_cleanup(self):
        _p,_plan,store,r=self.store();r=store.claim(r)
        self.assertEqual(store.read()[0]['reserved_posts'],4)
        for step in (1,2,3):r=store.native_step(r,step,'new-note',None)
        with self.assertRaises(StoreError):store.complete(r)
        r=store.verified_cleanup(r);r=store.complete(r);store.finish(r);self.assertFalse(store.pending())

    def test_pending_restart_never_reclaims_even_before_a_native_post(self):
        _p,_plan,store,r=self.store();pending=store.claim(r);reopened=SelectionTrialStore(store.backend)
        for action in (lambda:reopened.claim(r),lambda:reopened.claim(pending),lambda:reopened.finish(pending,discard_prepared=True),lambda:reopened.complete(pending)):
            with self.assertRaises(StoreError):action()

    def test_cas_target_and_cleanup_claim_are_single_use(self):
        _p,_plan,store,r=self.store();r=store.claim(r);mark=dict(id='new-mark',sha256='a'*64)
        r=store.native_step(r,1,'new-note',mark)
        for step,target,other in [(1,'new-note',mark),(2,'original',mark),(2,'new-note',dict(mark,sha256='b'*64))]:
            with self.assertRaises(StoreError):store.native_step(r,step,target,other)
        r=store.native_step(r,2,'new-note',mark);r=store.native_step(r,3,'new-note',mark);r=store.claim_cleanup(r)
        with self.assertRaises(StoreError):store.claim_cleanup(r)
        self.assertTrue(store.read()[0]['cleanup_pending'])

    def test_corrupt_or_unreadable_intent_is_never_claimable(self):
        _p,_plan,store,r=self.store();raw=r.raw
        for key,value in [('reserved_posts',4),('native_steps',1),('cleanup_pending',True),('schema',True),('extra','private')]:
            data=json.loads(raw);data[key]=value;store.backend.data=json.dumps(data).encode()
            with self.assertRaises(StoreError):store.read()
        store.backend.data=raw
        with self.assertRaises(StoreError):store.claim(Receipt(raw+b' '))
        store.finish(r,discard_prepared=True)

    def test_independent_model_allows_only_matching_new_note_and_one_mark(self):
        _p,plan=fixture();value=changed(plan,mark=True)
        row,mark=observe(plan.baseline,value,plan.context,'1'*32,'created')
        self.assertEqual(row['reviewId'],'new-note');self.assertEqual(mark['id'],'new-mark')
        self.assertFalse(restored(plan.baseline,changed(plan,3,True),plan.context,'1'*32,'new-note',mark))
        self.assertTrue(restored(plan.baseline,changed(plan,3),plan.context,'1'*32,'new-note',mark))

    def test_original_records_positions_and_unrelated_mark_cannot_change(self):
        _p,plan=fixture()
        for kind in ('thought','mark','position','private','range','extra'):
            value=changed(plan,mark=True)
            if kind=='thought':value['thoughts']['original']['content']='changed'
            elif kind=='mark':value['marks']['updated']['old-mark']['style']=2
            elif kind=='position':value['position']['chapter_offset']=13
            elif kind=='private':value['thoughts']['new-note']['isPrivate']=0
            elif kind=='range':value['marks']['updated']['new-mark']['range']='2-3'
            else:value['marks']['updated']['unrelated']=dict(value['marks']['updated']['new-mark'],bookmarkId='unrelated')
            with self.assertRaises(ValueError):observe(plan.baseline,value,plan.context,'1'*32,'created')

    def test_existing_chapter_titles_are_preserved_new_selected_index_may_remain(self):
        _p,plan=fixture();value=changed(plan,3,chapter=True)
        self.assertTrue(restored(plan.baseline,value,plan.context,'1'*32,'new-note',None))
        value['marks']['chapters']['3']='Unrelated chapter'
        with self.assertRaises(ValueError):observe(plan.baseline,value,plan.context,'1'*32,'deleted','new-note')
        plan.baseline['marks']['chapters']['2']='Original'
        with self.assertRaises(ValueError):observe(plan.baseline,changed(plan,3,chapter=True),plan.context,'1'*32,'deleted','new-note')

    def test_independent_read_lag_retries_reads_only_and_is_bounded(self):
        p,plan=fixture();probe=SelectionProbe(web=Mock(),notes=Mock(),writer=Mock(),sleep=lambda _n:None)
        probe.plan,probe.payload,probe.original=plan,p,fingerprint(plan.bound)
        probe.notes.observe.side_effect=[deepcopy(plan.baseline),changed(plan)]
        probe.read_step(p['selection_preview']['credentials'],1,'new-note')
        self.assertEqual(probe.notes.observe.call_count,2);probe.writer.request.assert_not_called()
        probe.created_id=None;probe.notes.observe.reset_mock();probe.notes.observe.side_effect=[deepcopy(plan.baseline)]*3
        with self.assertRaises(ValueError):probe.read_step(p['selection_preview']['credentials'],1,'new-note')
        self.assertEqual(probe.notes.observe.call_count,3);probe.writer.request.assert_not_called()

    def cleanup_probe(self,*,no_change=False,auto_removed=False,lost_ack=False):
        p,plan,store,r=self.store();r=store.claim(r);value=changed(plan,3,mark=True)
        mark=dict(id='new-mark',sha256=digest(value['marks']['updated']['new-mark']))
        for step in (1,2,3):r=store.native_step(r,step,'new-note',mark)
        probe=SelectionProbe(web=Mock(),notes=Mock(),writer=Mock(),sleep=lambda _n:None)
        probe.plan,probe.payload,probe.original,probe.created_id,probe.mark=plan,p,fingerprint(plan.bound),'new-note',mark
        probe.notes.observe.side_effect=[deepcopy(plan.baseline)] if auto_removed else [value]+([value]*3 if no_change else [deepcopy(plan.baseline)])
        if lost_ack:probe.writer.request.side_effect=__import__('verify_eink_login').ProbeError('lost acknowledgement')
        return probe,store,r

    def test_cleanup_targets_only_the_record_independently_bound_before_claim(self):
        probe,store,r=self.cleanup_probe(lost_ack=True)
        def send(*values):
            self.assertTrue(store.read()[0]['cleanup_pending']);self.assertEqual(values[2],dict(bookmarkIds=['new-mark']))
            raise __import__('verify_eink_login').ProbeError('lost ack')
        probe.writer.request.side_effect=send;r=probe.cleanup(payload()['selection_preview']['credentials'],store,r)
        self.assertEqual(probe.writer.request.call_count,1);self.assertTrue(store.read()[0]['cleanup_verified'])

    def test_no_effect_cleanup_stays_pending_and_never_sends_again(self):
        probe,store,r=self.cleanup_probe(no_change=True)
        with self.assertRaises(ValueError):probe.cleanup(payload()['selection_preview']['credentials'],store,r)
        self.assertEqual(probe.writer.request.call_count,1);self.assertTrue(store.read()[0]['cleanup_pending'])
        with self.assertRaises(ValueError):probe.cleanup(payload()['selection_preview']['credentials'],store,store.read()[1])
        self.assertEqual(probe.writer.request.call_count,1)

    def test_auto_removed_association_spends_no_cleanup_post(self):
        probe,store,r=self.cleanup_probe(auto_removed=True);probe.cleanup(payload()['selection_preview']['credentials'],store,r)
        probe.writer.request.assert_not_called();self.assertTrue(store.read()[0]['cleanup_verified'])

    def test_public_runner_and_transport_configuration_are_strict(self):
        task.validate_runner(runner(True),True)
        for key,value in [('private','source'),('profile_removed',False),('installed_files',True)]:
            v=runner(True);v[key]=value
            with self.assertRaises(ValueError):task.validate_runner(v,True)
        v=runner(True);v['stage']['selection_trial']['native_gets']=0
        with self.assertRaises(ValueError):task.validate_runner(v,True)
        p,plan=fixture();p['selection_trial']=dict(armed=False,rpc_token='a'*32,original_ids=['original'],edited_text=note_text('1'*32,True))
        native.validate_payload(p,False,None)
        for field in ('full_manifest','progress_roundtrip','annotations'):
            invalid=deepcopy(p);invalid[field]={}
            with self.assertRaises(ValueError):native.validate_payload(invalid,False,None)
        with self.assertRaises(ValueError):native.validate_payload(p,True,None)
        with self.assertRaises(ValueError):native.validate_payload(p,False,1234)
        self.assertNotIn('cookies',task.public_runner(runner(True)))

    def test_default_never_loads_account_or_reservation(self):
        with patch.object(task,'SelectionTrialStore') as store,patch.object(task,'SessionStore') as session,patch.object(task,'SelectionProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        for item in (store,session,probe):item.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def run_fixture(self):
        p,plan,store,r=self.store();probe=SimpleNamespace(payload=p,plan=plan,cleanup_posts=0,derived_chapter_metadata_changed=False,
            current=Mock(),baseline=Mock(),final=Mock(),read_step=Mock(return_value=None))
        probe.cleanup=lambda _credentials,s,receipt:s.verified_cleanup(receipt)
        return probe,store,r

    def test_full_reservation_precedes_spawn_and_each_ack_follows_readback(self):
        probe,store,r=self.run_fixture();child=Mock();child.wait.return_value=0
        messages=[('STEP',dict(seq=n,created_id='new-note')) for n in (1,2,3)]+[('RESULT',runner(True))]
        def spawn(*_args,**_kwargs):
            self.assertEqual(store.read()[0]['reserved_posts'],4);return child
        def ack(_stream,value):self.assertEqual(store.read()[0]['native_steps'],value['seq'])
        with patch.object(task.subprocess,'Popen',side_effect=spawn),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply',side_effect=ack),patch.object(task,'stop'):
            frames.return_value.next.side_effect=messages
            result=task.run(probe,payload()['selection_preview']['credentials'],store,r,['synthetic'],armed=True,expected=fingerprint(probe.plan.bound))
        self.assertEqual(result['independent_native_steps'],3);self.assertFalse(store.pending());self.assertEqual(probe.read_step.call_count,3)

    def test_wrong_intent_or_independent_failure_cannot_launch_next_write(self):
        probe,store,r=self.run_fixture()
        with patch.object(task.subprocess,'Popen') as process,self.assertRaises(ValueError):task.run(probe,{},store,r,['synthetic'],armed=True,expected='0'*64)
        process.assert_not_called();self.assertEqual(store.read()[0]['reserved_posts'],0)
        probe.read_step.side_effect=ValueError('independent mismatch');child=Mock();child.poll.return_value=None;child.wait.return_value=0
        failure=dict(result='UNVERIFIED',profile_removed=True,installed_files=0,installed_bytes_match=False,stage=None,cookies={})
        with patch.object(task.subprocess,'Popen',return_value=child),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply') as ack,patch.object(task,'stop'):
            frames.return_value.next.side_effect=[('STEP',dict(seq=1,created_id='new-note')),('RESULT',failure)]
            with self.assertRaises(task.TrialFailure):task.run(probe,{},store,r,['synthetic'],armed=True,expected=fingerprint(probe.plan.bound))
        self.assertFalse(ack.call_args[0][1]['ok']);self.assertEqual(store.read()[0]['native_steps'],0);self.assertEqual(store.read()[0]['reserved_posts'],4)


if __name__=='__main__':unittest.main()
