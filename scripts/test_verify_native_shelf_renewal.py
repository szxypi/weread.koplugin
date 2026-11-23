"""Offline orchestration for saved-session shelf authorization recovery."""
from contextlib import ExitStack
from copy import deepcopy
import tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from secure_native_session import NativeSessionStore
from test_secure_native_session import Backend
from test_native_shelf_renewal_broker import grant,body
import verify_native_shelf_renewal as task


class SupervisorTests(unittest.TestCase):
    def exercise(self,mode):
        credentials=grant();fresh=dict(credentials,accessToken='synthetic-renewed');store=NativeSessionStore(Backend())
        store.save(credentials,credentials['vid'],verified=True)
        saved=dict(vid=credentials['vid'],cookies={'wr_vid':credentials['vid'],'wr_skey':'synthetic-web-access'})
        shelf=dict(books=[dict(bookId='42',title='Synthetic',author='Author')],archive=[]);changed=deepcopy(shelf);changed['books'][0]['title']='Changed'
        state=dict(after=False,broker_calls=0)
        class Session:
            def load(self):return deepcopy(saved)
        class Web:
            def __init__(self):self.cookies=[SimpleNamespace(name='wr_vid',value=credentials['vid']),
                SimpleNamespace(name='wr_skey',value='synthetic-web-access')]
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,*_args):return deepcopy(changed if mode=='changed' and state['after'] else shelf)
            def close(self):pass
        class Native:
            def __init__(self):self.report={'stages':[]}
            def request(self,stage,_url,credentials=None):
                if credentials['accessToken']=='synthetic-access':
                    self.report['stages'].append(dict(stage=stage,status=401));raise ValueError('expired')
                self.report['stages'].append(dict(stage=stage,status=200));return deepcopy(shelf)
        def fake_execute(payload,_command,broker,report):
            state['broker_calls']+=1;armed=payload['armed'];broker.handle(dict(kind='expiry',status=401),armed)
            accepted=broker.handle(dict(kind='claim',body=body(credentials)),armed)
            if armed:
                assert accepted;broker.handle(dict(kind='verified',credentials=fresh,book_count=1),armed)
                broker.handle(dict(kind='shelf',snapshot=shelf),armed);state['after']=True
            else:assert not accepted
            report.update(result='NATIVE_SHELF_RENEWAL_VERIFIED' if armed else 'NATIVE_SHELF_RENEWAL_DRY_VERIFIED',
                authentication_posts_claimed=broker.auth_claimed,keychain_new_grant_saved=broker.saved_status,profile_removed=True)
        with tempfile.TemporaryDirectory() as directory:
            marker=Path(directory)/'once.json'
            patches=[patch.object(task,'MARKER',marker),patch.object(task,'SessionStore',Session),patch.object(task,'NativeSessionStore',return_value=store),
                patch.object(task,'WebSourceProbe',Web),patch.object(task,'NativeProbe',Native),patch.object(task,'other_pending',return_value=False),
                patch.object(task,'command',return_value=['synthetic']),patch.object(task,'execute',side_effect=fake_execute)]
            with ExitStack() as stack:
                for item in patches:stack.enter_context(item)
                result=task.run(apply=mode!='dry');exists=marker.exists()
                second=task.run(apply=True) if exists else None
        return result,store,state,exists,second
    def test_dry_preserves_saved_grant(self):
        result,store,state,exists,_=self.exercise('dry')
        self.assertEqual(result['result'],'NATIVE_SHELF_RENEWAL_DRY_VERIFIED');self.assertFalse(exists)
        self.assertEqual(store.load('12345678'),grant());self.assertEqual(state['broker_calls'],1)
    def test_success_updates_grant_and_consumes_scope(self):
        result,store,_state,exists,second=self.exercise('success')
        self.assertEqual(result['result'],'NATIVE_SHELF_RENEWAL_VERIFIED');self.assertTrue(exists)
        self.assertEqual(store.load('12345678')['accessToken'],'synthetic-renewed')
        self.assertEqual(second['result'],'UNVERIFIED');self.assertEqual(second['authentication_posts_claimed'],0)
    def test_changed_shelf_is_reported_after_grant_is_safely_saved(self):
        result,store,_state,exists,_=self.exercise('changed')
        self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(exists)
        self.assertEqual(result['reason'],'shelf_renewal/changed');self.assertTrue(result['keychain_new_grant_saved'])
        self.assertEqual(store.load('12345678')['accessToken'],'synthetic-renewed')


if __name__=='__main__':unittest.main()
