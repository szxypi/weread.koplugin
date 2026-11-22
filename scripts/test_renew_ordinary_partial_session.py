import contextlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import renew_ordinary_partial_session as task
from secure_native_session import NativeSessionStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore
from secure_ordinary_recovery_renewal import RecoveryRenewalStore
from test_secure_native_session import Backend,credentials
from test_secure_ordinary_reconnect_trial import plan
from txt_full_summary import digest
from verify_eink_login import ProbeError


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'synthetic'})
        self.old=credentials();self.native_store=NativeSessionStore(Backend());self.native_store.save(self.old,'900000',verified=True)
        selected=plan();selected.update(owner_sha256=digest('900000'),grant_sha256=digest(self.old),web_session_sha256=digest(self.saved))
        self.original=OrdinaryReconnectStore(Backend());self.receipt=self.original.reserve(selected)
        self.receipt=self.original.advance(self.receipt,'prepared','enter_pending');self.receipt=self.original.advance(self.receipt,'enter_pending','enter_acknowledged')
        self.bridge=RecoveryRenewalStore(Backend());self.session=SimpleNamespace(load=lambda:self.saved);self.report={}
    def run_renewal(self,*,status=401,fail=False):
        class Reader:
            def __init__(self,*_):self.report={'stages':[]}
            def request(self,*_args,**_kwargs):
                self.report['stages'].append({'status':status})
                if status!=200:raise ProbeError('synthetic')
                return {'books':[]}
        class Renewal:
            def __init__(self):self.report={'renewal_attempts':0}
            def renew(inner,old):
                inner.report['renewal_attempts']+=1
                if fail:raise ProbeError('synthetic lost receipt')
                return dict(old,accessToken='synthetic-new-access'),{'books':[]}
        task.execute(self.original,self.receipt,self.session,self.native_store,self.bridge,self.saved,self.old,lambda:True,self.report,
                     reader_factory=Reader,renewal_factory=Renewal)
    def test_two_401_then_one_verified_renewal(self):
        self.run_renewal();self.assertEqual(self.report['result'],'ORDINARY_RECOVERY_RENEWAL_VERIFIED')
        state,_=self.bridge.read();self.assertEqual(state['phase'],'verified')
        self.assertEqual(state['new_grant_sha256'],digest(self.native_store.load('900000')))
        self.assertEqual(self.original.read()[0]['phase'],'enter_acknowledged')
        with self.assertRaises(ValueError):self.run_renewal()
    def test_no_renewal_without_explicit_401(self):
        with self.assertRaises(ValueError):self.run_renewal(status=200)
        self.assertIsNone(self.bridge.read()[0]);self.assertEqual(self.native_store.load('900000'),self.old)
    def test_ambiguous_renewal_stays_pending_and_cannot_replay(self):
        with self.assertRaises(ProbeError):self.run_renewal(fail=True)
        self.assertEqual(self.bridge.read()[0]['phase'],'pending');self.assertEqual(self.report['authentication_posts_attempted'],1)
        with self.assertRaises(ValueError):self.run_renewal(fail=True)
    def test_default_and_partial_cli_are_offline(self):
        with patch.object(task,'SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in (['--renew'],['--saved-session']):
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)


if __name__=='__main__':unittest.main()
