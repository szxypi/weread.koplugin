"""Closed recovery proofs: inspection never substitutes for an old POST ACK."""
import json
import unittest
from types import SimpleNamespace
from native_position_review_probe import compare as compare_observation,FRAME as OBS_FRAME
from run_native_reader_review import decode,decode_reopen,CASES,FRAME,FLAGS,REVIEW_FLAGS


def stage(kind):
    a={key:False for key in REVIEW_FLAGS}
    a.update(kind=kind,failed_line=0,unknown_retained=True,review_worker=True,workers_reaped=True,
             cancelled=kind in ('cancel','move','offline','account'),storage_preserved=kind=='storage',
             archived_unknown=kind in ('local','cloud'),newer_local_kept=kind in ('local','cloud'),
             fresh_choice=kind in ('local','cloud'),new_request=kind=='local',cloud_choice=kind=='cloud')
    flags={key:key in ('manual','original_local_units','summary_not_in_checkpoints','parent_only_document','workers_reaped','reader_from_shelf','source_workers') for key in FLAGS}
    return dict(result='PASS',phase='complete',failed_line=0,native_posts=2+int(kind=='local'),web_posts=0,review_case=a,**flags)


def frame(value):return FRAME+json.dumps(value).encode()


class NativeReaderReviewTests(unittest.TestCase):
    def test_local_cloud_and_four_preserved_pending_paths(self):
        for kind in CASES:self.assertEqual(decode(frame(stage(kind)),kind),stage(kind))
    def test_readonly_cloud_choice_cannot_hide_a_write(self):
        value=stage('cloud');value['native_posts']=3
        with self.assertRaises(ValueError):decode(frame(value),'cloud')
    def test_new_local_choice_requires_archive_and_preserved_newer_intent(self):
        for key in ('unknown_retained','review_worker','workers_reaped','archived_unknown','newer_local_kept','fresh_choice','new_request'):
            value=stage('local');value['review_case'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):decode(frame(value),'local')
    def test_cancellation_or_storage_error_never_counts_as_archived(self):
        for kind in ('cancel','move','offline','account','storage'):
            for key in ('archived_unknown','new_request','cloud_choice'):
                value=stage(kind);value['review_case'][key]=True
                with self.assertRaises(ValueError):decode(frame(value),kind)
    def test_strict_result_types_and_modes(self):
        for key,bad in (('native_posts',True),('web_posts',1),('timed',True),('parent_only_document',False)):
            value=stage('local');value[key]=bad
            with self.assertRaises(ValueError):decode(frame(value),'local')
        value=stage('cloud');value['review_case']['kind']='local'
        with self.assertRaises(ValueError):decode(frame(value),'cloud')
    def test_private_extras_never_cross_report_boundary(self):
        for nested in (True,False):
            value=stage('local');(value['review_case'] if nested else value)['summary']='private'
            with self.assertRaises(ValueError):decode(frame(value),'local')
    def test_ambiguous_frame_and_incomplete_proof(self):
        for raw in (b'private',FRAME+frame(stage('local')),b'x'*(2*1024*1024+1)):
            with self.assertRaises(ValueError):decode(raw,'local')
        value=stage('local');value['result']='UNVERIFIED';value['review_case']['new_request']=False
        self.assertEqual(decode(frame(value),'local'),value)

    def test_offline_reopen_requires_unknown_history_or_original_pending(self):
        for kind in CASES:
            value=stage(kind);value.pop('review_case');value.update(native_posts=0,web_posts=0)
            for key in FLAGS:value[key]=key in ('reader_from_shelf','parent_only_document')
            archived=kind in ('local','cloud')
            value['review_reopen']=dict(kind=kind,journal_idle=archived,unknown_history=archived,pending_preserved=not archived,local_intent=not archived,history_rows=int(archived))
            self.assertEqual(decode_reopen(frame(value),kind),value)
            value['review_reopen']['unknown_history']=not archived
            with self.assertRaises(ValueError):decode_reopen(frame(value),kind)

    def test_private_observation_comparison_requires_full_state_and_six_gets(self):
        obs={'point':{'summary':'synthetic private'},'counts':{'readingTime':12},'version':0,'shelf_sha256':'a'*64}
        expected=dict(result='PASS',native_gets=6,readbacks=2,observation=obs,unchanged=True)
        def runner(command,**kw):
            self.assertEqual(command,['synthetic-probe']);self.assertEqual(json.loads(kw['input']),dict(credentials={'token':'synthetic'},metadata={}))
            return SimpleNamespace(returncode=0,stdout=OBS_FRAME+json.dumps(expected).encode())
        compare_observation({'token':'synthetic'},{},obs,['synthetic-probe'],runner=runner)
    def test_incomplete_or_mutating_observation_never_matches(self):
        for change in ({'native_gets':5},{'readbacks':1},{'unchanged':False},{'extra':'private'}):
            value=dict(result='PASS',native_gets=6,readbacks=2,observation={},unchanged=True);value.update(change)
            with self.assertRaises(ValueError):compare_observation({}, {}, {},['synthetic'],runner=lambda *a,**k:SimpleNamespace(returncode=0,stdout=OBS_FRAME+json.dumps(value).encode()))
    def test_ambiguous_or_private_child_output_is_rejected(self):
        for raw in (b'PRIVATE_COOKIE',OBS_FRAME+OBS_FRAME+b'{}',b'x'*65537):
            with self.assertRaises(ValueError):compare_observation({}, {}, {},['synthetic'],runner=lambda *a,**k:SimpleNamespace(returncode=0,stdout=raw))
    def test_oversized_private_input_never_launches_reader(self):
        def forbidden(*a,**k):raise AssertionError('child launched')
        with self.assertRaises(ValueError):compare_observation({}, {'summary':'x'*65537}, {},['synthetic'],runner=forbidden)


if __name__=='__main__':unittest.main()
