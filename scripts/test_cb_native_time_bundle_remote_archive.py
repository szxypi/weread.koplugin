"""A relay binds the private file bytes to a single claim and approval."""
import base64,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch

import cb_native_time_bundle_remote_archive as task
from test_cb_native_time_bundle_native_record import setup


class RemoteArchiveTests(unittest.TestCase):
    def test_file_identity_and_one_shot_recheck(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(task,'require_tmpfs'):
            root=Path(directory);bundle,_grant,_evidence,_selection,_body,_record,path,_now=setup(directory)
            os.chmod(path,0o600);plan=bundle['plan'];raw=path.read_bytes()
            relay=task.Relay(plan,root,path);event=dict(kind='claim',body={},selection={},record={})
            value=relay.prepare(event);self.assertEqual(base64.b64decode(value['archive_base64']),raw)
            self.assertTrue(relay.recheck())
            with self.assertRaises(ValueError):relay.prepare(event)
            with self.assertRaises(ValueError):relay.recheck()
            relay=task.Relay(plan,root,path);relay.prepare(event);path.write_bytes(raw+b'changed')
            with self.assertRaises(ValueError):relay.recheck()
            with self.assertRaises(ValueError):relay.recheck()

    def test_symlink_permissions_extra_fields_and_wrong_path_fail(self):
        for mode in ('link','mode','root_mode','wrong_path','extra','invalid_archive'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory,patch.object(task,'require_tmpfs'):
                root=Path(directory);bundle,_grant,_evidence,_selection,_body,_record,path,_now=setup(directory)
                os.chmod(path,0o600);event=dict(kind='claim',body={},selection={},record={});source=path
                if mode=='link':
                    raw=path.read_bytes();path.unlink();other=root/'other';other.write_bytes(raw);path.symlink_to(other)
                elif mode=='mode':os.chmod(path,0o644)
                elif mode=='root_mode':os.chmod(root,0o755)
                elif mode=='wrong_path':source=root/'other'
                elif mode=='extra':event['archive_base64']='forged'
                else:path.write_bytes(b'not a capture')
                with self.assertRaises(ValueError):task.Relay(bundle['plan'],root,source).prepare(event)


if __name__=='__main__':unittest.main()
