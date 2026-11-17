"""Transport allowlist and opt-in boundary for the empty-group experiment."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cloud_group_contract import create_request, delete_request, digest, project
from cloud_group_journal import Journal
from test_cloud_group_journal import Memory
from test_cloud_group_trial import shelf
from verify_cloud_group_trial import ScopedNative, main
from verify_eink_login import NativeProbe, ProbeError


class ScopedTransportTest(unittest.TestCase):
    def setUp(self):
        self.journal=Journal(backend=Memory());self.grant={'vid':'42','accessToken':'synthetic-token'}
        self.name='KOReader-Test-'+'a'*24
        self.token=self.journal.begin('42',digest(self.grant),self.name,'b'*64,'c'*64)
        self.probe=ScopedNative(self.journal,self.grant,lambda:True,lambda:True)

    def test_scope_and_one_shot_dispatch(self):
        body=create_request(self.name)
        with self.assertRaises(ProbeError):self.probe.post('/shelf/archive',body)
        self.token=self.journal.advance(self.token,'create_claimed')
        for path,value in (('/shelf/add',body),('/shelf/archive',dict(body,name='other'))):
            with self.subTest(path=path),self.assertRaises(ProbeError):self.probe.post(path,value)
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as send:
            self.assertEqual(self.probe.post('/shelf/archive',body),{'succ':1})
            with self.assertRaises(ProbeError):self.probe.post('/shelf/archive',body)
            self.assertEqual(send.call_count,1)
        self.token=self.journal.advance(self.token,'created',group_id_value='42')
        self.token=self.journal.advance(self.token,'delete_claimed')
        with patch.object(NativeProbe,'request',return_value={'succ':1}) as send:
            with self.assertRaises(ProbeError):self.probe.post('/shelf/deleteArchive',{'archiveId':42,'removeBooks':1})
            self.probe.post('/shelf/deleteArchive',delete_request('42'))
            with self.assertRaises(ProbeError):self.probe.post('/shelf/deleteArchive',delete_request('42'))
            self.assertEqual(send.call_count,1)

    def test_expired_owner_or_other_pending_blocks_before_send(self):
        self.token=self.journal.advance(self.token,'create_claimed');body=create_request(self.name)
        for probe in (ScopedNative(self.journal,self.grant,lambda:False,lambda:True),
                      ScopedNative(self.journal,self.grant,lambda:True,lambda:False)):
            with self.assertRaises(ProbeError):probe.post('/shelf/archive',body)
            self.assertEqual(probe.write_attempts,0)

    def test_offline_default_does_not_open_credentials_or_network(self):
        with patch('verify_cloud_group_trial.SessionStore') as session,patch('verify_cloud_group_trial.NativeSessionStore') as native,redirect_stdout(io.StringIO()):
            self.assertEqual(main([]),0)
        session.assert_not_called();native.assert_not_called()

    def test_read_only_closure_seals_exact_scope_without_sending(self):
        grant={'vid':'42','accessToken':'synthetic-token'};saved={'vid':'42','cookies':{'wr_skey':'synthetic-cookie'}}
        journal=Journal(backend=Memory());name='KOReader-Test-'+'a'*24
        token=journal.begin('42',digest(grant),name,digest(project(shelf(True))),digest(project(shelf(False))))
        journal.advance(token,'create_claimed')
        native=SimpleNamespace(shelf=lambda:deepcopy(shelf(True)),write_attempts=0,report={'stages':[]},
                               post=lambda *_args: self.fail('read-only closure sent a write'))
        web=SimpleNamespace(vid=None,set_cookie=lambda *_args:None,verify_account=lambda:None,
                            request=lambda *_args:deepcopy(shelf(False)),close=lambda:None)
        output=io.StringIO()
        with patch('verify_cloud_group_trial.no_other_pending',return_value=True),patch('verify_cloud_group_trial.Journal',return_value=journal),\
             patch('verify_cloud_group_trial.SessionStore') as session,patch('verify_cloud_group_trial.NativeSessionStore') as native_store,\
             patch('verify_cloud_group_trial.WebFlagsProbe',return_value=web),patch('verify_cloud_group_trial.ScopedNative',return_value=native),\
             patch('verify_cloud_group_trial.save_refreshed_web_session',return_value=False),redirect_stdout(output):
            session.return_value.load.return_value=saved;native_store.return_value.load.return_value=grant
            self.assertEqual(main(['--saved-session','--close-unchanged']),0)
        result=json.loads(output.getvalue());self.assertEqual(result['result'],'CLOSED_UNVERIFIED')
        self.assertEqual(result['data_posts'],0);self.assertEqual(journal.read()[0]['phase'],'closed_unverified')
        self.assertNotIn('synthetic-token',output.getvalue());self.assertNotIn(name,output.getvalue())

    def test_consumed_scope_stops_before_credential_or_network_access(self):
        output=io.StringIO()
        with patch('verify_cloud_group_trial.Journal') as journal,patch('verify_cloud_group_trial.SessionStore') as session,\
             patch('verify_cloud_group_trial.no_other_pending') as pending,redirect_stdout(output):
            journal.return_value.read.return_value=({'phase':'closed_unverified'},b'opaque')
            self.assertEqual(main(['--saved-session','--apply']),1)
        session.assert_not_called();pending.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['phase'],'scope_consumed')

    def test_delayed_group_inspection_returns_only_boolean_facts(self):
        grant={'vid':'42','accessToken':'synthetic-token'};saved={'vid':'42','cookies':{'wr_skey':'synthetic-cookie'}}
        journal=Journal(backend=Memory());name='KOReader-Test-'+'a'*24
        base_native,base_web=project(shelf(True)),project(shelf(False))
        token=journal.begin('42',digest(grant),name,digest(base_native),digest(base_web));token=journal.advance(token,'create_claimed')
        journal.close_unchanged(token,[(base_native,base_web),(base_native,base_web)])
        native_shelf=shelf(True);native_shelf['archive'].append({'archiveId':97,'name':name,'bookIds':[],'albumIds':[]})
        web_shelf=shelf(False);web_shelf['archive'].append({'archiveId':97,'name':name,'bookIds':[]})
        native=SimpleNamespace(shelf=lambda:deepcopy(native_shelf),write_attempts=0,report={'stages':[]},
                               post=lambda *_args:self.fail('inspection sent a write'))
        web=SimpleNamespace(vid=None,set_cookie=lambda *_args:None,verify_account=lambda:None,
                            request=lambda *_args:deepcopy(web_shelf),close=lambda:None)
        output=io.StringIO()
        with patch('verify_cloud_group_trial.Journal',return_value=journal),patch('verify_cloud_group_trial.SessionStore') as session,\
             patch('verify_cloud_group_trial.NativeSessionStore') as native_store,patch('verify_cloud_group_trial.WebFlagsProbe',return_value=web),\
             patch('verify_cloud_group_trial.ScopedNative',return_value=native),patch('verify_cloud_group_trial.no_other_pending') as pending,\
             patch('verify_cloud_group_trial.save_refreshed_web_session',return_value=False),redirect_stdout(output):
            session.return_value.load.return_value=saved;native_store.return_value.load.return_value=grant
            self.assertEqual(main(['--saved-session','--inspect']),0)
        result=json.loads(output.getvalue());self.assertTrue(result['native_present'] and result['same_group_when_visible'])
        self.assertTrue(result['native_other_state_unchanged'] and result['web_other_state_unchanged'])
        self.assertNotIn(name,output.getvalue());self.assertNotIn('synthetic-token',output.getvalue());pending.assert_not_called()


if __name__=='__main__':unittest.main()
