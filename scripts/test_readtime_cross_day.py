"""Aged real captures can be checked, never dispatched or rewritten."""
from contextlib import redirect_stdout
from copy import deepcopy
import io,json,unittest
from unittest.mock import patch
from annotation_experiment_model import digest
from selection_trial_mock import credentials
from test_eink_login import Opener
from test_readtime_history_capture import fixture as capture_fixture
from test_readtime_trial import fixture_trial
import verify_readtime_cross_day as cross


def fixture():
    capture,source,_op,clock=capture_fixture()
    with patch('verify_readtime_history_capture.reading_position',return_value=source.plan.web_position):
        capture.run({'vid':credentials()['vid']},credentials())
    plan=capture.store.read()[0]['plan'];clock[0]=plan['not_before']+10
    _trial,_source,_op,_clock,progress,stats,*_rest=fixture_trial();progress['timestamp']=int(clock[0])
    metadata=dict(bookId=plan['source']['book_id'],version=plan['book_version'])
    source.prepare.reset_mock();source.baseline.reset_mock()
    op=Opener([deepcopy(v) for _i in range(2) for v in (metadata,progress,stats)])
    task=cross.Preflight(source,capture.store,opener=op,clock=lambda:clock[0],sleep=lambda n:clock.__setitem__(0,clock[0]+n))
    return task,source,op,clock


