"""Closed first-sync UI evidence; no live accounts, grants or writes."""
from copy import deepcopy
import json,unittest
from run_native_reader_initial import decode,FRAME,FLAGS,CASE_FLAGS,CASES


def stage(mode='accepted',reopen=False):
    needed={'reopen','offline_preserved'} if reopen else {'cancelled_locally','explicit_choice','no_automatic_write','workers_reaped'}|(
        {'confirmed'} if mode in ('accepted','delayed') else {'reviewed','local_save_failed' if mode=='local_save_failed' else 'unknown_kept'})
    return dict(result='PASS',phase='complete',failed_line=0,native_posts=0 if reopen else 1,web_posts=0,
                initial_case=dict(mode=mode,failed_line=0,**{k:k in needed for k in CASE_FLAGS}),**{k:False for k in FLAGS})


def frame(v):return FRAME+json.dumps(v).encode()


class NativeReaderInitialTests(unittest.TestCase):
    def test_each_mode_has_an_exact_live_and_offline_proof(self):
        for mode in CASES:
            for reopen in (False,True):
                v=stage(mode,reopen);self.assertEqual(decode(frame(v),mode,reopen),v)
                for k in CASE_FLAGS:
                    bad=deepcopy(v);bad['initial_case'][k]=not bad['initial_case'][k]
                    with self.subTest(mode=mode,reopen=reopen,k=k),self.assertRaises(ValueError):decode(frame(bad),mode,reopen)
    def test_unknown_and_saved_ack_are_not_interchangeable(self):
        for mode in ('noack','rejected','changed_counts','local_save_failed'):
            v=stage(mode);v['initial_case']['confirmed']=True
            with self.assertRaises(ValueError):decode(frame(v),mode)
    def test_private_fields_wrong_types_and_counts_are_rejected(self):
        for key,value in (('web_posts',1),('native_posts',2),('failed_line',True),('summary','private')):
            v=stage();v[key]=value
            with self.assertRaises(ValueError):decode(frame(v),'accepted')
        for key,value in (('summary','private'),('confirmed',1),('mode','unknown'),('failed_line',False)):
            v=stage();v['initial_case'][key]=value
            with self.assertRaises(ValueError):decode(frame(v),'accepted')
    def test_duplicate_frames_wrong_mode_and_incomplete_pass_are_rejected(self):
        v=stage()
        for raw,mode in ((frame(v)*2,'accepted'),(frame(v),'unknown'),(frame(v),'noack'),(b'','accepted')):
            with self.assertRaises(ValueError):decode(raw,mode)
        v['phase']='init'
        with self.assertRaises(ValueError):decode(frame(v),'accepted')


if __name__=='__main__':unittest.main()
