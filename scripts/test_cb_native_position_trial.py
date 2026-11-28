"""Offline checks for the scoped native CB sender trial."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_cb_native_position_trial as task


class TestNativeTrial(unittest.TestCase):
    def test_offline_never_accesses_session_or_native(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'native') as native,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();native.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_inputs_stay_in_pipe_and_exact_receipt_is_required(self):
        position=dict(book_id='CB_Synthetic',summary='private summary')
        context=dict(psvts='private session');cookies=dict(wr_skey='private cookie')
        good=dict(accepted=True,acknowledged=True,confirmed=True,writes=2,reads=1,enter_attempted=True,report_attempted=True)
        prefix=b'\nWEREAD_CB_EXISTING_NATIVE_REPORT='
        with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=prefix+json.dumps(good).encode())) as child:
            self.assertEqual(task.native(['lua'],position,context,cookies,'both'),good)
        self.assertNotIn('private',' '.join(child.call_args.args[0]))
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['cookies'],cookies)
        for result in (dict(good,writes=1),dict(good,confirmed=False),dict(good,extra='forbidden')):
            with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=prefix+json.dumps(result).encode())):
                with self.assertRaises(task.NativeFailure):task.native(['lua'],position,context,cookies,'both')
        with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout=b'')):
            with self.assertRaises(task.NativeFailure) as error:task.native(['lua'],position,context,cookies,'both')
        self.assertIsNone(error.exception.writes)


if __name__=='__main__':unittest.main()
