#!/usr/bin/env python3
"""Offline guard checks and optional actual native UI preflight."""
import argparse
from copy import deepcopy
import json
import unittest
from unittest.mock import patch

from annotation_experiment_model import digest
import cb_txt_highlight_trial as trial
from test_cb_fixture_highlight_trial import Fake
from test_cb_txt_highlight_trial import sample
from test_secure_native_session import Backend
import verify_cb_txt_note_navigation as verify


class NavigationTests(unittest.TestCase):
    def test_independently_returned_mark_and_source_are_required(self):
        source,baseline,plan,body=sample();fake=Fake(baseline,body);fake.send('create_pending',body,None)
        row=fake.current['marks']['updated']['new-synthetic-highlight']
        target=dict(id=row['bookmarkId'],sha256=digest(row))
        value=verify.payload('900000',source,body,target,fake.current)
        self.assertEqual(value['chapters'][0]['targets'][0]['chapter_offset'],48)
        for changed in (dict(source,book_id='CB_Wrong'),dict(source,source=source['source']+'extra'),
                        dict(source,source_format='web_xhtml')):
            with self.assertRaises(ValueError):verify.payload('900000',changed,body,target,fake.current)
        invalid=deepcopy(fake.current);invalid['marks']['updated'][target['id']]['markText']='different'
        with self.assertRaises(ValueError):verify.payload('900000',source,body,target,invalid)

    def test_callback_runs_after_confirmation_and_unexpected_state_prevents_delete(self):
        _,baseline,plan,body=sample();fake=Fake(baseline,body);intent=trial.Intent(Backend());called=[]
        def callback(value,target,read):
            self.assertEqual(value,body);self.assertEqual(intent.read()[0]['phase'],'created')
            self.assertEqual(read()['marks']['updated'][target['id']]['markText'],trial.TEXT);called.append(True)
        result=trial.execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send,on_created=callback)
        self.assertEqual(called,[True]);self.assertEqual(result['writes'],2);self.assertEqual(fake.current,baseline)
        fake=Fake(baseline,body);intent=trial.Intent(Backend())
        def changed(_body,_target,_read):fake.current['thoughts']['unexpected']={}
        with self.assertRaises(ValueError):trial.execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send,on_created=changed)
        self.assertEqual(fake.sent,['create_pending']);self.assertEqual(intent.read()[0]['phase'],'created')
        with self.assertRaises(Exception):trial.execute(plan,body,baseline,intent,fake.owned,fake.read,fake.send,on_created=callback)
        self.assertEqual(fake.sent,['create_pending'])

    def test_runner_wires_real_readback_to_both_screen_checks(self):
        source,baseline,_,_=sample();intent=trial.Intent(Backend());screens=[];fake_holder=[]
        def highlight_runner(*_args,**kwargs):
            plan,body=kwargs['prepare_fn']('900000',source['book_id'],'a'*32,source,1,baseline)
            fake=Fake(baseline,body);fake_holder.append(fake)
            kwargs['execute_fn'](plan,body,baseline,intent,fake.owned,fake.read,fake.send)
            return dict(result=kwargs['result_label'],annotation_posts=len(fake.sent))
        def fixture_run(*_args,**kwargs):return kwargs['runner']()
        def ui(command,data,width,height,dpi):
            self.assertEqual(command,['native']);self.assertEqual(data['chapters'][0]['rows'][0]['markText'],trial.TEXT)
            screens.append((width,height,dpi));return dict(width=width,height=height)
        with patch.object(verify.fixture,'run',side_effect=fixture_run):
            report=verify.run({},None,None,{},None,None,intent,['native'],apply=True,ui=ui,highlight_runner=highlight_runner)
        self.assertEqual(report['result'],'CB_TXT_NOTE_NAVIGATION_VERIFIED');self.assertEqual(screens,list(verify.SCREENS))
        self.assertEqual(fake_holder[0].sent,['create_pending','delete_pending'])
        self.assertNotIn(trial.TEXT,json.dumps(report));self.assertNotIn(source['book_id'],json.dumps(report))


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--native-command',nargs=argparse.REMAINDER)
    args=parser.parse_args();suite=unittest.defaultTestLoader.loadTestsFromTestCase(NavigationTests)
    if not unittest.TextTestRunner().run(suite).wasSuccessful():return 1
    if args.native_command:
        source,baseline,plan,body=sample();fake=Fake(baseline,body);fake.send('create_pending',body,None)
        row=fake.current['marks']['updated']['new-synthetic-highlight'];target=dict(id=row['bookmarkId'],sha256=digest(row))
        data=verify.payload('900000',source,body,target,fake.current)
        results=[verify.native_ui(args.native_command,data,*screen) for screen in verify.SCREENS]
        print(json.dumps(dict(result='PASS',native_ui=results,network_requests=0)))
    return 0


if __name__=='__main__':raise SystemExit(main())
