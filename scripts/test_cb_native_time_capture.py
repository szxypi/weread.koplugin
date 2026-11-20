"""Isolated CB capture validation; synthetic content and in-memory storage."""
from contextlib import nullcontext
from copy import deepcopy
import base64
import json
import unittest
from unittest.mock import Mock,patch

from cb_native_time_capture_bundle import SERVICE
from native_time_capture import validate
from native_time_capture_bundle import CaptureBundleStore,SERVICE as PRIOR_SERVICE
from native_time_capture_evidence import validate_evidence
from secure_weread_session import StoreError
from test_native_time_capture import capture
from test_native_time_capture_evidence import make_fixture,bundle
from test_secure_native_session import Backend
from test_owner_reading import stage as reading_stage
import run_native_time_capture as runner
import run_native_time_bundle_inspect as inspector
import verify_cb_native_time_capture_inspect as supervisor


def fixture():
    plan=capture('web_xhtml','CB_Synthetic')
    _previous,ledger,coverage=make_fixture()
    ledger.execute('UPDATE windows SET book_id=?,file_id=?',(plan['book_id'],plan['file_id']))
    ledger.commit();proof=bundle(ledger,coverage);ledger.close();coverage.close()
    pieces={};backend=Backend()
    chunks=lambda index:pieces.setdefault(index,Backend())
    return plan,proof,backend,pieces,chunks


class ImportedCaptureTests(unittest.TestCase):
    def test_explicit_identity_and_full_epub_binding(self):
        plan,proof,_,_,_=fixture()
        with self.assertRaises(ValueError):validate(plan)
        self.assertEqual(validate(plan,imported=True),plan)
        self.assertEqual(validate_evidence(plan,proof,imported=True),proof)
        with self.assertRaises(ValueError):validate(capture('web_xhtml'),imported=True)
        for book in ('CB_','CB_bad/','CB_'+('A'*65),'42'):
            bad=deepcopy(plan);bad['book_id']=book;bad['rows'][0]['book_id']=book
            with self.subTest(book=book),self.assertRaises(ValueError):validate(bad,imported=True)
        for field,value in (('format','web_txt'),('file_id','f'*64),('owner','0'),('not_before',1)):
            bad=deepcopy(plan);bad[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):validate(bad,imported=True)

    def test_dedicated_store_roundtrip_and_no_replay(self):
        plan,proof,backend,pieces,chunks=fixture()
        self.assertNotEqual(SERVICE,PRIOR_SERVICE)
        with self.assertRaises(ValueError):CaptureBundleStore(imported=True)
        store=CaptureBundleStore(backend,chunks=chunks,lock=nullcontext,imported=True)
        receipt=store.capture(plan,proof)
        reopened=CaptureBundleStore(backend,chunks=chunks,lock=nullcontext,imported=True)
        self.assertEqual(reopened.read()[0],dict(plan=plan,evidence=proof))
        self.assertEqual(reopened.read()[1],receipt)
        with self.assertRaises(StoreError):store.capture(plan,proof)
        for name in ('claim','send','advance','delete','renew'):self.assertFalse(hasattr(store,name))
        pieces[1].data=b'corrupt'
        with self.assertRaises(StoreError):reopened.read()

    def test_cross_book_evidence_and_partial_save_fail_closed(self):
        plan,proof,backend,pieces,chunks=fixture();bad=deepcopy(plan);bad['file_id']='0'*64
        store=CaptureBundleStore(backend,chunks=chunks,lock=nullcontext,imported=True)
        with self.assertRaises(ValueError):store.capture(bad,proof)
        self.assertIsNone(backend.data)
        self.assertTrue(all(part.data is None for part in pieces.values()))
        numeric=capture('web_xhtml')
        with self.assertRaises(ValueError):store.capture(numeric,proof)

    def test_runner_binds_cb_stage_to_private_capture(self):
        plan,_,_,_,_=fixture()
        payload=dict(vid=plan['owner'],cookies={'wr_vid':plan['owner'],'wr_skey':'mock_key'},book_id=plan['book_id'],
            chapter_uid=plan['chapter_uid'],source_format=plan['format'],source_raw_sha256=plan['raw_sha256'],cb_reading=True,
            native_time_capture=dict(device_sha256=plan['device_sha256'],baseline_sha256=plan['baseline_sha256'],book_version=plan['book_version']))
        self.assertEqual(runner.payload_valid(payload,imported=True),payload)
        with self.assertRaises(ValueError):runner.payload_valid(payload)
        stage=reading_stage();stage['source_match_reason']='none'
        stage['native_time_capture']=dict(phase='complete',real_statistics=True,actual_clock=True,exact_source=True,
            ledger_reopened=True,same_day_deferred=True,seconds=plan['seconds'],rows=len(plan['rows']),
            archive_bytes=len(base64.b64decode(plan['archive_base64'])),failed_line=0)
        envelope=dict(report=stage,cookies=payload['cookies'],candidate_private=plan)
        frame=lambda value:b'\nWEREAD_OWNER_READING_RESULT='+json.dumps(value).encode()
        self.assertEqual(runner.decode(frame(envelope),payload,imported=True)[2],plan)
        for field,value in (('book_id','CB_Other'),('owner','900001'),('file_id','f'*64),('format','web_txt')):
            bad=deepcopy(envelope);bad['candidate_private'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):runner.decode(frame(bad),payload,imported=True)
        bad=deepcopy(envelope);bad['report']['source_match_reason']='other'
        with self.assertRaises(ValueError):runner.decode(frame(bad),payload,imported=True)

    def test_same_day_inspection_cannot_touch_other_scopes_or_claim(self):
        plan,proof,backend,_,chunks=fixture();store=CaptureBundleStore(backend,chunks=chunks,lock=nullcontext,imported=True)
        store.capture(plan,proof);bundle,receipt=store.read()
        self.assertEqual(inspector.validate_input(bundle,plan['ended_at'],imported=True),bundle)
        for stamp in (plan['ended_at']-1,plan['not_before']):
            with self.assertRaises(ValueError):inspector.validate_input(bundle,stamp,imported=True)
        with self.assertRaises(ValueError):inspector.validate_input(bundle,plan['ended_at'])
        expected=dict(result='SAME_DAY_DEFERRED',seconds=plan['seconds'],exact_rows=True,archive_verified=True,
                      coverage_verified=True,same_day_deferred=True,pending_unchanged=True,profile_removed=True,
                      account_data_posts=0,authentication_posts=0)
        for mode in ('success','missing_proof','unexpected_write','receipt_changed'):
            value=deepcopy(expected)
            if mode=='missing_proof':value['archive_verified']=False
            if mode=='unexpected_write':value['account_data_posts']=1
            process=Mock();process.returncode=0;process.communicate.return_value=(json.dumps(value).encode(),None)
            scoped=Mock();scoped.read.side_effect=[(bundle,receipt),(bundle,None) if mode=='receipt_changed' else (bundle,receipt)]
            with self.subTest(mode=mode),patch.object(supervisor.subprocess,'Popen',return_value=process),patch.object(supervisor,'stop'):
                if mode=='success':
                    report=supervisor.inspect(scoped,['synthetic-runner'],clock=lambda:plan['ended_at']+1)
                    self.assertTrue(report['saved_capture_unchanged'])
                    self.assertEqual(json.loads(process.communicate.call_args.args[0]),bundle)
                else:
                    with self.assertRaises(ValueError):supervisor.inspect(scoped,['synthetic-runner'],clock=lambda:plan['ended_at']+1)


if __name__=='__main__':unittest.main()
