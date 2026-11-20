"""Actual-clock provenance and private bounded capture; no dispatch path."""
from contextlib import redirect_stdout
from copy import deepcopy
import io,json,unittest
from unittest.mock import patch
from readtime_history_capture import CaptureStore,validate,next_cst_day
from secure_weread_session import StoreError
from test_eink_login import Opener
from test_secure_native_session import Backend
from test_readtime_trial import fixture_trial,NOW
from selection_trial_mock import credentials
import verify_readtime_history_capture as capture


def fixture():
    trial,source,_op,clock,before,_stats,*_r=fixture_trial()
    metadata=dict(bookId=source.plan.bound['book_id'],version=source.plan.context['bookVersion'])
    source.prepare.return_value=source.plan
    opener=Opener([deepcopy(v) for v in (metadata,before,before,metadata)])
    task=capture.Capture(source,CaptureStore(Backend()),opener=opener,clock=lambda:clock[0],monotonic=lambda:clock[0],
        sleep=lambda n:clock.__setitem__(0,clock[0]+n))
    return task,source,opener,clock


class CaptureTests(unittest.TestCase):
    def invoke(self,task,**kwargs):
        with patch.object(capture,'reading_position',return_value=task.source.plan.web_position):
            return task.run({'vid':credentials()['vid']},credentials(),**kwargs)

    def test_defaults_and_invalid_status_do_not_open_keychain(self):
        for args in ([],['--status']):
            with patch.object(capture,'SessionStore') as web,patch.object(capture,'CaptureStore') as store,redirect_stdout(io.StringIO()) as out:
                self.assertEqual(capture.main(args),bool(args))
            web.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)

    def test_real_interval_captured_once_and_waits_for_next_cst_date(self):
        task,_source,op,_clock=fixture();report=self.invoke(task);state,r=task.store.read();p=state['plan']
        self.assertEqual(report['result'],'CAPTURED_NO_DISPATCH');self.assertFalse(report['future_write_granted'])
        self.assertEqual(p['start_time'],NOW);self.assertEqual(p['duration'],2);self.assertEqual(p['captured_at'],NOW+2)
        self.assertEqual(p['not_before'],next_cst_day(NOW)+1);self.assertGreater(p['not_before'],NOW+2)
        self.assertTrue(all(x.data is None for x in op.requests));self.assertEqual(len(op.requests),4)
        with self.assertRaises(ValueError):self.invoke(task)
        self.assertEqual(task.store.read()[1],r)
        self.assertFalse(hasattr(task.store,'claim'));self.assertFalse(hasattr(task.store,'finish'))

    def test_changed_version_counter_or_position_prevents_capture(self):
        for field in ('version','readingTime','recordReadingTime','position'):
            task,_source,op,_clock=fixture()
            if field=='version':op.responses[3]['version']+=1
            elif field=='position':op.responses[2]['book']['chapterOffset']+=1
            else:op.responses[2]['book'][field]+=1
            with self.subTest(field=field),self.assertRaises(ValueError):self.invoke(task)
            self.assertEqual(task.store.read(),(None,None));self.assertTrue(all(x.data is None for x in op.requests))

    def test_clock_jump_insufficient_wait_or_monotonic_mismatch_prevents_capture(self):
        for field in ('forward','backward','short','monotonic'):
            task,_source,_op,clock=fixture()
            if field=='forward':task.sleep=lambda n:clock.__setitem__(0,clock[0]+n+20)
            elif field=='backward':task.sleep=lambda n:clock.__setitem__(0,clock[0]-20)
            elif field=='short':task.sleep=lambda n:clock.__setitem__(0,clock[0]+1)
            else:task.monotonic=lambda:NOW
            with self.subTest(field=field),self.assertRaises(ValueError):self.invoke(task)
            self.assertEqual(task.store.read(),(None,None))

    def test_foreign_or_unverified_catalog_and_owner_prevents_capture(self):
        for field in ('catalog','boolean_version','owner'):
            task,source,_op,_clock=fixture()
            if field=='catalog':source.web.request.return_value['book']['version']+=1
            elif field=='boolean_version':source.web.request.return_value['book']['version']=True
            with self.subTest(field=field),self.assertRaises(ValueError):
                if field=='owner':task.run({'vid':'other'},credentials())
                else:self.invoke(task)
            self.assertEqual(task.store.read(),(None,None))

    def test_changed_originals_web_position_and_failed_handoff_prevents_capture(self):
        for field in ('originals','web','handoff'):
            task,source,_op,_clock=fixture()
            if field=='originals':source.baseline.side_effect=[{},ValueError('changed')]
            with self.subTest(field=field),patch.object(capture,'reading_position',return_value={} if field=='web' else source.plan.web_position):
                with self.assertRaises(Exception):
                    task.run({'vid':credentials()['vid']},credentials(),on_final=(lambda:(_i for _i in ()).throw(OSError())) if field=='handoff' else None)
            self.assertEqual(task.store.read(),(None,None))

    def test_plan_rejects_timestamp_edit_day_boundary_extra_fields_and_booleans(self):
        task,_source,_op,_clock=fixture();self.invoke(task);original=task.store.read()[0]['plan']
        for key,value in [('duration',True),('captured_at',NOW-86400),('start_time',NOW-86400),('not_before',NOW+100),
                          ('monotonic_elapsed_ms',100),('clock_elapsed_ms',3000),('extra',1)]:
            changed=deepcopy(original);changed[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate(changed)
        changed=deepcopy(original);changed['start_time']=next_cst_day(NOW)-1;changed['captured_at']=changed['start_time']+2
        changed['not_before']=next_cst_day(changed['start_time'])+1
        with self.assertRaises(ValueError):validate(changed)

    def test_corrupt_or_duplicate_capture_is_not_replaced(self):
        task,_source,_op,_clock=fixture();self.invoke(task);value,r=task.store.read();store=CaptureStore(task.store.backend)
        with self.assertRaises(StoreError):store.capture(value['plan'])
        self.assertEqual(store.read()[1],r)
        for patch_value in ({'scope':'foreign'},{'schema':True},{'phase':'claimed'}):
            corrupt=deepcopy(value);corrupt.update(patch_value);store.backend.data=json.dumps(corrupt).encode()
            with self.assertRaises(StoreError):store.read()
        store.backend.data=r.raw;store.backend.save=lambda raw:None
        other=CaptureStore(Backend());other.backend.save=lambda raw:None
        with self.assertRaises(StoreError):other.capture(value['plan'])

    def test_no_network_before_preparation_or_outside_read_whitelist(self):
        task,_source,op,_clock=fixture()
        for url,body in [(capture.BASE+'/book/info?bookId=42',None),(capture.BASE+'/book/batchUploadProgress',{}),(capture.BASE+'/login',{})]:
            with self.assertRaises(ValueError):task.request('outside',url,body,credentials())
        self.assertEqual(len(op.requests),0)


if __name__=='__main__':unittest.main()
