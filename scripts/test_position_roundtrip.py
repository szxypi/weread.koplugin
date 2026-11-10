"""Offline, synthetic experiments. No Keychain access or live account writes."""
from contextlib import redirect_stdout, redirect_stderr
import copy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import verify_position_roundtrip as task
from verify_source_coordinates import FilteredSource


def plan(source=None, summary='synthetic summary'):
    source = source or '<html><body><p>This original sentence provides a unique safe test position for validation.</p></body></html>'
    offset = FilteredSource(source).starts[0]
    raw = dict(book=dict(bookId='900001', chapterUid=2, chapterIdx=2, chapterOffset=offset, progress=25, summary=summary))
    context = dict(book_id='900001', psvts='synthetic-ps', pclts='synthetic-pc', token='synthetic-token', progress=raw)
    return task.prepare_plan('900001', raw, context, source)


class FakeProbe(task.RoundTripProbe):
    def __init__(self, ack=True, failure=None, concurrent=False, ignore_probe=False, failure_exception=None,
                 normalize_probe_percent=False,normalize_restore_percent=False):
        super().__init__()
        self.plan=plan(); self.scope_vid=self.vid='900000'; self.book_id='900001'; self.authenticated=True
        self.set_cookie('wr_vid',self.vid); self.set_cookie('wr_skey','synthetic-only-key')
        self.current=copy.deepcopy(self.plan['baseline'])
        self.sent=[]; self.ack=ack; self.failure=failure; self.concurrent=concurrent; self.ignore_probe=ignore_probe
        self.failure_exception=failure_exception or task.PreflightError('synthetic_uncertain_transport')
        self.normalize_probe_percent=normalize_probe_percent;self.normalize_restore_percent=normalize_restore_percent

    def request(self, stage, url, body=None, **options):
        self.guard(stage,url,body)
        self.sent.append((stage,copy.deepcopy(body)))
        if stage=='write_probe' and not self.ignore_probe:
            self.current=copy.deepcopy(self.plan['target'])
            if self.normalize_probe_percent:self.current['raw_percent']+=1
            if self.concurrent:self.current['chapter_offset']+=10
        elif stage=='write_restore':
            self.current=copy.deepcopy(self.plan['baseline'])
            if self.normalize_restore_percent:self.current['raw_percent']+=1
        if stage==self.failure:raise self.failure_exception
        return dict(succ=1) if self.ack else {}

    def read_position(self):
        return copy.deepcopy(self.current)


