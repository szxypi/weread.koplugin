import contextlib,io,json,unittest
from unittest.mock import patch
from verify_translation_fetch import compare,main


class TranslationFetchTest(unittest.TestCase):
    def test_default_never_opens_credentials_or_network(self):
        with patch('verify_translation_fetch.SessionStore') as store,patch('verify_translation_fetch.TranslationProbe') as probe,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0);store.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_explicit_access_and_pipe_are_paired(self):
        for args in (['--saved-session'],['--lua-command','not-run']):
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)
    def test_exact_content_and_nonempty_blocks_required(self):
        sample=dict(sha256='a'*64,blocks=49)
        compare(dict(samples=[dict(sample,pairs=49)]),[sample])
        for actual in (dict(sample,sha256='b'*64,pairs=49),dict(sample,blocks=48,pairs=48),dict(sample,pairs=True),dict(sample,pairs=50)):
            with self.subTest(actual=actual),self.assertRaises(ValueError):compare(dict(samples=[actual]),[sample])
    def test_lost_or_extra_results_are_not_partial_success(self):
        for result in ({},dict(samples=[]),dict(samples=[{},{}])):
            with self.assertRaises(ValueError):compare(result,[dict(sha256='a'*64,blocks=1)])
    def test_zero_or_invalid_expected_content_is_not_evidence(self):
        for sample in (dict(sha256='a'*64,blocks=0),dict(sha256='a'*64,blocks=True),dict(sha256='bad',blocks=1)):
            with self.assertRaises(ValueError):compare(dict(samples=[dict(sample,pairs=0)]),[sample])


if __name__=='__main__':unittest.main()
