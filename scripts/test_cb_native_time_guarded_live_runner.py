"""The one-shot worker must reject unsafe inputs before opening a workspace."""
import contextlib,io,tempfile,unittest
from pathlib import Path
from unittest.mock import patch

import run_cb_native_time_guarded_live as task


class LiveRunnerTests(unittest.TestCase):
    def test_invalid_input_cannot_start(self):
        for mode in ('unarmed','early','same_day','wrong_owner','mock_real','extra_field'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);(root/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
                plan={'owner':'900000','book_id':'CB_SyntheticResume','not_before':10,'start_time':1}
                grant={'vid':'900000','accessToken':'mock-native-access','refreshToken':'mock-native-refresh'}
                payload=dict(bundle={'plan':plan,'evidence':{}},grant=grant,cookies={'wr_vid':'900000','wr_skey':'mock_key'},
                             months={},token='a'*32,armed=True)
                args=['--koreader',str(root),'--source',str(root),'--candidate',str(candidate)]
                if mode=='unarmed':payload['armed']=False
                elif mode=='early':plan['not_before']=9999999999
                elif mode=='same_day':plan['start_time']=100000
                elif mode=='wrong_owner':grant['vid']='900001'
                elif mode=='mock_real':plan['book_id']='CB_Other';args+=['--mock-port','1234']
                else:payload['unexpected']=True
                stream=io.TextIOWrapper(io.BytesIO(),encoding='utf-8',write_through=True)
                with patch.object(task.sys,'platform','linux'),patch.object(task,'enable_subreaper'),\
                     patch.object(task.resource,'setrlimit'),patch.object(task.signal,'signal'),\
                     patch.object(task.Path,'read_text',return_value='tmpfs /dev/shm tmpfs rw 0 0\n'),\
                     patch.object(task,'read_initial',return_value=payload),patch.object(task,'validate_evidence'),\
                     patch.object(task,'validate_credentials'),patch.object(task,'validate_cookies'),patch.object(task,'validate_months'),\
                     patch.object(task.time,'time',return_value=100001),patch.object(task.os,'mkdir') as mkdir,\
                     patch.object(task.subprocess,'Popen') as spawn,contextlib.redirect_stdout(stream):
                    self.assertEqual(task.main(args),1)
                mkdir.assert_not_called();spawn.assert_not_called()

    def test_preexisting_workspace_is_not_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'luajit').touch();candidate=root/'candidate.zip';candidate.touch()
            plan={'owner':'900000','book_id':'CB_SyntheticResume','not_before':10,'start_time':1}
            payload=dict(bundle={'plan':plan,'evidence':{}},grant={'vid':'900000'},
                         cookies={'wr_vid':'900000','wr_skey':'mock_key'},months={},token='a'*32,armed=True)
            stream=io.TextIOWrapper(io.BytesIO(),encoding='utf-8',write_through=True)
            with patch.object(task.sys,'platform','linux'),patch.object(task,'enable_subreaper'),\
                 patch.object(task.resource,'setrlimit'),patch.object(task.signal,'signal'),\
                 patch.object(task.Path,'read_text',return_value='tmpfs /dev/shm tmpfs rw 0 0\n'),\
                 patch.object(task,'read_initial',return_value=payload),patch.object(task,'validate_evidence'),\
                 patch.object(task,'validate_credentials'),patch.object(task,'validate_cookies'),patch.object(task,'validate_months'),\
                 patch.object(task.time,'time',return_value=100001),patch.object(task.os,'mkdir',side_effect=FileExistsError),\
                 patch.object(task.shutil,'rmtree') as cleanup,contextlib.redirect_stdout(stream):
                self.assertEqual(task.main(['--koreader',str(root),'--source',str(root),'--candidate',str(candidate)]),1)
            cleanup.assert_not_called()


if __name__=='__main__':unittest.main()
