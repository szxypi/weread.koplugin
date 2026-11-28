"""Developer probes are offline unless an explicit synthetic runtime is given."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

import verify_native_time_bundle_gate as gate
import verify_native_time_bundle_selection as selection
import verify_native_time_bundle_supervisor as supervisor
import verify_native_time_bundle_rpc as rpc
import verify_native_time_bundle_ui_rpc as ui_rpc
import verify_native_time_bundle_accounting as accounting
import verify_native_time_http_guard as http_guard


class OfflineProbeTests(unittest.TestCase):
    def test_default_modes_never_start_a_child(self):
        for module in (gate,selection,supervisor,rpc,ui_rpc,accounting,http_guard):
            with self.subTest(module=module.__name__),patch.object(module.subprocess,'run') as child,redirect_stdout(io.StringIO()) as output:
                self.assertEqual(module.main([]),0)
            child.assert_not_called();report=json.loads(output.getvalue())
            self.assertEqual(report['result'],'OFFLINE_ONLY')
            self.assertEqual(report['account_data_posts'],0);self.assertEqual(report['authentication_posts'],0)


if __name__=='__main__':unittest.main()
