import contextlib,hashlib,io,json,subprocess,unittest
from unittest.mock import patch
from run_translation_fetch_owner import FLAGS,FRAME as NATIVE_FRAME,decode,payload_valid,validate_stage
from verify_translation_fetch_owner import FRAME,execute,main,observation,synthetic_source


def payload():
    source=synthetic_source()
    return dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'),book_id='900001',chapter_uid='1',
        title='Synthetic',author='Synthetic',source=source,source_sha256=hashlib.sha256(source.encode()).hexdigest(),blocks=12)


def stage(mode):
    return dict({k:True for k in FLAGS},mode=mode,result='PASS',phase='complete',screenshots=0,
        requests=10 if mode=='live' else 0,forbidden=0,failed_line=0)


def result():
    return dict(result='PASS',stages=[stage('live'),stage('reopen')],profile_removed=True,cookies=payload()['cookies'],
        account_data_posts=0,authentication_posts=0,installed=dict(files=298,bytes_match=True))


class TranslationOwnerTest(unittest.TestCase):
    def invoke(self,value,code=0):
        raw=FRAME+json.dumps(value).encode()
        with patch('verify_translation_fetch_owner.subprocess.run',return_value=subprocess.CompletedProcess([],code,raw,b'')) as run:
            value=execute(['private-command'],payload())
            self.assertEqual(json.loads(run.call_args.kwargs['input']),payload())
            self.assertTrue(run.call_args.kwargs['capture_output'])
            return value

    def test_default_has_no_credentials_network_or_child(self):
        with patch('verify_translation_fetch_owner.SessionStore') as store,patch('verify_translation_fetch_owner.Native') as native,\
                patch('verify_translation_fetch_owner.execute') as child,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0);store.assert_not_called();native.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_access_and_private_pipe_must_be_paired(self):
        for args in (['--saved-session'],['--mock'],['--native-ui-command','no-run'],['--mock','--saved-session']):
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)

    def test_payload_requires_exact_real_source_and_scope(self):
        self.assertIsNotNone(payload_valid(payload()))
        for update in (dict(source='x'*200),dict(source_sha256='A'*64),dict(chapter_uid='0'),dict(chapter_uid='2147483648'),
                dict(book_id='../other'),dict(vid=True),dict(blocks=True),dict(blocks=0),dict(blocks=20001),
                dict(source='x'*204801),dict(title='x'*4097),dict(author='a\0b'),dict(extra='unexpected')):
            with self.subTest(update=list(update)),self.assertRaises(ValueError):payload_valid(dict(payload(),**update))

    def test_cookie_owner_and_syntax_checked(self):
        for cookies in ({},dict(wr_vid='other',wr_skey='mock_key'),dict(wr_vid='900000',wr_skey='bad;cookie'),
                dict(wr_vid='900000',wr_skey='short'),dict(wr_vid='900000',wr_skey='mock_key',unknown='value')):
            with self.subTest(cookies=list(cookies)),self.assertRaises(ValueError):payload_valid(dict(payload(),cookies=cookies))

    def test_mock_is_explicit_numeric_loopback_port_and_synthetic_owner(self):
        valid=dict(payload(),mock_port=12345);payload_valid(valid,12345)
        for value,port in ((valid,None),(payload(),12345),(valid,12346),(dict(valid,mock_port=True),True),
                (dict(valid,mock_port=0),0),(dict(valid,mock_port=65536),65536),(dict(valid,book_id='900002'),12345)):
            with self.assertRaises(ValueError):payload_valid(value,port)

    def test_complete_two_stage_result(self):
        self.assertEqual(self.invoke(result()),result())

    def test_all_native_checks_required_and_strict_booleans(self):
        for flag in FLAGS:
            for value in (False,1,None):
                value_stage=stage('live');value_stage[flag]=value
                with self.subTest(flag=flag,value=value),self.assertRaises(ValueError):validate_stage(value_stage,'live')
        with self.assertRaises(ValueError):validate_stage(dict(stage('live'),unexpected=True),'live')

    def test_live_bounded_reads_and_offline_zero_requests(self):
        for mode,requests in (('live',0),('live',33),('live',True),('reopen',1),('reopen',False)):
            with self.subTest(mode=mode,requests=requests),self.assertRaises(ValueError):validate_stage(dict(stage(mode),requests=requests),mode)
        validate_stage(dict(stage('live'),requests=32),'live')

    def test_no_screenshots_or_forbidden_requests_or_failure(self):
        for field in ('screenshots','forbidden','failed_line'):
            for value in (1,False,'0'):
                with self.subTest(field=field,value=value),self.assertRaises(ValueError):validate_stage(dict(stage('live'),**{field:value}),'live')

    def test_modes_completion_and_schema_must_match(self):
        for update in (dict(mode='reopen'),dict(phase='download'),dict(result='UNVERIFIED')):
            with self.assertRaises(ValueError):validate_stage(dict(stage('live'),**update),'live')
        for value in (None,[],{}):
            with self.assertRaises(ValueError):validate_stage(value,'live')
        with self.assertRaises(ValueError):validate_stage(stage('live'),'unknown')

    def test_native_frame_is_unique_bounded_and_exact(self):
        valid=NATIVE_FRAME+json.dumps(dict(report=stage('live'),cookies=payload()['cookies'])).encode()
        self.assertEqual(decode(valid,'live','900000')[0],stage('live'))
        for raw in (b'',valid+NATIVE_FRAME, b'x'*1048577, NATIVE_FRAME+b'[]',
                NATIVE_FRAME+json.dumps(dict(report=stage('live'),cookies=payload()['cookies'],extra=1)).encode()):
            with self.assertRaises(ValueError):decode(raw,'live','900000')

    def test_native_frame_must_match_owner(self):
        raw=NATIVE_FRAME+json.dumps(dict(report=stage('live'),cookies=payload()['cookies'])).encode()
        with self.assertRaises(ValueError):decode(raw,'live','900001')

    def test_host_rechecks_stages_installation_and_no_writes(self):
        cases=[dict(stages=[]),dict(stages=[stage('reopen'),stage('live')]),dict(stages=[stage('live'),dict(stage('reopen'),requests=1)]),
            dict(installed=dict(files=True,bytes_match=True)),dict(installed=dict(files=0,bytes_match=True)),
            dict(installed=dict(files=298,bytes_match=False)),dict(account_data_posts=1),dict(authentication_posts=True),
            dict(extra='unexpected'),dict(cookies=dict(wr_vid='900001',wr_skey='mock_key'))]
        for update in cases:
            with self.subTest(update=list(update)),self.assertRaises(ValueError):self.invoke(dict(result(),**update))

    def test_failed_or_incomplete_result_is_never_success(self):
        for update,code in (({},1),(dict(result='UNVERIFIED'),0),(dict(profile_removed=False),0)):
            with self.assertRaises(ValueError):self.invoke(dict(result(),**update),code)

    def test_failure_diagnostics_cannot_echo_private_strings(self):
        value=dict(result(),result='UNVERIFIED',phase='private-value',reason='private-value',failed_line='private-value')
        with self.assertRaises(ValueError) as raised:self.invoke(value)
        self.assertEqual(raised.exception.diagnostic,{})

    def test_host_rejects_missing_duplicate_oversized_or_nonobject_frame(self):
        for raw in (b'',FRAME+b'{}'+FRAME, b'x'*1048577,FRAME+b'[]'):
            with patch('verify_translation_fetch_owner.subprocess.run',return_value=subprocess.CompletedProcess([],0,raw,b'')),self.assertRaises(ValueError):execute(['no-run'],payload())

    def test_explicit_absent_record_preserves_absence_not_zero(self):
        raw=dict(bookId='900001',book=dict(bookId='900001',title='Synthetic'),canFreeRead=1,timestamp=100)
        value=observation(raw,'900001','native')
        self.assertFalse(value['position_present']);self.assertEqual(value['counters'],{});self.assertNotIn('position',value)
        self.assertEqual(observation(dict(raw,timestamp=101),'900001','native'),value)
        self.assertNotEqual(observation(dict(raw,canFreeRead=0),'900001','native'),value)

    def test_absence_requires_observed_envelope_and_matching_book(self):
        raw=dict(bookId='900001',book=dict(bookId='900001'),canFreeRead=1,timestamp=100)
        for value in ({},dict(bookId='900001'),dict(raw,bookId='900002'),dict(raw,book=dict(bookId='900002')),
                dict(raw,book={}),dict(raw,errcode=0),dict(raw,canFreeRead=True),dict(raw,timestamp=-1),dict(raw,timestamp=True)):
            with self.subTest(fields=list(value)),self.assertRaises(ValueError):observation(value,'900001','native')

    def test_absent_position_preserves_nested_time_counts_and_rejects_errors(self):
        raw=dict(bookId='900001',book=dict(bookId='900001'),canFreeRead=1,timestamp=100)
        value=observation(dict(raw,book=dict(nested=[dict(recordReadingTime=4)])),'900001','native')
        self.assertEqual(list(value['counters'].values()),[4]);self.assertFalse(value['position_present'])
        self.assertNotEqual(value,observation(raw,'900001','native'))
        for book in (dict(readingTime=True),dict(nested=[dict(recordReadingTime=-1)]),dict(ttsTime=None)):
            with self.assertRaises(ValueError):observation(dict(raw,book=book),'900001','native')
        with self.assertRaises(ValueError):observation(dict(raw,succ=False),'900001','native')

    def test_existing_position_keeps_counter_presence_and_values(self):
        raw=dict(bookId='900001',progress=0,chapterUid=0,chapterOffset=0)
        empty=observation(raw,'900001','native');zero=observation(dict(raw,readingTime=0),'900001','native')
        self.assertTrue(empty['position_present']);self.assertEqual(empty['counters'],{})
        self.assertNotEqual(empty,zero);self.assertEqual(zero['counters'],dict(readingTime=0))
        for value in (True,-1,'0',None,2**53):
            with self.assertRaises(ValueError):observation(dict(raw,readingTime=value),'900001','native')

    def test_rejected_or_ambiguous_positions_are_not_absence(self):
        for raw in (dict(bookId='900002',progress=0),dict(bookId='900001',progress=-1),
                dict(bookId='900001',progress=0,succ=False),dict(data=[dict(progress=0),dict(progress=1)])):
            with self.assertRaises(ValueError):observation(raw,'900001','native')


if __name__=='__main__':unittest.main()
