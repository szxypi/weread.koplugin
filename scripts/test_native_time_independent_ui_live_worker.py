"""The shared UI worker enforces dry/live and loopback account boundaries."""
from contextlib import ExitStack
from io import BytesIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch
import run_native_time_independent_ui_live_worker as worker


class WorkerBoundaryTests(unittest.TestCase):
    def args(self,root):
        runtime=root/'runtime';runtime.mkdir();(runtime/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
        return ['--koreader',str(runtime),'--source',str(root),'--candidate',str(candidate),
                '--width','1264','--height','1680','--dpi','300']

    def test_mock_entry_rejects_missing_loopback_or_live_flag_before_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            args=self.args(Path(tmp))
            for extra in ([],['--mock-port','1234','--allow-live']):
                with self.subTest(extra=extra),patch.object(worker.sys,'platform','linux'),patch.object(worker,'read_initial') as read, \
                     patch('sys.stderr',new_callable=lambda:Mock()):
                    with self.assertRaises(SystemExit):worker.main(args+extra,mock_only=True)
                    read.assert_not_called()

    def test_live_payload_requires_explicit_enable_and_mock_account_is_fixed(self):
        for mode in ('no_enable','foreign_mock'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                args=self.args(Path(tmp));extra=[] if mode=='no_enable' else ['--mock-port','1234']
                payload={'bundle':{'plan':{'owner':'foreign','book_id':'foreign','format':'web_xhtml'},'evidence':{}},
                         'grant':{'vid':'foreign'},'cookies':{},'months':{},'token':'a'*32,'armed':True}
                stdout=Mock();stdout.buffer=BytesIO()
                original=Path.read_text
                def read_text(path,*a,**k):
                    if str(path)=='/proc/mounts':return 'tmpfs /dev/shm tmpfs rw 0 0\n'
                    return original(path,*a,**k)
                with ExitStack() as stack:
                    stack.enter_context(patch.object(worker.sys,'platform','linux'))
                    stack.enter_context(patch.object(Path,'read_text',read_text))
                    for name in ('enable_subreaper','validate_evidence','validate_credentials','validate_cookies','validate_months'):
                        stack.enter_context(patch.object(worker,name))
                    stack.enter_context(patch.object(worker.resource,'setrlimit'))
                    stack.enter_context(patch.object(worker.signal,'signal'))
                    stack.enter_context(patch.object(worker,'read_initial',return_value=payload))
                    stack.enter_context(patch.object(worker.sys,'stdout',stdout))
                    mkdir=stack.enter_context(patch.object(worker.os,'mkdir'))
                    spawn=stack.enter_context(patch.object(worker.subprocess,'Popen'))
                    self.assertEqual(worker.main(args+extra),1)
                    mkdir.assert_not_called();spawn.assert_not_called()


if __name__=='__main__':unittest.main()
