"""Offline boundaries for the real-source native cloud-view verifier."""
import io
import json
from contextlib import redirect_stdout
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_owner_cb_cloud_nearby_ui as verify


class TestOwnerCbCloudNearby(unittest.TestCase):
    def test_offline_never_accesses_session_or_runner(self):
        with patch.object(verify,'SessionStore') as store,patch.object(verify,'run_ui') as runner,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(verify.main([]),0)
        store.assert_not_called();runner.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_following_target_is_bounded_and_unique(self):
        source='<html><body><p>A uniquely identifiable following target with context.</p></body></html>'
        self.assertEqual(verify.following_target(source,12),15)
        with self.assertRaises(ValueError):verify.following_target(source,10**9)

    def test_runner_private_source_only_in_stdin_and_strict_result(self):
        good=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_navigation=True,
                  fresh_process=True,pending_preserved=True,upload_disabled=True,requests=6,denied=0,credentials_not_persisted=True)
        payload=dict(source='private synthetic source')
        with patch.object(verify.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(good).encode())) as child:
            self.assertTrue(verify.run_ui(['runner'],payload,True,600,800,167)['single'])
        self.assertNotIn(payload['source'],' '.join(child.call_args.args[0]))
        self.assertEqual(json.loads(child.call_args.kwargs['input']),payload)
        for bad in (dict(good,requests=7),dict(good,private='forbidden'),dict(good,profile_removed=False)):
            with patch.object(verify.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(bad).encode())):
                with self.assertRaises(ValueError):verify.run_ui(['runner'],payload,False,600,800,167)


if __name__=='__main__':unittest.main()