class PositionRoundTripTests(unittest.TestCase):
    def test_default_never_opens_credentials_or_network(self):
        with patch.object(task,'SessionStore') as store, patch.object(task,'RoundTripProbe') as web, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();web.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['account_data_writes_attempted'],0)

    def test_apply_requires_session_and_explicit_mode(self):
        for args in (['--apply'],['--saved-session','--apply'],['--mode','probe'],
                     ['--saved-session','--apply','--mode','probe'],
                     ['--saved-session','--apply','--mode','probe','--book-id','900001']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--lua-command','synthetic'])

    def test_private_lua_model_compares_all_fields_without_any_http(self):
        output=dict(stages=[dict(stage=stage,matches=True,mismatched_fields=[]) for stage in task.WRITE_ORDER],http_requests=0)
        result=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_POSITION_PAYLOAD_RESULT='+json.dumps(output).encode())
        with patch.object(task.subprocess,'run',return_value=result) as child:
            public=task.verify_lua_payloads(plan(),['synthetic'])
        self.assertEqual(public,dict(lua_payload_model_verified=True,lua_payloads_compared=4,lua_http_requests=0))
        private=json.loads(child.call_args.kwargs['input'])
        self.assertEqual(len(private['samples']),4)
        self.assertNotIn('cookies',private)
        for sample in private['samples']:
            self.assertIn('synthetic-ps',sample['options']['psvts'])
            if sample['stage']!='write_enter':self.assertEqual(sample['expected']['rt'],0)
        self.assertNotIn('synthetic-ps',json.dumps(public))

    def test_lua_model_refuses_incomplete_or_mutated_contracts(self):
        clean=dict(stages=[dict(stage=stage,matches=True,mismatched_fields=[]) for stage in task.WRITE_ORDER],http_requests=0)
        invalid=[]
        for key,value in [('http_requests',1),('http_requests',False),('stages',[]),('private','private-content')]:
            item=copy.deepcopy(clean);item[key]=value;invalid.append(item)
        item=copy.deepcopy(clean);item['stages'][1]['mismatched_fields']=['co'];invalid.append(item)
        item=copy.deepcopy(clean);item['stages'][0]['matches']=1;invalid.append(item)
        for output in invalid:
            result=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_POSITION_PAYLOAD_RESULT='+json.dumps(output).encode())
            with self.subTest(kind=type(output)),patch.object(task.subprocess,'run',return_value=result),self.assertRaises(task.RoundTripError):
                task.verify_lua_payloads(plan(),['synthetic'])

    def test_lua_model_private_failure_output_is_not_in_diagnostics(self):
        result=SimpleNamespace(returncode=1,stdout=b'private session value')
        with patch.object(task.subprocess,'run',return_value=result),self.assertRaises(task.RoundTripError) as caught:
            task.verify_lua_payloads(plan(),['synthetic'])
        self.assertEqual(str(caught.exception),'roundtrip_lua_model_failed')

    def test_long_or_missing_summary_has_an_explicit_preview_change(self):
        value=plan(summary='a'*30)
        self.assertFalse(value['same_position_summary_preserved'])
        self.assertEqual(len(value['baseline']['summary']),20)
        self.assertIsNotNone(value['target'])
        self.assertEqual(value['target']['chapter_offset']-value['baseline']['chapter_offset'],1)

    def test_payloads_are_same_book_and_zero_time(self):
        value=plan()
        for stage in task.WRITE_ORDER:
            body=task.payload(value,stage)
            self.assertTrue(task.validate_payload(value,stage,body))
            if stage=='write_enter':self.assertNotIn('rt',body)
            else:self.assertEqual(body['rt'],0)
        self.assertIs(type(task.payload(value,'write_same')['pr']),int)

    def test_signed_but_tampered_payloads_are_still_rejected(self):
        value=plan()
        for key,bad in [('b','other'),('c','other'),('ci',True),('co',True),('co',12345),('pr',True),
                        ('pr',26),('rt',10),('ps','other'),('pc','other'),('appId','other'),('sm','other'),('sg','bad')]:
            body=task.payload(value,'write_probe');body[key]=bad
            body['s']=task.weread_sign(task.sorted_query({k:v for k,v in body.items() if k!='s'}))
            with self.subTest(key=key,bad=bad),self.assertRaises(task.RoundTripError):task.validate_payload(value,'write_probe',body)

    def test_preview_transport_has_no_write_authority(self):
        web=FakeProbe();body=task.payload(web.plan,'write_enter')
        with self.assertRaises(task.PreflightError):web.guard('write_enter',task.WRITE_URL,body)
        for url in ('https://weread.qq.com/web/login/renewal','https://weread.qq.com/web/shelf/add'):
            with self.assertRaises(task.PreflightError):web.guard('unexpected',url,{})
        self.assertEqual(web.writes,0)
        web.mode='same';body=task.payload(web.plan,'write_probe');web.pending=('write_probe',task.canonical(body))
        with self.assertRaises(task.PreflightError):web.guard('write_probe',task.WRITE_URL,body)

    def test_foreign_owner_is_rejected_before_sending(self):
        web=FakeProbe();web.mode='probe';web.set_cookie('wr_vid','900099')
        with self.assertRaises(task.PreflightError):web.send('write_enter')
        self.assertEqual(web.writes,0);self.assertEqual(web.sent,[]);self.assertIsNone(web.pending)

    def test_same_position_requires_ack_for_a_success_claim(self):
        for ack,expected in ((True,'SAME_POSITION_ACKNOWLEDGED'),(False,'SAME_POSITION_UNCONFIRMED')):
            web=FakeProbe(ack=ack);report={}
            self.assertEqual(web.execute('same',report),expected)
            self.assertEqual([row[0] for row in web.sent],['write_enter','write_same'])
            self.assertTrue(task.same_position(web.current,web.plan['baseline']))
            self.assertTrue(report['restoration_verified'])

    def test_probe_readback_and_conditional_restore(self):
        for ack in (True,False):
            web=FakeProbe(ack=ack);report={}
            self.assertEqual(web.execute('probe',report),'ONE_CHARACTER_ROUNDTRIP_VERIFIED')
            self.assertEqual([row[0] for row in web.sent],list(task.WRITE_ORDER))
            self.assertEqual(web.writes,4)
            self.assertTrue(report['probe_observed'] and report['restoration_verified'])
            self.assertTrue(task.same_position(web.current,web.plan['baseline']))

    def test_applied_but_uncertain_probe_is_restored_without_replaying_it(self):
        web=FakeProbe(failure='write_probe');report={}
        with self.assertRaises(task.PreflightError):web.execute('probe',report)
        self.assertEqual([row[0] for row in web.sent],list(task.WRITE_ORDER))
        self.assertTrue(report['restoration_verified'])

    def test_interrupt_after_probe_attempt_still_checks_and_restores_once(self):
        web=FakeProbe(failure='write_probe',failure_exception=KeyboardInterrupt());report={}
        with self.assertRaises(KeyboardInterrupt):web.execute('probe',report)
        self.assertEqual([row[0] for row in web.sent],list(task.WRITE_ORDER))
        self.assertTrue(report['restoration_verified'])

    def test_uncertain_restore_has_no_post_replay_or_false_confirmation(self):
        web=FakeProbe(failure='write_restore');report={}
        with self.assertRaises(task.PreflightError):web.execute('probe',report)
        self.assertEqual(web.writes,4)
        self.assertNotIn('restoration_verified',report)

    def test_concurrent_reader_position_is_never_restored_over(self):
        web=FakeProbe(concurrent=True);report={}
        with self.assertRaises(task.RoundTripError):web.execute('probe',report)
        self.assertEqual(len(web.sent),3)
        self.assertTrue(report['concurrent_position_detected'])
        self.assertNotEqual(web.current['chapter_offset'],web.plan['baseline']['chapter_offset'])

    def test_missing_probe_effect_does_not_trigger_a_post_retry(self):
        web=FakeProbe(ignore_probe=True);report={}
        with patch.object(task.time,'sleep'):
            self.assertEqual(web.execute('probe',report),'ROUNDTRIP_UNCONFIRMED')
        self.assertEqual(len(web.sent),3)
        self.assertFalse(report['probe_observed']);self.assertTrue(report['restoration_verified'])

    def test_server_normalized_metadata_does_not_prevent_a_bounded_restore(self):
        web=FakeProbe(normalize_probe_percent=True);report={}
        self.assertEqual(web.execute('probe',report),'ONE_CHARACTER_ROUNDTRIP_VERIFIED')
        self.assertFalse(report['probe_metadata_unchanged'])
        self.assertTrue(report['original_coordinates_restored'] and report['restoration_verified'])
        web=FakeProbe(normalize_restore_percent=True);report={}
        with patch.object(task.time,'sleep'):
            self.assertEqual(web.execute('probe',report),'ROUNDTRIP_UNCONFIRMED')
        self.assertTrue(report['original_coordinates_restored'])
        self.assertFalse(report['restoration_verified'])
        self.assertEqual(web.writes,4)

    def test_changed_baseline_aborts_before_any_post(self):
        web=FakeProbe();web.current['chapter_offset']+=20
        with self.assertRaises(task.RoundTripError):web.execute('probe',{})
        self.assertEqual(web.writes,0)

    def test_probe_does_not_split_a_combining_character(self):
        value=plan(source='<html><body><p>e\u0301This unique sentence provides enough original text for a safe source anchor.</p></body></html>')
        self.assertIsNone(value['target'])
        web=FakeProbe();web.plan=value
        with self.assertRaises(task.RoundTripError):web.execute('probe',{})
        self.assertEqual(web.writes,0)

    def test_bounded_probe_and_send_order(self):
        web=FakeProbe();web.mode='same'
        with self.assertRaises(task.RoundTripError):web.send('write_probe')
        web.send('write_enter');web.send('write_same')
        with self.assertRaises(task.RoundTripError):web.send('write_probe')
        for value in (dict(succ=0),dict(errCode=-1),dict(errcode=False),dict(errcode=0,errCode=-1)):
            with self.assertRaises(task.RoundTripError):task.acknowledged(value)

    def test_preview_main_is_private_and_does_not_call_execute(self):
        web=MagicMock();web.prepare.return_value=plan();web.writes=0;web.report=dict(stages=[])
        with patch.object(task,'SessionStore') as store,patch.object(task,'RoundTripProbe',return_value=web),\
                patch.object(task,'save_refreshed_web_session',return_value=False),redirect_stdout(io.StringIO()) as out:
            store.return_value.load.side_effect=lambda:dict(vid='88008800',cookies=dict(wr_skey='private-key-sentinel'))
            self.assertEqual(task.main(['--saved-session','--mode','probe']),0)
        web.execute.assert_not_called();web.close.assert_called_once()
        for private in ('88008800','900001','private-key-sentinel','synthetic-token'):
            self.assertNotIn(private,out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['result'],'READONLY_ROUNDTRIP_PREVIEW_READY')

    def test_explicit_apply_cli_pins_owner_and_reports_only_public_results(self):
        for owner,expected_code in (('900000',0),('900099',1)):
            web=FakeProbe();web.prepare=MagicMock(return_value=web.plan);web.verify_account=MagicMock()
            with patch.object(task,'SessionStore') as store,patch.object(task,'RoundTripProbe',return_value=web),\
                    patch.object(task,'save_refreshed_web_session',return_value=False),redirect_stdout(io.StringIO()) as out:
                store.return_value.load.side_effect=lambda:dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-only-key'))
                self.assertEqual(task.main(['--saved-session','--book-id','900001','--expected-owner',owner,
                                            '--mode','probe','--apply']),expected_code)
            result=json.loads(out.getvalue())
            self.assertEqual(result['account_data_writes_attempted'],4 if expected_code==0 else 0)
            if expected_code==0:self.assertEqual(result['result'],'ONE_CHARACTER_ROUNDTRIP_VERIFIED')
            for private in ('900000','900001','synthetic-only-key','synthetic-token'):
                self.assertNotIn(private,out.getvalue())


if __name__=='__main__':unittest.main()
