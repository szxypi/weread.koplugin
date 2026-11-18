"""Guarded ordinary-book worker requires explicit live mode or mock identity."""
import contextlib,io,tempfile,unittest
from pathlib import Path
from unittest.mock import patch

import run_native_time_guarded_worker as task


class GuardedWorkerTests(unittest.TestCase):
    def test_unrequested_live_send_and_real_account_mock_are_rejected(self):
        for mode in ('live_without_opt_in','foreign_mock'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);(root/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
                payload=dict(bundle={'plan':{'owner':'900002','book_id':'900003','format':'web_xhtml'},'evidence':{}},
                    grant={'vid':'900002','accessToken':'private','refreshToken':'private'},
                    cookies={'wr_vid':'900002','wr_skey':'private'},months={},token='a'*32,armed=True)
                output=io.BytesIO();stream=io.TextIOWrapper(output,encoding='utf-8',write_through=True)
                args=['--koreader',str(root),'--source',str(root),'--candidate',str(candidate)]
                if mode=='foreign_mock':args+=['--mock-port','1234']
                with patch.object(task.sys,'platform','linux'),patch.object(task,'enable_subreaper'),\
                     patch.object(task.resource,'setrlimit'),patch.object(task.signal,'signal'),\
                     patch.object(task.Path,'read_text',return_value='tmpfs /dev/shm tmpfs rw 0 0\n'),\
                     patch.object(task,'read_initial',return_value=payload),patch.object(task,'validate_evidence'),\
                     patch.object(task,'validate_credentials'),patch.object(task,'validate_cookies'),patch.object(task,'validate_months'),\
                     patch.object(task.subprocess,'Popen') as spawn,contextlib.redirect_stdout(stream):
                    status=task.main(args)
                spawn.assert_not_called();self.assertEqual(status,1)
                self.assertNotIn('private',output.getvalue().decode());self.assertNotIn('900003',output.getvalue().decode())

    def test_existing_workspace_is_not_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
            plan={'owner':'900000','book_id':'900001','format':'web_xhtml','not_before':1,'start_time':1}
            payload=dict(bundle={'plan':plan,'evidence':{}},grant={'vid':'900000','accessToken':'mock-native-access',
                'refreshToken':'mock-native-refresh'},cookies={'wr_vid':'900000','wr_skey':'mock_key'},months={},token='a'*32,armed=False)
            output=io.BytesIO();stream=io.TextIOWrapper(output,encoding='utf-8',write_through=True)
            with patch.object(task.sys,'platform','linux'),patch.object(task,'enable_subreaper'),\
                 patch.object(task.resource,'setrlimit'),patch.object(task.signal,'signal'),\
                 patch.object(task.Path,'read_text',return_value='tmpfs /dev/shm tmpfs rw 0 0\n'),\
                 patch.object(task,'read_initial',return_value=payload),patch.object(task,'validate_evidence'),\
                 patch.object(task,'validate_credentials'),patch.object(task,'validate_cookies'),patch.object(task,'validate_months'),\
                 patch.object(task.os,'mkdir',side_effect=FileExistsError),patch.object(task.shutil,'rmtree') as cleanup,\
                 contextlib.redirect_stdout(stream):
                self.assertEqual(task.main(['--koreader',str(root),'--source',str(root),'--candidate',str(candidate),'--mock-port','1234']),1)
            cleanup.assert_not_called()


if __name__=='__main__':unittest.main()
