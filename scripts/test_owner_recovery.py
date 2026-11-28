"""Offline gates for one owner-authorized parent renewal; no owner credentials."""
from contextlib import redirect_stdout, redirect_stderr
import copy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import owner_recovery_contract as contract
import verify_owner_recovery as task
from test_owner_reading import OWNER, COOKIES, stage, frame
from test_owner_annotations import addon

GRANT = dict(vid=OWNER,accessToken='synthetic-new-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'1'*19)
MODEL = dict(ranges=['1-2','3-4'],digest='a'*64,source_quotes_digest='b'*64,underlines=2,thought_items=3)


def private(mode='live',dry=False):
    live=mode=='live'
    return dict(guard_installed=True,credentials=GRANT.copy() if live and not dry else None,
                model=copy.deepcopy(MODEL) if live and not dry else None,
                recovery=dict(first_native_status=401 if live else 0,authentication_posts=int(live and not dry),
                    renewal_shelf_reads=int(live and not dry),renewal_shelf_status=200 if live and not dry else 0,
                    saved_revision=3 if live and not dry else 1,saved_new_grant=live and not dry,renewal_pending=False,
                    guard_denied=0,failed_line=0,store_write_attempts=2 if live and not dry else int(live)))


def envelope(dry=False):
    rows=[]
    for mode in (('live',) if dry else ('live','reopen')):
        row=stage(mode);row['annotations']=addon(mode)
        if mode=='live':
            row['annotations'].update(source_data_matches=False,source_quote_recheck_verified=False,native_underlines_requests=1 if dry else 2)
        if dry:row['result']='UNVERIFIED'
        rows.append(row)
    return dict(report=dict(result='UNVERIFIED' if dry else 'PASS',tmpfs_profile=True,profile_removed=True,stages=rows,
                            runner_error='stage_unverified' if dry else 'none'),cookies=COOKIES.copy(),
                recovery_private=[private(row['mode'],dry) for row in rows])


class OwnerRecoveryTests(unittest.TestCase):
    def test_default_never_loads_credentials_or_starts_a_child(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'NativeSessionStore') as native, \
                patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();native.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_authentication_requires_explicit_session_command_and_renew_flag(self):
        for args in (['--renew-in-parent'],['--saved-session'],['--lua-command','synthetic']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)

    def test_pending_models_are_validated_after_parent_and_not_falsely_preapproved(self):
        value=contract.decode(frame(envelope()),OWNER)
        self.assertFalse(value['report']['stages'][0]['annotations']['source_data_matches'])
        for field in ('source_data_matches','source_quote_recheck_verified'):
            bad=envelope();bad['report']['stages'][0]['annotations'][field]=True
            with self.assertRaises(ValueError):contract.decode(frame(bad),OWNER)
        contract.compare_postflight(MODEL,dict(MODEL,ranges=['3-4','1-2']))
        for field,changed in (('digest','f'*64),('source_quotes_digest','f'*64),('thought_items',4),('ranges',['1-2','5-6'])):
            with self.assertRaises(ValueError):contract.compare_postflight(MODEL,dict(MODEL,**{field:changed}))

    def test_private_receipt_and_runtime_proofs_are_strict(self):
        for key,value in (('authentication_posts',2),('saved_revision',2),('saved_new_grant',False),('renewal_pending',True),
                          ('first_native_status',200),('renewal_shelf_status',401),('guard_denied',1),('store_write_attempts',True)):
            bad=envelope();bad['recovery_private'][0]['recovery'][key]=value
            with self.assertRaises((ValueError,TypeError)):contract.decode(frame(bad),OWNER)
        for key in ('workers_reaped','credential_file_audit','plugin_selection'):
            bad=envelope();bad['report']['stages'][0][key]=False
            with self.assertRaises(ValueError):contract.decode(frame(bad),OWNER)
        bad=envelope();bad['recovery_private'][0]['credentials']['vid']='900099'
        with self.assertRaises(Exception):contract.decode(frame(bad),OWNER)
        bad=envelope();bad['recovery_private'][0]['model']['ranges']=['1-2','1-2']
        with self.assertRaises(ValueError):contract.decode(frame(bad),OWNER)

    def test_reopen_can_never_authenticate_or_read_native_data(self):
        for section,key,value in (('recovery','authentication_posts',1),('recovery','renewal_shelf_reads',1),
                                  ('recovery','store_write_attempts',1),('annotations','native_thought_requests',1)):
            bad=envelope()
            if section=='recovery':bad['recovery_private'][1][section][key]=value
            else:bad['report']['stages'][1][section][key]=value
            with self.assertRaises(ValueError):contract.decode(frame(bad),OWNER)

    def run_online(self,*,renew=True,dry=False,fail_child=False,independent_failure=False):
        web=MagicMock();web.vid=OWNER;web.book_id='900001';web.report=dict(stages=[])
        web.prepare.return_value=dict(book_id='900001',chapter_uid='2',shelf_books=139)
        web.baseline=dict(chapter='2',offset=10,percent=20)
        with patch.object(task,'SessionStore') as store,patch.object(task,'NativeSessionStore') as native, \
                patch.object(task,'ReadingPreflight',return_value=web),patch.object(task,'save_refreshed_web_session',return_value=False), \
                patch.object(task,'decode_content_shards',return_value='<p>private source</p>'), \
                patch.object(task,'reading_position',return_value=web.baseline),patch.object(task,'prepare',return_value=MODEL), \
                patch.object(task,'NativeProbe') as verifier,patch.object(task.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
            store.return_value.load.return_value=dict(vid=OWNER,cookies=COOKIES.copy())
            native.return_value.load.return_value=GRANT.copy()
            native.return_value.begin_renewal.return_value=(SimpleNamespace(pending=b'synthetic-intent'),GRANT.copy())
            verifier.return_value.request.return_value=dict(books=[{}]*139)
            if independent_failure:verifier.return_value.request.side_effect=RuntimeError('synthetic-private-failure')
            child.return_value=SimpleNamespace(stdout=frame(envelope(dry)),returncode=1 if dry else 0)
            if fail_child:child.side_effect=RuntimeError('synthetic-private-failure')
            args=['--saved-session']+(['--renew-in-parent'] if renew else [])+['--lua-command','synthetic']
            code=task.main(args)
        return code,json.loads(output.getvalue()),native.return_value,child

    def test_dry_expiry_does_not_create_an_intent_or_send_authentication(self):
        code,result,store,child=self.run_online(renew=False,dry=True)
        self.assertEqual((code,result['result']),(0,'OWNER_PLUGIN_EXPIRY_VERIFIED_NO_AUTH_POST'))
        store.begin_renewal.assert_not_called();store.finish_renewal.assert_not_called()
        self.assertFalse(json.loads(child.call_args.kwargs['input'])['annotations']['permit_renewal'])

    def test_verified_grant_is_saved_and_independent_model_is_required(self):
        code,result,store,child=self.run_online()
        self.assertEqual(code,0);self.assertEqual(result['result'],'OWNER_PARENT_ANNOTATION_RECOVERY_VERIFIED')
        store.finish_renewal.assert_called_once();store.release_renewal.assert_not_called()
        self.assertTrue(result['independent_model_verified']);self.assertEqual(result['authentication_posts_attempted'],1)
        self.assertNotIn('synthetic-new-access',json.dumps(result))
        self.assertEqual(len(json.loads(child.call_args.kwargs['input'])['annotations']['intent_digest']),64)

    def test_unknown_or_unverified_receipts_keep_intent_and_never_replay(self):
        for options in (dict(fail_child=True),dict(independent_failure=True)):
            code,result,store,_child=self.run_online(**options)
            self.assertEqual(code,1);self.assertTrue(result['keychain_intent_retained'])
            store.begin_renewal.assert_called_once();store.finish_renewal.assert_not_called();store.release_renewal.assert_not_called()
            self.assertNotIn('synthetic-private-failure',json.dumps(result))
            if options.get('fail_child'):self.assertIsNone(result['authentication_posts_attempted'])

    def test_proven_zero_dispatch_can_release_only_the_owned_intent(self):
        code,result,store,_child=self.run_online(dry=True)
        self.assertEqual(code,1);self.assertFalse(result['keychain_intent_retained'])
        store.release_renewal.assert_called_once();self.assertTrue(store.release_renewal.call_args.kwargs['not_dispatched'])


if __name__=='__main__':unittest.main()
