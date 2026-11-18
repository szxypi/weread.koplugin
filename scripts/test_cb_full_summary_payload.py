"""Offline bounds and pipe privacy for CB full-summary payload comparison."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_cb_full_summary_payload as task
from verify_cb_roundtrip_preflight import assess
from verify_source_coordinates import FilteredSource


def sample():
    book='CB_Synthetic';source='<html><body><p>Unique synthetic position with sufficiently long nearby context.</p></body></html>'
    offset=FilteredSource(source).starts[0];summary='自造完整摘要不应被截断。'+'文'*24+'😀'
    raw=dict(book=dict(bookId=book,chapterUid=2,chapterIdx=2,chapterOffset=offset,progress=25,summary=summary))
    context=dict(book_id=book,psvts='synthetic',pclts='synthetic',token='synthetic-token',progress=raw)
    return assess(book,raw,context,source),raw


class TestFullSummary(unittest.TestCase):
    def test_offline_has_no_credentials_or_network(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'compare') as compare,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();compare.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_full_summary_preserved_and_private_data_only_in_pipe(self):
        plan,raw=sample();values=task.vectors(plan,raw)
        self.assertEqual(len(values),2)
        for value in values:self.assertEqual(value['expected']['sm'],raw['book']['summary'])
        response=dict(matches=2,total=2,network_requests=0)
        process=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_CB_FULL_SUMMARY_PAYLOAD='+json.dumps(response).encode())
        with patch.object(task.subprocess,'run',return_value=process) as child:
            self.assertTrue(task.compare(values,['synthetic']))
        self.assertNotIn(raw['book']['summary'],' '.join(child.call_args.args[0]))
        self.assertNotIn('cookies',child.call_args.kwargs['input'].decode())
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['samples'],values)

    def test_fractional_percent_and_unbounded_summary_rejected(self):
        plan,raw=sample();plan['baseline']['raw_percent']=25.5
        with self.assertRaises(ValueError):task.vectors(plan,raw)
        plan,raw=sample();raw['book']['summary']='x'*513
        with self.assertRaises(ValueError):task.vectors(plan,raw)
        plan,raw=sample();raw['book']['summary']='bad\x00'+('x'*30)
        with self.assertRaises(ValueError):task.vectors(plan,raw)


if __name__=='__main__':unittest.main()
