import contextlib,io,json,unittest
from unittest.mock import patch

import verify_owner_cached_catalog_restore as task


class OwnerCatalogRestoreTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_untrusted_container_stops_before_loading_session(self):
        with patch.object(task,'trusted_command',side_effect=ValueError('private failure')),\
             patch.object(task,'SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main(['--saved-session']),1)
        store.assert_not_called();self.assertNotIn('private failure',output.getvalue())


if __name__=='__main__':unittest.main()
