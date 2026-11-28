"""Offline checks of the EPUB native first-sync test harness."""
import unittest
from unittest.mock import patch
from test_cb_unstarted_epub_position_fixture import Harness as EpubHarness
from test_cb_unstarted_native_ui_fixture import Harness as UiHarness
import verify_cb_unstarted_native_ui_fixture as task


class Harness(EpubHarness):
    runner=UiHarness.runner
    def __init__(self,mode='success'):
        super().__init__();self.ui_mode=mode;self.calls=[]
    def after(self,context,report):
        return task.ui_trial(context,report,self.grant,self.position_intent,self.position_evidence,['synthetic'],
                             runner=self.runner,attest=lambda:['synthetic'],fixture='epub')
    def execute_ui(self):
        with patch.object(task,'CbReadingProbe',side_effect=self.source_factory):
            return self.execute(after_time=self.after)


class EpubNativeUiTest(unittest.TestCase):
    def test_dry_run_then_one_confirmed_write(self):
        h=Harness(); result=h.execute_ui()
        self.assertEqual(result['result'],'UNSTARTED_TIME_FIXTURE_VERIFIED',result)
        self.assertEqual(h.calls,[False,True]); self.assertTrue(h.cleaned)
        self.assertTrue(result['position_probe']['counters_preserved'])
    def test_uncertainty_retains_fixture(self):
        for mode in ('lost','wrong_count'):
            h=Harness(mode); result=h.execute_ui()
            self.assertEqual(result['result'],'UNVERIFIED'); self.assertTrue(result['position_write_uncertain'])
            self.assertFalse(h.cleaned); self.assertEqual(h.calls,[False,True])
            self.assertEqual(h.execute_ui()['result'],'UNVERIFIED')


if __name__=='__main__': unittest.main()
