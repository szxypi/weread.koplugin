"""Single native first-position scope, private broker and no-replay boundaries."""
from contextlib import ExitStack,redirect_stdout,redirect_stderr
from copy import deepcopy
import io,json,time,unittest
from unittest.mock import Mock,patch
from native_reader_fixture import GRANT
from native_initial_reader_model import PROTOCOL,validate_plan
from native_initial_reader_contract import FLAGS,validate_payload,validate_stage,validate_result
from secure_native_initial_reader import NativeInitialReaderStore
from secure_native_initial_position import NativeInitialPositionStore
from secure_weread_session import StoreError
from test_native_initial_position import plan as prior_plan
from test_native_reader_trial import Child
from test_owner_reading import stage as reading_stage
from test_secure_native_session import Backend
from native_txt_read_model import body
import native_initial_reader_broker as broker
import verify_native_initial_reader as task


def plan():
    p=prior_plan();p['protocol']=PROTOCOL;return p


def payload(armed=True,prepare=False):
    p=plan()
    if prepare:p['target']['raw_percent']=0;p['source_file_id']='0'*64
    return dict(book_id='900001',chapter_uid='1',source_text='Synthetic source for native first position validation.',shelf_ids=['900001'],shelf_books=1,
                source_format='web_txt',source_raw_sha256=p['source_sha256'],source_sample_offset=120,vid=GRANT['vid'],cookies=dict(wr_vid=GRANT['vid'],wr_skey='mock_key'),
                native_source_excerpt=True,native_grant=deepcopy(GRANT),reader_mock_port=12345,
                native_initial_reader=dict(plan=p,armed=armed,bind_percent=not prepare,rpc_token='a'*32,native_shelf_sha256=p['native_shelf_sha256'],guest='5ecdcfd7f',time_zone='+08:00'))


def result(armed):
    s=reading_stage();a={k:True for k in FLAGS}
    a.update(phase='complete',permit_writes=armed,local_commit=armed,dispatch_blocked=not armed,native_gets=12,native_posts=1 if armed else 0,
             blocked_posts=0 if armed else 1,native_denied=0,last_native_status=200,acknowledged=1 if armed else 0,steps=1 if armed else 0,failed_line=0)
    s['native_initial_reader']=a
    return dict(result='PASS',profile_removed=True,installed=dict(files=287,bytes_match=True),stage=s,cookies=dict(wr_vid='900000',wr_skey='mock_key'))


def events(v):
    p=plan();t=v['native_initial_reader'];m=dict(book_id='900001',before=deepcopy(p['baseline']['native']),desired=deepcopy(p['target']),counts=p['counts'],
         version=p['version'],shelf_sha256=p['native_shelf_sha256'],source_sha256=p['source_sha256'],file_id=p['source_file_id'],basis='raw_txt_utf16')
    sequence=[('STEP',dict(kind='plan',seq=1,metadata=m,reader_percent=p['target']['raw_percent'])),
              ('STEP',dict(kind='claim' if t['armed'] else 'dry_body',seq=1,body=body(GRANT,p['target'],p['version'],t['guest'],int(time.time()),123,t['time_zone'])))]
    if t['armed']:sequence.extend([('STEP',dict(kind='ack',seq=1)),('STEP',dict(kind='verified',seq=1))])
    return sequence+[('RESULT',result(t['armed']))]


