"""Offline authorization, one-use intent, source binding and failure gates."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import hashlib
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cb_cloud_position import observed
from cb_existing_position_intent import Intent
from mock_weread import CB_READING_ID,CHAPTERS,MockServer,chapter_html
from test_cb_fixture_position_transport import MemoryBackend
from verify_source_coordinates import FilteredSource
import verify_cb_fixture_reconnect_trial as task


class ReconnectTests(unittest.TestCase):
    def setUp(self):
        self.server=MockServer(0);self.server.cb_reading=True;self.server.content_format='epub'
        source=chapter_html(1);model=FilteredSource(source)
        first=model.locate('这是第1章的第16段。我们沿着小路慢慢前行')[0]
        summary=''.join(c for c in model.anchor_at(first,size=96) if not c.isspace())[:20]
        self.server.progress[CB_READING_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary=summary)
        self.context=dict(sample=dict(source=source,chapters=CHAPTERS),plan=dict(book=CB_READING_ID,chapter='1',index=1,first=first),
            chapters=CHAPTERS,pair=self.pair,authority=lambda:True,shelf_current=lambda:True,
            cookies=lambda:dict(wr_vid='900000',wr_skey='synthetic-cookie-session'),owner='900000',attempt='a'*32,
            source_hash='b'*64,target=CB_READING_ID,attest=lambda:['first'],command=['first'])
        self.context['initial_observed']={name:observed(raw,CB_READING_ID,CHAPTERS,name) for name,raw in zip(('native','web'),self.pair())}
        self.intent=Intent(backend=MemoryBackend());self.report=dict(position_writes_known=1,position_writes_uncertain=False)
        self.phases=[];self.writes=0;self.fail=None
    def tearDown(self):self.server.server_close()
    def pair(self):
        web=self.server.get_progress(CB_READING_ID);native=deepcopy(web)
        native['book'].update(readingTime=0,recordReadingTime=0,ttsTime=0)
        return native,web
    def runner(self,_command,payload,_width,_height,_dpi):
        mode='discover' if payload.get('reconnect_discover') else 'armed' if payload['armed'] else 'dry'
        self.phases.append(mode)
        if mode==self.fail:raise ValueError('synthetic failure')
        if mode=='discover':return dict(result='DISCOVERED',offset=payload['first_offset']+1)
        if mode=='dry':return dict(result='DRY_RUN')
        self.writes+=2;self.server.progress[CB_READING_ID].update(chapterOffset=payload['next_offset'],summary=payload['expected_summary'])
        return dict(result='PASS')
    def run_trial(self):return task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=self.runner,attest=lambda:['runner'])
    def test_offline_default_does_not_load_sessions(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_two_screen_sequence_uses_a_new_bound_intent_once(self):
        self.assertTrue(self.run_trial());self.assertEqual(self.phases,['discover','dry','armed']*2)
        self.assertEqual(self.writes,4);self.assertEqual(self.report['position_writes_known'],5)
        self.assertFalse(self.report['position_writes_uncertain']);self.assertEqual(len(self.report['reconnect_stages']),2)
        with self.assertRaises(Exception):self.run_trial()
        self.assertEqual(self.writes,4)
    def test_failures_stop_before_later_writes_and_keep_the_intent(self):
        for mode in ('discover','dry','armed'):
            with self.subTest(mode=mode):
                self.tearDown();self.setUp();self.fail=mode
                with self.assertRaises(ValueError):self.run_trial()
                self.assertEqual(self.writes,0);self.assertEqual(len(self.report['reconnect_stages']),0)
                self.assertEqual(self.report['position_writes_uncertain'],mode=='armed')
                self.assertIsNotNone(self.intent.backend.load());self.tearDown()
    def test_shelf_or_account_change_prevents_any_dispatch(self):
        for field in ('authority','shelf_current'):
            self.context[field]=lambda:False
            self.assertFalse(self.run_trial());self.assertEqual(self.phases,[]);self.assertEqual(self.writes,0)
            self.intent=Intent(backend=MemoryBackend());self.context[field]=lambda:True
    def test_resume_only_accepts_exact_unclaimed_intent(self):
        fingerprint=hashlib.sha256((self.context['source_hash']+':'+str(self.context['plan']['first'])).encode()).hexdigest()
        reserved=self.intent.reserve(self.context['owner'],self.context['target'],self.context['attempt'],fingerprint)
        self.assertTrue(task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=self.runner,
                                             attest=lambda:['runner'],resume=True))
        self.assertEqual(self.writes,4)
        with self.assertRaises(ValueError):
            task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=self.runner,attest=lambda:['runner'],resume=True)
        self.assertEqual(self.writes,4)
        self.intent=Intent(backend=MemoryBackend());reserved=self.intent.reserve(self.context['owner'],self.context['target'],self.context['attempt'],fingerprint)
        self.intent.claim(reserved,'write_enter');self.phases=[]
        with self.assertRaises(ValueError):
            task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=self.runner,attest=lambda:['runner'],resume=True)
        self.assertEqual(self.phases,[])
    def test_resume_rejects_wrong_source_or_account_before_dispatch(self):
        self.intent.reserve(self.context['owner'],self.context['target'],self.context['attempt'],'c'*64)
        with self.assertRaises(ValueError):
            task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=self.runner,attest=lambda:['runner'],resume=True)
        self.assertEqual(self.phases,[]);self.assertEqual(self.writes,0)

    def test_changed_cloud_after_preview_blocks_dispatch(self):
        original=self.runner
        def altered(command,payload,width,height,dpi):
            result=original(command,payload,width,height,dpi)
            if payload.get('reconnect_discover'):
                self.server.progress[CB_READING_ID]['chapterOffset']+=3
            return result
        with self.assertRaises(ValueError):
            task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=altered,attest=lambda:['runner'])
        self.assertEqual(self.phases,['discover']);self.assertEqual(self.writes,0)
        self.assertIsNotNone(self.intent.backend.load())
    def test_discovery_cannot_reuse_cloud_offset(self):
        def same(_command,payload,_width,_height,_dpi):
            self.phases.append('discover');return {'result':'DISCOVERED','offset':payload['first_offset']}
        self.assertFalse(task.reconnect_trial(self.context,self.report,self.intent,['runner'],runner=same,attest=lambda:['runner']))
        self.assertEqual(self.phases,['discover']);self.assertEqual(self.writes,0)
    def test_injected_uploader_receives_exact_multipage_fixture(self):
        manual=Intent(backend=MemoryBackend());calls=[]
        def fake_first(_saved,_session,_native,grant,journal,_initial,_command,*,apply,uploader,after_verified):
            uploader(None,journal,grant,lambda _v:True,lambda _v:True,apply=apply,cleanup_gate=lambda *_:True)
            return {'result':'READ_ONLY_PREVIEW'}
        def fake_upload(*_args,**kwargs):calls.append(kwargs);return {'result':'READ_ONLY_PREVIEW'}
        result=task.execute({},None,None,{},object(),None,manual,['first'],['second'],first=fake_first,upload=fake_upload)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertIs(calls[0]['fixture_builder'],task.build_reading)
        self.assertIs(calls[0]['prepare_plan'],task.prepare_plan);self.assertIs(calls[0]['check_plan'],task.check_plan)

    def test_repeated_excerpt_requires_unique_surrounding_source(self):
        repeated='shared phrase with repeated words and punctuation. '*5
        raw='<body><p>First unique prefix '+repeated+' first suffix.</p><p>Second distinct prefix '+repeated+' second suffix.</p></body>'
        model=FilteredSource(raw);indices=[i for i,c in enumerate(model.characters) if c=='s' and ''.join(model.characters[i:i+13])=='shared phrase']
        self.assertEqual(len(indices),10);offset=model.starts[indices[0]]
        from verify_source_coordinates import CoordinateError
        with self.assertRaises(CoordinateError):model.anchor_at(offset,size=96)
        expected=''.join(c for c in model.characters[indices[0]:] if not c.isspace())[:20]
        self.assertEqual(task.source_summary(model,offset),expected)
        with self.assertRaises(ValueError):task.source_summary(model,True)
        long='identical repeated text '*100
        model=FilteredSource('<body><p>prefix '+long+'</p><p>prefix '+long+'</p></body>')
        offset=model.starts[model.characters.index('i')+200]
        with self.assertRaises(ValueError):task.source_summary(model,offset)

    def test_invalid_scope_never_launches_a_runner(self):
        for value in ({'reconnect':False,'armed':True},{'reconnect':True,'armed':1},
                      {'reconnect':True,'armed':True,'reconnect_discover':True}):
            with self.subTest(value=value),patch.object(task.subprocess,'run') as child,self.assertRaises(ValueError):
                task.run_ui(['synthetic'],value,600,800,167)
            child.assert_not_called()
    def test_interrupted_outer_apply_does_not_claim_zero_writes(self):
        manual=Intent(backend=MemoryBackend())
        def interrupted(*_args,**_kwargs):return {'result':'UNVERIFIED','phase':'unknown','account_data_writes_known':0}
        result=task.execute({},None,None,{},None,None,manual,['first'],['second'],apply=True,first=interrupted)
        self.assertIsNone(result['account_data_writes_known']);self.assertTrue(result['position_writes_uncertain'])

    def test_exact_runner_report_rejects_missing_guards(self):
        payload=dict(armed=False,reconnect=True,reconnect_discover=True)
        good=dict(result='DISCOVERED',offset=42,profile_removed=True,installed_bytes_match=True,offline_intent=True,
                  writes=0,denied=0,credentials_not_persisted=True)
        for value,valid in ((good,True),(dict(good,offset=True),False),(dict(good,writes=1),False),(dict(good,profile_removed=False),False)):
            with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())):
                if valid:self.assertEqual(task.run_ui(['synthetic'],payload,600,800,167),value)
                else:
                    with self.assertRaises(ValueError):task.run_ui(['synthetic'],payload,600,800,167)

if __name__=='__main__':unittest.main()
