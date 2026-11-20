import unittest

from cb_fixture_close_intent import Intent as CloseIntent
from cb_fixture_timer_intent import Intent as TimerIntent
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_txt_manual_fixture_ui_trial import Harness
from verify_cb_txt_auto_fixture_ui_trial import auto_trial


class AutoTrialTest(unittest.TestCase):
    def make(self):
        h=Harness();timer=TimerIntent(backend=MemoryBackend());close=CloseIntent(backend=MemoryBackend())
        return h,timer,close

    def test_both_modes_and_sizes_are_independently_guarded(self):
        h,timer,close=self.make();calls=[]
        def dry(command,payload,width,height,dpi):
            calls.append(('dry',width));return h.runner(command,payload,width,height,dpi)
        def auto(_command,payload,width,_height,_dpi):
            calls.append(('timer' if payload.get('timer') else 'close',width))
            self.assertTrue(payload['armed']);self.assertEqual(payload['source_format'],'web_txt')
            h.current.update(chapterOffset=payload['first_offset'],summary=payload['timer_summary'])
            return True
        self.assertTrue(auto_trial(h.context,h.report,timer,close,['auto'],dry_runner=dry,auto_runner=auto,attest=lambda:['auto']))
        self.assertEqual(calls,[('dry',600),('timer',600),('dry',1264),('timer',1264),
                                ('dry',600),('close',600),('dry',1264),('close',1264)])
        self.assertEqual(h.report['position_writes_known'],13);self.assertFalse(h.report['position_writes_uncertain'])
        self.assertEqual(len(h.report['auto_stages']),4)
        with self.assertRaises(Exception):
            auto_trial(h.context,h.report,timer,close,['auto'],dry_runner=dry,auto_runner=auto,attest=lambda:['auto'])

    def test_uncertain_auto_result_does_not_continue_or_replay(self):
        h,timer,close=self.make();calls=[]
        def dry(*_args):calls.append('dry');return True
        def fail(*_args):calls.append('auto');return False
        self.assertFalse(auto_trial(h.context,h.report,timer,close,['auto'],dry_runner=dry,auto_runner=fail,attest=lambda:['auto']))
        self.assertEqual(calls,['dry','auto']);self.assertTrue(h.report['position_writes_uncertain'])
        self.assertIsNone(close.backend.load())
        with self.assertRaises(Exception):auto_trial(h.context,h.report,timer,close,['auto'],dry_runner=dry,auto_runner=fail,attest=lambda:['auto'])

    def test_changed_shelf_or_progress_after_dry_stops_before_writes(self):
        h,timer,close=self.make();calls=[]
        def dry(*_args):h.current['chapterOffset']+=1;return True
        def auto(*_args):calls.append('write');return True
        with self.assertRaises(ValueError):
            auto_trial(h.context,h.report,timer,close,['auto'],dry_runner=dry,auto_runner=auto,attest=lambda:['auto'])
        self.assertEqual(calls,[]);self.assertFalse(h.report['position_writes_uncertain'])
        h,timer,close=self.make();h.context['shelf_current']=lambda:False
        self.assertFalse(auto_trial(h.context,h.report,timer,close,['auto'],dry_runner=dry,auto_runner=auto,attest=lambda:['auto']))
        self.assertEqual(calls,[])


if __name__=='__main__':unittest.main()
