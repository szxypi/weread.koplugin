"""Require complete zero-request CB sync notice and offline local persistence."""
from copy import deepcopy
import json,unittest
from cb_sync_limit_contract import decode_envelope,FLAGS
from verify_owner_reading import FRAME
from test_owner_reading import stage as base_stage,COOKIES


def stage(mode='live'):
    v=base_stage(mode);v['source_match_reason']='none';v['cb_sync_limit']=dict(native_denied=0,failed_line=0,**{k:True for k in FLAGS});return v


def frame(v):return FRAME+json.dumps(v).encode()


def envelope():
    return dict(report=dict(result='PASS',tmpfs_profile=True,profile_removed=True,stages=[stage(),stage('reopen')],runner_error='none',
                            installed_package=dict(files=288,bytes_match=True)),cookies=COOKIES.copy())


class CbSyncLimitTests(unittest.TestCase):
    def test_both_live_and_offline_proofs_are_required(self):
        for mode in ('live','reopen'):
            v=dict(report=stage(mode),cookies=COOKIES.copy());decode_envelope(frame(v),COOKIES['wr_vid'],mode=mode,cb_reading=True)
            for key in FLAGS:
                bad=deepcopy(v);bad['report']['cb_sync_limit'][key]=False
                with self.subTest(mode=mode,key=key),self.assertRaises(ValueError):decode_envelope(frame(bad),COOKIES['wr_vid'],mode=mode,cb_reading=True)
    def test_failed_cleanup_or_installed_bytes_cannot_claim_success(self):
        v=envelope();decode_envelope(frame(v),COOKIES['wr_vid'],cb_reading=True)
        for change in (lambda r:r.update(profile_removed=False),lambda r:r.pop('installed_package'),lambda r:r['installed_package'].update(bytes_match=False)):
            bad=deepcopy(v);change(bad['report'])
            with self.assertRaises(ValueError):decode_envelope(frame(bad),COOKIES['wr_vid'],cb_reading=True)
    def test_private_extra_fields_wrong_types_and_native_attempts_are_rejected(self):
        for key,value in (('summary','private'),('native_denied',1),('failed_line',True),('zero_sync_requests',1)):
            v=envelope();v['report']['stages'][0]['cb_sync_limit'][key]=value
            with self.assertRaises(ValueError):decode_envelope(frame(v),COOKIES['wr_vid'],cb_reading=True)
    def test_different_modes_or_unscoped_sources_are_rejected(self):
        v=envelope()
        for args in ({},{'cb_reading':True,'cb_full_book':True},{'cb_reading':True,'full_chapters':2},{'cb_reading':True,'extra':'private'}):
            with self.assertRaises(ValueError):decode_envelope(frame(v),COOKIES['wr_vid'],**args)


if __name__=='__main__':unittest.main()