class CrossDayTests(unittest.TestCase):
    def invoke(self,task,**kwargs):
        with patch.object(cross,'reading_position',return_value=task.source.plan.web_position):
            return task.run({'vid':credentials()['vid']},credentials(),**kwargs)

    def test_default_is_offline(self):
        with patch.object(cross,'SessionStore') as store,patch.object(cross,'Preflight') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cross.main([]),0)
        store.assert_not_called();probe.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_two_fresh_reads_do_not_change_capture_or_grant_dispatch(self):
        task,source,op,_clock=fixture();old=task.store.read();result=self.invoke(task)
        self.assertEqual(result['result'],'PASS_CROSS_DAY_READONLY');self.assertEqual(task.store.read(),old)
        self.assertFalse(result['future_write_granted']);self.assertFalse(result['historical_accounting_verified'])
        self.assertEqual(len(op.requests),6);self.assertTrue(all(x.data is None for x in op.requests))
        source.prepare.assert_called_once_with({'vid':credentials()['vid']},credentials(),existing=old[0]['plan']['source'])
        self.assertEqual(source.baseline.call_count,3);source.writer.request.assert_not_called()
        with self.assertRaises(ValueError):self.invoke(task)

    def test_not_ready_missing_capture_foreign_device_and_owner_stop_before_network(self):
        for kind in ('early','missing','device','owner'):
            task,source,op,clock=fixture();grant=credentials();saved={'vid':grant['vid']}
            if kind=='early':clock[0]=task.store.read()[0]['plan']['not_before']-1
            elif kind=='missing':task.store.backend.data=None
            elif kind=='device':grant['deviceId']='other-device'
            else:saved['vid']='other-owner'
            with self.subTest(kind=kind),self.assertRaises(ValueError):task.run(saved,grant)
            self.assertEqual(len(op.requests),0);source.prepare.assert_not_called()

    def test_native_version_position_counter_or_server_clock_change_stops(self):
        for kind in ('version','position','readingTime','recordReadingTime','ttsTime','server_clock','early_server','boolean_stamp'):
            task,_source,op,_clock=fixture();old=task.store.read()
            if kind=='version':op.responses[3]['version']+=1
            elif kind=='position':op.responses[4]['book']['chapterOffset']+=1
            elif kind in ('readingTime','recordReadingTime','ttsTime'):op.responses[4]['book'][kind]+=1
            elif kind=='boolean_stamp':op.responses[4]['timestamp']=True
            elif kind=='early_server':op.responses[4]['timestamp']=old[0]['plan']['not_before']-1
            else:op.responses[4]['timestamp']+=100
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.invoke(task)
            self.assertEqual(task.store.read(),old);self.assertTrue(all(x.data is None for x in op.requests))

    def test_source_or_catalog_change_stops(self):
        for kind in ('source','catalog','version','boolean'):
            task,source,op,_clock=fixture()
            if kind=='source':source.prepare.side_effect=ValueError('selection_trial/changed')
            elif kind=='catalog':source.web.request.return_value['updated']=[]
            else:source.web.request.return_value['book']['version']=True if kind=='boolean' else source.plan.context['bookVersion']+1
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.invoke(task)
            self.assertEqual(len(op.requests),0)

    def test_statistics_change_or_wrong_month_stops(self):
        for kind in ('totalReadTime','readDays','bucket','baseTime'):
            task,_source,op,_clock=fixture();old=task.store.read()
            if kind=='bucket':op.responses[5]['readTimes'][next(iter(op.responses[5]['readTimes']))]+=1
            else:op.responses[5][kind]+=1
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.invoke(task)
            self.assertEqual(task.store.read(),old)

    def test_historical_month_is_requested_instead_of_current_month(self):
        task,_source,op,clock=fixture();clock[0]+=40*86400
        for index in (1,4):op.responses[index]['timestamp']=int(clock[0])
        self.invoke(task)
        month=cross.period('monthly',task.store.read()[0]['plan']['start_time'])[0]
        self.assertNotEqual(month,cross.period('monthly',clock[0])[0])
        self.assertTrue(all(x.full_url.endswith('baseTime='+str(month)) for x in (op.requests[2],op.requests[5])))

    def test_web_source_callback_and_capture_replacement_stop(self):
        for kind in ('web','source','callback','replace'):
            task,source,_op,_clock=fixture();old=task.store.read()
            if kind=='source':source.baseline.side_effect=ValueError('selection_trial/changed')
            def final():
                if kind=='replace':task.store.backend.data=None
                if kind=='callback':raise OSError('synthetic')
            with self.subTest(kind=kind),patch.object(cross,'reading_position',return_value={} if kind=='web' else source.plan.web_position),self.assertRaises(Exception):
                task.run({'vid':credentials()['vid']},credentials(),on_final=final)
            if kind!='replace':self.assertEqual(task.store.read(),old)

    def test_timeout_does_not_retry_and_transport_blocks_all_writes(self):
        task,_source,op,_clock=fixture();op.responses[1]=TimeoutError()
        with self.assertRaises(Exception):self.invoke(task)
        self.assertEqual(len(op.requests),2)
        for url,body in ((cross.BASE+'/login',{}),(cross.BASE+'/book/batchUploadProgress',{}),(cross.BASE+'/book/getProgress?bookId=42',None)):
            with self.assertRaises(ValueError):task.request('outside',url,body,credentials())
        self.assertEqual(len(op.requests),2)

    def test_changed_grant_never_reaches_transport(self):
        task,source,op,_clock=fixture();source.baseline.side_effect=lambda *_args: setattr(task,'grant',digest({'foreign':'grant'}))
        with self.assertRaises(ValueError):self.invoke(task)
        self.assertEqual(len(op.requests),0)

    def test_main_reports_fixed_transport_status_and_hides_arbitrary_errors(self):
        from unittest.mock import Mock
        for failure in (ValueError('selection_trial/changed'),ValueError('private title or token')):
            probe=Mock();probe.run.side_effect=failure
            for transport in (probe,probe.source.notes,probe.source.web):
                transport.report={'stages':[dict(stage='saved_shelf',status=401,headers='private header')]}
            with patch.object(cross,'SessionStore'),patch.object(cross,'NativeSessionStore'),patch.object(cross,'Preflight',return_value=probe),redirect_stdout(io.StringIO()) as out:
                self.assertEqual(cross.main(['--saved-session']),1)
            report=json.loads(out.getvalue());self.assertNotIn('private',out.getvalue())
            self.assertEqual(report['stages']['source_native'],[dict(stage='saved_shelf',status=401)])
            self.assertEqual(report.get('reason'),'selection_trial/changed' if str(failure).startswith('selection_trial/') else None)
            probe.source.web.close.assert_called_once();self.assertFalse(report['future_write_granted'])


if __name__=='__main__':unittest.main()
