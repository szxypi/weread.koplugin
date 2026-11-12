"""Closed native reader proof cannot be substituted by ordinary upload results."""
import json
import unittest
from run_native_reader_close import decode,CASES,FRAME
from run_native_reader_position import FLAGS


def stage(kind):
    written=kind in ('plain','noack')
    a=dict(kind=kind,document_closed=True,archive_worker=True,workers_reaped=True,no_closed_document_calls=True,
           confirmed=kind=='plain',unknown_retained=kind=='noack',cancelled=not written,close_posts=int(written),failed_line=0)
    r=dict(result='PASS',phase='complete',failed_line=0,native_posts=1+int(written),web_posts=0,close_case=a,
           **{key:key in ('manual','original_local_units','summary_not_in_checkpoints','parent_only_document','workers_reaped','reader_from_shelf','source_workers') for key in FLAGS})
    return r


def frame(value):return FRAME+json.dumps(value).encode()


class NativeReaderCloseTests(unittest.TestCase):
    def test_closed_confirmed_unknown_and_three_cancellations(self):
        for kind in CASES:self.assertEqual(decode(frame(stage(kind)),kind),stage(kind))
    def test_every_native_close_proof_is_required(self):
        for key in ('document_closed','archive_worker','workers_reaped','no_closed_document_calls','confirmed'):
            value=stage('plain');value['close_case'][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):decode(frame(value),'plain')
        for key in ('manual','reader_from_shelf','source_workers','workers_reaped','parent_only_document'):
            value=stage('plain');value[key]=False
            with self.assertRaises(ValueError):decode(frame(value),'plain')
    def test_unknown_applied_position_is_not_mistaken_for_success(self):
        for change in ({'confirmed':True},{'unknown_retained':False},{'close_posts':0}):
            value=stage('noack');value['close_case'].update(change)
            with self.assertRaises(ValueError):decode(frame(value),'noack')
    def test_cancellation_cannot_hide_a_late_post(self):
        for kind in ('cancel','reopen','account'):
            value=stage(kind);value['close_case']['close_posts']=1;value['native_posts']=2
            with self.assertRaises(ValueError):decode(frame(value),kind)
    def test_strict_counts_modes_and_no_unrelated_flags(self):
        for key,bad in (('native_posts',True),('web_posts',1),('timed',True),('pending_reopened',True),('failed_line',1)):
            value=stage('plain');value[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):decode(frame(value),'plain')
        for key,bad in (('close_posts',True),('failed_line',1),('kind','noack')):
            value=stage('plain');value['close_case'][key]=bad
            with self.assertRaises(ValueError):decode(frame(value),'plain')
    def test_private_or_invented_fields_never_cross_result_boundary(self):
        for nested in (True,False):
            value=stage('plain');(value['close_case'] if nested else value)['raw_source']='private'
            with self.assertRaises(ValueError):decode(frame(value),'plain')
        value=stage('plain');value.pop('close_case')
        with self.assertRaises(ValueError):decode(frame(value),'plain')
    def test_frame_scope_and_partial_failure_are_unambiguous(self):
        value=stage('plain');value['result']='UNVERIFIED';value['close_case']['confirmed']=False
        self.assertEqual(decode(frame(value),'plain'),value)
        for raw,kind in ((frame(stage('plain')),'other'),(FRAME+frame(stage('plain')),'plain'),(b'private','plain')):
            with self.assertRaises(ValueError):decode(raw,kind)


if __name__=='__main__':unittest.main()