class NativeInitialReaderTests(unittest.TestCase):
    def run_case(self,*,armed=True,prepare=False,modify=None,after=None,before=None,fail_claim=False):
        v=payload(armed,prepare);store=NativeInitialReaderStore(Backend())
        if not prepare:store.reserve(v['native_initial_reader']['plan'])
        sequence=events(v)
        if modify:modify(sequence)
        frames=Mock();frames.next.side_effect=sequence;child=Child();r={};answers=[]
        advance=store.advance
        def claim(*args):
            if fail_claim and args[1]=='prepared':raise StoreError('initial_reader/claim')
            return advance(*args)
        def reply(_stream,value):
            if value['ok'] and armed and value['kind']=='claim':self.assertEqual(store.read()[0]['phase'],'pending')
            answers.append(value)
        with patch.object(broker.subprocess,'Popen',return_value=child),patch.object(broker,'Frames',return_value=frames),\
             patch.object(broker,'reply',side_effect=reply),patch.object(broker,'stop') as stop,patch.object(store,'advance',side_effect=claim):
            try:broker.execute(v,['synthetic'],store,r,prepare=prepare,before=before,after=after)
            except Exception:r['stopped']=True
        stop.assert_called_once_with(child);return v,store,r,answers
    def test_default_never_loads_grants_network_or_reader(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as grant,patch.object(task,'execute') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();grant.assert_not_called();child.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_incomplete_or_conflicting_cli_is_rejected(self):
        for args in (['--saved-session'],['--apply'],['--mock'],['--native-ui-command','x'],['--saved-session','--inspect','--native-ui-command','x'],['--mock','--inspect']):
            with self.subTest(args=args),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
    def test_scope_and_protocol_are_distinct_from_consumed_python_sender(self):
        self.assertNotEqual(NativeInitialReaderStore.service,NativeInitialPositionStore.service)
        self.assertNotEqual(PROTOCOL,NativeInitialPositionStore.protocol)
        with self.assertRaises(StoreError):validate_plan(prior_plan())
        validate_plan(plan())
    def test_prepare_binds_actual_reader_percent_and_file_before_reserving(self):
        _v,store,r,answers=self.run_case(armed=False,prepare=True)
        state=store.read()[0];self.assertEqual((state['phase'],state['posts']),('prepared',0))
        self.assertEqual(state['plan']['source_file_id'],'e'*64);self.assertEqual(state['plan']['target']['raw_percent'],50)
        self.assertEqual(r['synthetic_posts'],0);self.assertEqual([a['kind'] for a in answers],['plan','dry_body'])
    def test_fresh_disarmed_preview_never_claims_or_saves_ack(self):
        _v,store,r,_a=self.run_case(armed=False)
        self.assertEqual((store.read()[0]['phase'],store.read()[0]['posts']),('prepared',0))
        self.assertEqual(r['result'],'NATIVE_INITIAL_READER_DISARMED_VERIFIED')
    def test_actual_native_sequence_is_exactly_one_claim_ack_and_independent_step(self):
        _v,store,r,answers=self.run_case()
        self.assertEqual((store.read()[0]['phase'],store.read()[0]['posts']),('retired',1))
        self.assertEqual(r['explicit_success_receipts'],1);self.assertEqual(r['independent_steps'],1)
        self.assertFalse(r['original_no_chapter_restored']);self.assertTrue(r['first_position_established'])
        self.assertEqual([a['kind'] for a in answers],['plan','claim','ack','verified'])
    def test_changed_point_binding_counts_shelf_and_presence_stop_before_claim(self):
        changes=(lambda m:m['desired'].update(chapter_offset=121),lambda m:m.update(file_id='f'*64),lambda m:m['before'].update(summary_present=True,summary=''),
                 lambda m:m['counts'].update(readingTime=1),lambda m:m.update(shelf_sha256='f'*64),lambda m:m.update(version=True),
                 lambda m:m.update(extra='private'),lambda m:m['desired'].update(raw_percent=51))
        for change in changes:
            with self.subTest(change=change):
                _v,store,r,_a=self.run_case(modify=lambda items:change(items[0][1]['metadata']))
                self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'prepared')
    def test_wrong_dto_signature_time_units_and_body_fields_do_not_claim(self):
        for change in ({'readingTime':1},{'signature':'0'*64},{'summary':'guessed'},{'bookVersion':7},{'timestamp':int(time.time())-31},{'hours':{}},{'extra':1}):
            _v,store,r,_a=self.run_case(modify=lambda items:items[1][1]['body'].update(change))
            self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'prepared')
    def test_claim_save_failure_and_independent_preflight_failure_never_allow_transport(self):
        for args in (dict(fail_claim=True),dict(before=Mock(side_effect=ValueError('initial_reader/changed')))):
            _v,store,r,answers=self.run_case(**args)
            self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'prepared');self.assertFalse(answers[-1]['ok']);self.assertEqual(r['claimed_posts'],0)
    def test_lost_ack_and_duplicate_claim_keep_unknown_no_second_step(self):
        for modify in (lambda items:items.__delitem__(slice(2,None)),lambda items:items.insert(2,deepcopy(items[1])),lambda items:items.pop(2)):
            _v,store,r,_a=self.run_case(modify=modify)
            self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'pending');self.assertEqual(r['synthetic_posts'],1)
    def test_acknowledged_scope_survives_independent_readback_failure(self):
        _v,store,r,answers=self.run_case(after=Mock(side_effect=ValueError('initial_reader/readback')))
        self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'acknowledged');self.assertEqual(r['explicit_success_receipts'],1);self.assertFalse(answers[-1]['ok'])
    def test_old_consumed_or_pending_scope_never_starts_a_reader_again(self):
        for phase in ('pending','acknowledged','retired'):
            store=NativeInitialReaderStore(Backend());receipt=store.reserve(plan());receipt=store.advance(receipt,'prepared','pending')
            if phase!='pending':receipt=store.advance(receipt,'pending','acknowledged')
            if phase=='retired':store.advance(receipt,'acknowledged','retired')
            with patch.object(broker.subprocess,'Popen') as child,self.assertRaises(ValueError):broker.execute(payload(),['synthetic'],store,{})
            child.assert_not_called()
            with self.assertRaises(StoreError):store.reserve(plan())
    def test_stale_receipt_cannot_advance_or_overwrite(self):
        store=NativeInitialReaderStore(Backend());r=store.reserve(plan());store.advance(r,'prepared','pending')
        with self.assertRaises(StoreError):store.advance(r,'prepared','pending')
        self.assertEqual(store.read()[0]['posts'],1)
    def test_closed_payload_stage_and_result_cannot_claim_missing_proofs(self):
        validate_payload(payload(),True,12345);validate_result(result(True),True,GRANT['vid'])
        for change in (lambda v:v.update(extra='private'),lambda v:v.update(chapter_uid='2'),lambda v:v['native_initial_reader'].update(armed=1),
                       lambda v:v['native_initial_reader'].update(native_shelf_sha256='f'*64)):
            v=payload();change(v)
            with self.assertRaises((ValueError,StoreError)):validate_payload(v,True,12345)
        for key in FLAGS-{'permit_writes','dispatch_blocked'}:
            v=result(True);v['stage']['native_initial_reader'][key]=False
            with self.assertRaises(ValueError):validate_stage(v['stage'],True)
        for key,value in (('profile_removed',False),('installed',dict(files=287,bytes_match=False))):
            v=result(True);v[key]=value
            with self.assertRaises(ValueError):validate_result(v,True,GRANT['vid'])
    def test_read_only_inspection_keeps_unknown_scope_and_never_starts_a_reader(self):
        from test_native_initial_position import Web,Api
        from native_initial_fixture import NativeInitialServer
        server=NativeInitialServer('rejected');store=NativeInitialReaderStore(Backend());r=store.reserve(plan());store.advance(r,'prepared','pending')
        old=store.read();report={}
        try:
            with patch.object(task,'verify_source'),patch.object(task,'check_binding') as binding,patch.object(task,'execute') as reader:
                task.inspect_current(Web(server),Api(server,store),GRANT,plan(),report)
            reader.assert_not_called();self.assertEqual(store.read(),old);self.assertEqual(report['current_state'],'original')
            self.assertEqual(report['independent_observations'],2);self.assertTrue(binding.call_args.kwargs['read_only'])
        finally:server.server_close()
    def test_private_load_failures_are_not_printed(self):
        with patch('verify_native_thought_trial.other_pending',return_value=False),patch.object(task,'SessionStore',side_effect=ValueError('PRIVATE_COOKIE_LITERAL')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--prepare','--native-ui-command','synthetic']),1)
        self.assertNotIn('PRIVATE_COOKIE_LITERAL',out.getvalue());self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)
    def test_pending_new_scope_blocks_every_old_exclusion(self):
        import verify_native_thought_trial as shared
        with ExitStack() as stack:
            factories={}
            for name in dir(shared):
                if name.endswith('Store'):
                    factory=stack.enter_context(patch.object(shared,name));factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None);factories[name]=factory
            factories['NativeInitialReaderStore'].return_value.pending.return_value=True
            self.assertTrue(shared.other_pending());self.assertTrue(shared.other_pending(exclude_native_initial_position=True))
            self.assertFalse(shared.other_pending(exclude_native_initial_reader=True))


if __name__=='__main__':unittest.main()
