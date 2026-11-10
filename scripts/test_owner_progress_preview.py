"""Offline gates for the dispatch-disabled real-reader preview."""
from contextlib import redirect_stdout, redirect_stderr
import copy
import io
import json
import time
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import owner_progress_preview_contract as contract
import verify_owner_progress_preview as task
from test_owner_reading import OWNER,COOKIES,stage,frame
from test_position_roundtrip import plan
from verify_position_roundtrip import WRITE_ORDER,payload,weread_sign,sorted_query


def records(value=None):
    value=value or plan()
    return [dict(stage=key,body=payload(value,key),context={k:value['context'][k] for k in ('psvts','pclts','token')}) for key in WRITE_ORDER]


def envelope():
    row=stage()
    row['progress_preview']=dict(**dict.fromkeys(contract.FLAGS,True),captured_requests=4,synthetic_enter_acknowledgements=1,
                                 denied_requests=0,network_write_dispatches=0,failed_line=0)
    return dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,stages=[row],runner_error='none'),
                cookies=COOKIES.copy(),progress_private=dict(records=records()))


class PreviewTests(unittest.TestCase):
    def test_default_never_accesses_credentials_or_starts_child(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'Preflight') as web,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();web.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_no_apply_or_write_mode_exists(self):
        for args in (['--apply'],['--saved-session'],['--lua-command','synthetic'],['--mode','probe']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_public_schema_and_cleanup_are_strict(self):
        contract.decode(frame(envelope()),OWNER)
        for field in contract.FLAGS-{'legacy_matches_source','page_start_matches_source'}:
            value=envelope();value['report']['stages'][0]['progress_preview'][field]=False
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        for field,bad in (('network_write_dispatches',1),('captured_requests',3),('denied_requests',1),('synthetic_enter_acknowledgements',True)):
            value=envelope();value['report']['stages'][0]['progress_preview'][field]=bad
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        for field in ('profile_removed','tmpfs_profile'):
            value=envelope();value['report'][field]=False
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)
        value=envelope();value['report']['stages'][0]['progress_preview']['private']='synthetic'
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_single_live_process_is_not_an_offline_claim(self):
        for change in ('empty','two','offline'):
            value=envelope()
            if change=='empty':value['report']['stages']=[]
            if change=='two':value['report']['stages']*=2
            if change=='offline':value['report']['stages'][0]['mode']='reopen'
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_early_failure_has_no_private_records_and_cannot_be_pass(self):
        value=envelope();value['report'].update(result='UNVERIFIED',stages=[],runner_error='progress_preview_private')
        value['progress_private']=None
        actual=contract.decode(frame(value),OWNER)
        self.assertEqual(actual['report']['runner_error'],'progress_preview_private')
        value['report']['result']='PASS'
        with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_private_records_are_ordered_and_bounded(self):
        for change in ('missing','order','context','extra'):
            value=envelope();private=value['progress_private']
            if change=='missing':private['records'].pop()
            if change=='order':private['records'][1]['stage']='write_restore'
            if change=='context':private['records'][0]['context']['token']='bad\nsecret'
            if change=='extra':private['private']='synthetic'
            with self.assertRaises(ValueError):contract.decode(frame(value),OWNER)

    def test_every_actual_wire_field_is_compared_independently(self):
        value=plan();rows=records(value);now=int(time.time())
        contract.compare(rows,value,now-1,now+1)
        for field,bad in (('co',999),('rt',1),('ci',True),('b','other'),('s','bad'),('sg','bad'),('ps','other')):
            changed=copy.deepcopy(rows);changed[2]['body'][field]=bad
            if field!='s':changed[2]['body']['s']=weread_sign(sorted_query({k:v for k,v in changed[2]['body'].items() if k!='s'}))
            with self.assertRaises(ValueError):contract.compare(changed,value,now-1,now+1)

    def test_late_private_receipts_still_use_a_bounded_observation_window(self):
        value=plan();rows=records(value);now=int(time.time())
        with self.assertRaises(ValueError):contract.compare(rows,value,now+5,now+10)
        rows[2]['body']['ct']=True
        with self.assertRaises(ValueError):contract.compare(rows,value,now-1,now+1)

    def test_numeric_reader_counter_is_preserved_and_stage_order_is_still_required(self):
        value=plan();rows=records(value);now=int(time.time())
        for row in rows:
            row['context']['pclts']=123
            row['body']['pc']=123
            row['body']['s']=weread_sign(sorted_query({k:v for k,v in row['body'].items() if k!='s'}))
        contract.private(dict(records=rows),True)
        contract.compare(rows,value,now-1,now+1)
        rows[2]['stage']='write_restore'
        with self.assertRaises(ValueError):contract.compare(rows,value,now-1,now+1)

    def run_saved(self,fail=False):
        web=MagicMock();web.vid=OWNER;web.book_id='900001';web.plan=plan();web.report=dict(stages=[])
        web.baseline=dict(chapter='2',offset=10,percent=25)
        web.prepare.return_value=dict(book_id='900001',chapter_uid='2',progress_preview={})
        with patch.object(task,'SessionStore') as store,patch.object(task,'Preflight',return_value=web), \
                patch.object(task,'save_refreshed_web_session',return_value=False),patch.object(task,'reading_position',return_value=web.baseline), \
                patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid=OWNER,cookies=COOKIES.copy())
            child.return_value=SimpleNamespace(returncode=0,stdout=frame(envelope()))
            if fail:child.side_effect=RuntimeError('synthetic-private-failure')
            code=task.main(['--saved-session','--lua-command','synthetic'])
        return code,json.loads(out.getvalue()),store,child

    def test_saved_preview_reports_only_fixed_proofs_and_no_real_write(self):
        code,value,store,child=self.run_saved()
        self.assertEqual((code,value['result']),(0,'OWNER_NATIVE_UPLOAD_PREVIEW_VERIFIED'))
        self.assertEqual(value['payloads_compared'],4)
        self.assertTrue(value['synthetic_enter_acknowledgement']);self.assertFalse(value['real_plugin_write_verified'])
        self.assertFalse(value['offline_reopen_included']);self.assertEqual(value['account_data_writes_attempted'],0)
        self.assertNotIn('synthetic-ps',json.dumps(value));self.assertNotIn('progress_private',json.dumps(value))
        self.assertNotIn('synthetic-only-key',json.dumps(value))
        self.assertEqual(child.call_count,1);store.return_value.begin_renewal.assert_not_called()

    def test_unknown_output_never_replays_or_exposes_private_failure(self):
        code,value,store,child=self.run_saved(fail=True)
        self.assertEqual(code,1);self.assertEqual(child.call_count,1)
        store.return_value.begin_renewal.assert_not_called()
        self.assertNotIn('synthetic-private-failure',json.dumps(value))


if __name__=='__main__':unittest.main()
