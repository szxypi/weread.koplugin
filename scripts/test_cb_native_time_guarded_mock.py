"""Loopback-only runner refuses real credentials and existing workspaces."""
import contextlib,io,tempfile,unittest
from pathlib import Path
from unittest.mock import patch

import run_cb_native_time_guarded_mock as task


class GuardedMockTests(unittest.TestCase):
    def test_real_like_account_never_launches(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
            payload=dict(bundle={'plan':{'owner':'900001','book_id':'CB_real'},'evidence':{}},
                         grant={'vid':'900001','accessToken':'private'},cookies={},months={},token='a'*32,armed=True)
            output=io.BytesIO();stream=io.TextIOWrapper(output,encoding='utf-8',write_through=True)
            with patch.object(task.sys,'platform','linux'),patch.object(task,'enable_subreaper'),\
                 patch.object(task.resource,'setrlimit'),patch.object(task.signal,'signal'),\
                 patch.object(task.Path,'read_text',return_value='tmpfs /dev/shm tmpfs rw 0 0\n'),\
                 patch.object(task,'read_initial',return_value=payload),patch.object(task.subprocess,'Popen') as spawn,\
                 contextlib.redirect_stdout(stream):
                status=task.main(['--koreader',str(root),'--source',str(root),'--candidate',str(candidate),'--mock-port','1234'])
            spawn.assert_not_called();self.assertEqual(status,1)
            self.assertNotIn('private',output.getvalue().decode());self.assertNotIn('CB_real',output.getvalue().decode())

    def test_existing_workspace_is_not_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
            plan={'owner':'900000','book_id':'CB_SyntheticResume','not_before':1}
            payload=dict(bundle={'plan':plan,'evidence':{}},grant={'vid':'900000','accessToken':'mock-native-access',
                         'refreshToken':'mock-native-refresh'},cookies={'wr_vid':'900000','wr_skey':'mock_key'},months={},token='a'*32,armed=False)
            output=io.BytesIO();stream=io.TextIOWrapper(output,encoding='utf-8',write_through=True)
            with patch.object(task.sys,'platform','linux'),patch.object(task,'enable_subreaper'),\
                 patch.object(task.resource,'setrlimit'),patch.object(task.signal,'signal'),\
                 patch.object(task.Path,'read_text',return_value='tmpfs /dev/shm tmpfs rw 0 0\n'),\
                 patch.object(task,'read_initial',return_value=payload),patch.object(task,'validate_evidence'),\
                 patch.object(task.os,'mkdir',side_effect=FileExistsError),patch.object(task.shutil,'rmtree') as cleanup,\
                 contextlib.redirect_stdout(stream):
                self.assertEqual(task.main(['--koreader',str(root),'--source',str(root),'--candidate',str(candidate),'--mock-port','1234']),1)
            cleanup.assert_not_called()


if __name__=='__main__':unittest.main()
