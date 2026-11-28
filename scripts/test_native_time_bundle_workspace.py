"""Capture restoration is exact, private and cannot overwrite existing files."""
import base64
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_workspace import restore
from native_time_capture_evidence import account_key
from secure_highlight_trial import Receipt
from test_native_time_bundle_gate import fixture
import verify_native_time_bundle_workspace as inspection


class WorkspaceInspectorTests(unittest.TestCase):
    def test_default_never_loads_capture_or_starts_process(self):
        with patch.object(inspection,'CaptureBundleStore') as store,patch.object(inspection.subprocess,'Popen') as child,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(inspection.main([]),0)
        store.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_private_pipe_result_and_saved_scope_consistency_are_required(self):
        for mode in ('pass','result','posts','scope','timeout'):
            bundle,_grant,_body,_now=fixture();receipt=Receipt(b'synthetic-capture');store=Mock();store.read.return_value=(bundle,receipt)
            gate=Mock();gate.read.return_value=(None,None);audit=Mock();audit.read.return_value=(None,None)
            value=dict(result='SAME_DAY_DEFERRED',seconds=bundle['plan']['seconds'],exact_rows=True,archive_verified=True,
                       coverage_verified=True,same_day_deferred=True,pending_unchanged=True,profile_removed=True,
                       account_data_posts=0,authentication_posts=0)
            if mode=='result':value['coverage_verified']=False
            if mode=='posts':value['account_data_posts']=1
            if mode=='scope':gate.read.side_effect=[(None,None),({'phase':'claimed'},Receipt(b'other'))]
            process=Mock();process.returncode=0;process.communicate.return_value=(json.dumps(value).encode(),None)
            if mode=='timeout':process.communicate.side_effect=TimeoutError()
            with self.subTest(mode=mode),patch.object(inspection.time,'time',return_value=bundle['plan']['ended_at']+1), \
                 patch.object(inspection.subprocess,'Popen',return_value=process) as start,patch.object(inspection,'stop') as stop:
                if mode=='pass':
                    report=inspection.inspect(store,gate,audit,['synthetic-runner']);self.assertTrue(report['saved_scopes_unchanged'])
                    sent=process.communicate.call_args.args[0];self.assertEqual(json.loads(sent),bundle)
                else:
                    with self.assertRaises((ValueError,TimeoutError)):inspection.inspect(store,gate,audit,['synthetic-runner'])
                self.assertEqual(start.call_args.args[0],['synthetic-runner']);stop.assert_called_once_with(process)


@unittest.skipUnless(sys.platform=='linux' and Path('/dev/shm').is_dir(),'Linux private tmpfs required')
class BundleWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='weread-workspace-test-',dir='/dev/shm')
        self.addCleanup(self.temporary.cleanup);self.root=Path(self.temporary.name)
        self.bundle,_grant,_body,_now=fixture()

    def test_exact_archive_and_databases_have_private_permissions(self):
        epub,ledger=restore(self.bundle,self.root);plan=self.bundle['plan'];evidence=self.bundle['evidence']
        self.assertEqual(epub.read_bytes(),base64.b64decode(plan['archive_base64']))
        self.assertEqual((ledger/('offline-time-'+account_key(plan['owner'])+'.db')).read_bytes(),base64.b64decode(evidence['ledger_base64']))
        self.assertEqual((ledger/'reading-time-coverage.db').read_bytes(),base64.b64decode(evidence['coverage_base64']))
        self.assertEqual(ledger.stat().st_mode&0o777,0o700)
        self.assertTrue(all(path.stat().st_mode&0o777==0o600 for path in (epub,*ledger.iterdir())))

    def test_invalid_bundle_is_rejected_before_creating_any_file(self):
        bad=deepcopy(self.bundle);bad['evidence']['coverage_sha256']='0'*64
        with self.assertRaises(ValueError):restore(bad,self.root)
        self.assertEqual(list(self.root.iterdir()),[])

    def test_preexisting_path_or_symlink_is_never_overwritten(self):
        path=self.root/'source.epub';path.write_bytes(b'existing')
        with self.assertRaises(ValueError):restore(self.bundle,self.root)
        self.assertEqual(path.read_bytes(),b'existing')
        path.unlink();(self.root/'ledger').rmdir();(self.root/'ledger').symlink_to(self.root)
        with self.assertRaises(ValueError):restore(self.bundle,self.root)
        self.assertTrue((self.root/'ledger').is_symlink());self.assertFalse(path.exists())

    def test_world_accessible_or_non_tmpfs_root_is_rejected(self):
        os.chmod(self.root,0o755)
        with self.assertRaisesRegex(ValueError,'bundle_workspace/root'):restore(self.bundle,self.root)
        os.chmod(self.root,0o700)
        with tempfile.TemporaryDirectory() as directory:
            if not Path(directory).resolve().is_relative_to(Path('/dev/shm').resolve()):
                with self.assertRaisesRegex(ValueError,'bundle_workspace/root'):restore(self.bundle,Path(directory))
        link=self.root/'link';link.symlink_to(self.root,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'bundle_workspace/root'):restore(self.bundle,link)


if __name__=='__main__':unittest.main()
