"""Four native slots, matching host handshakes and disjoint trial protocols."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from mark_style_trial_model import bind,row_target
from native_highlight_trial import validate_payload,validate_stage
from secure_highlight_trial import HighlightTrialStore
from secure_mark_style_trial import MarkStyleTrialStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_selection_trial import fixture
from test_highlight_trial import state
from test_native_highlight_trial import runner
from verify_highlight_trial import HighlightProbe
import verify_native_mark_style_trial as task


def result(armed):
    value=runner(armed);a=value['stage']['selection_trial']
    a.update(steps=4 if armed else 0,native_posts=4 if armed else 0,style_controls=armed,style_displays=3 if armed else 0,native_gets=28)
    value['installed_files']=246;return value


class NativeStylesTests(unittest.TestCase):
    def fixture(self):
        payload,plan=fixture();source=Mock();source.payload=payload;source.plan=plan;source.prepare.return_value=plan
        source.baseline.return_value=deepcopy(plan.baseline);source.web.cookies={}
        highlight=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _s:None)
        probe=task.NativeStyleProbe(highlight,MarkStyleTrialStore(Backend(),native=True));probe.prepare({},{})
        added=state(plan,highlight.body);one=added['marks']['updated']['new-highlight']
        straight=deepcopy(added);straight['marks']['updated']['new-highlight']['style']=0;zero=straight['marks']['updated']['new-highlight']
        wave=deepcopy(added);wave['marks']['updated']['new-highlight']['style']=2;two=wave['marks']['updated']['new-highlight']
        probe.read=Mock(side_effect=[(row_target(one),one,added)]*2+[(row_target(zero),zero,straight)]*2+[(row_target(two),two,wave)]*2+[(None,None,plan.baseline)]*2)
        return probe

    def run_mock(self,p,armed=True,events=None):
        child=Mock();child.wait.return_value=0;child.poll.return_value=None
        if events is None:events=([('STEP',dict(seq=n,created_id='new-highlight')) for n in range(1,5)] if armed else [('STEP',dict(seq=0,preview=p.highlight.body))])+[('RESULT',result(armed))]
        def launch(*_args,**_kwargs):
            if armed:self.assertEqual(p.store.read()[0]['reserved_posts'],4)
            else:self.assertEqual(p.store.read(),(None,None))
            return child
        with patch.object(task.subprocess,'Popen',side_effect=launch),patch.object(task,'Frames') as frames,patch.object(task,'write_initial'),patch.object(task,'reply') as ack,patch.object(task,'stop'),patch.object(task,'reading_position',return_value=p.highlight.source.plan.web_position):
            frames.return_value.next.side_effect=events
            return task.run(p,{},['synthetic'],armed=armed),ack

    def test_success_claims_all_four_slots_before_launch_and_checks_every_step(self):
        p=self.fixture();value,ack=self.run_mock(p)
        self.assertEqual(value['independent_steps'],4);self.assertEqual(value['account_data_posts'],4)
        self.assertEqual(p.read.call_count,8);self.assertEqual(ack.call_count,4);self.assertEqual(p.store.read(),(None,None))
        p.highlight.source.writer.request.assert_not_called()

    def test_dry_run_checks_exact_preview_with_no_intent(self):
        p=self.fixture();value,ack=self.run_mock(p,False)
        self.assertEqual(value['account_data_posts'],0);self.assertEqual(p.store.read(),(None,None));p.read.assert_not_called()
        self.assertEqual(ack.call_args.args[1],dict(seq=0,ok=True))

    def test_wrong_or_original_id_stops_and_pending_cannot_launch_again(self):
        for event in (dict(seq=1,created_id='old-mark'),dict(seq=2,created_id='new-highlight'),dict(seq=True,created_id='new-highlight')):
            p=self.fixture()
            with self.subTest(event=event),self.assertRaises(task.TrialFailure):self.run_mock(p,events=[('STEP',event)])
            self.assertEqual(p.store.read()[0]['phase'],'create_pending');p.read.assert_not_called()
            with self.assertRaises(ValueError):task.run(p,{},['synthetic'],armed=True)

    def test_changed_target_cannot_release_next_style(self):
        p=self.fixture();p.read.side_effect=[(dict(id='different',sha256='a'*64),{},p.highlight.source.plan.baseline)]
        with self.assertRaises(task.TrialFailure):self.run_mock(p)
        self.assertEqual(p.store.read()[0]['phase'],'create_pending')

    def test_schema_does_not_accept_old_two_step_receipt_or_other_writes(self):
        p=self.fixture();value=task.payload(p,True);validate_payload(value,True,None,styles=True)
        with self.assertRaises(ValueError):validate_payload(value,True,None)
        for changes in ({'steps':2},{'native_posts':5},{'style_displays':2},{'style_controls':False}):
            r=result(True);r['stage']['selection_trial'].update(changes)
            with self.subTest(changes=changes),self.assertRaises(ValueError):validate_stage(r['stage'],True,styles=True)
        for invalid in (False,1,'true'):
            v=deepcopy(value);v['highlight_trial']['styles']=invalid
            with self.assertRaises(ValueError):validate_payload(v,True,None,styles=True)

    def test_python_and_native_trials_cannot_share_reservations(self):
        p=self.fixture();native=p.store;python=MarkStyleTrialStore(Backend())
        with self.assertRaises(ValueError):python.reserve(p.bound)
        with self.assertRaises(ValueError):native.reserve(bind(p.highlight.bound))
        native.reserve(p.bound)
        with self.assertRaises(StoreError):native.reserve(p.bound)

    def test_default_never_loads_accounts(self):
        with patch.object(task,'SessionStore') as login,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        login.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_prepare_failure_reports_zero_dispatches_without_claiming_or_launching(self):
        p=Mock();p.prepare.side_effect=ValueError('private diagnostic')
        source=p.highlight.source;source.notes.report={'stages':[dict(stage='baseline',status=401)]}
        source.web.report={'stages':[]};source.web.shards={}
        store=MarkStyleTrialStore(Backend(),native=True)
        with patch.object(task,'other_pending',return_value=False),patch.object(task,'NativeThoughtTrialStore') as thoughts,patch.object(task,'SelectionTrialStore') as selection,patch.object(task,'MarkStyleTrialStore',return_value=store),patch.object(task,'SessionStore') as login,patch.object(task,'NativeSessionStore') as native,patch.object(task,'NativeStyleProbe',return_value=p),patch.object(task.subprocess,'Popen') as launch,redirect_stdout(io.StringIO()) as out:
            thoughts.return_value.pending.return_value=selection.return_value.pending.return_value=False
            login.return_value.load.return_value=dict(vid='900000',cookies={});native.return_value.load.return_value={}
            self.assertEqual(task.main(['--saved-session','--dry-run','--native-ui-command','synthetic']),1)
        value=json.loads(out.getvalue());self.assertEqual(value['account_data_posts'],0);self.assertEqual(value['intent_state'],'absent')
        self.assertNotIn('private diagnostic',out.getvalue());launch.assert_not_called();self.assertEqual(store.read(),(None,None))


if __name__=='__main__':unittest.main()
