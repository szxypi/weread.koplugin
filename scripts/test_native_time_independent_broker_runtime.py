#!/usr/bin/env python3
"""Exercise private subprocess ordering with synthetic data and tmpfs only."""
from copy import deepcopy
import json,os,sys
from pathlib import Path

from native_time_bundle_preparation import SigningInputs
from native_time_independent_audit import IndependentAudit
from native_time_independent_broker import Prepared,execute
from native_time_independent_gate import IndependentGate
from secure_highlight_trial import Receipt
from test_native_time_bundle_fresh_broker_runtime import CHILD
from test_native_time_independent_audit import fixture
from test_secure_native_session import Backend

CHILD=CHILD.replace(
    '_b,_g,before,_samples,_now=example();_b,_g,body,_n=fixture()',
    """from readtime_upload_model import batch
    plan=p['bundle']['plan'];stamp=plan['not_before']+20
    point=dict(chapter_uid=int(plan['chapter_uid']),chapter_idx=plan['chapter_idx'],chapter_offset=12,
               raw_percent=3,summary={'present':False},chapterTitle={'present':False})
    before={'snapshot':{'point':point,'web_point':dict(point),'counts':{'readingTime':20,'recordReadingTime':0,'ttsTime':0},
              'version':plan['book_version'],'shelf':'a'*64,'source':plan['raw_sha256'],'catalog':'b'*64},'months':p['months']}
    rows=[{k:r[k] for k in ('start_time','duration','time_zone','book_version')} for r in plan['rows']]
    body=batch(p['grant'],plan['book_id'],rows,'synthetic-guest','synthetic-config',stamp,123,stamp*1000,456,current_zone='+08:00')""")


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt=Receipt(b'synthetic-capture')
    def read(self):return deepcopy(self.bundle),self.receipt


def scenario(mode):
    existing={p.name for p in Path('/dev/shm').glob('weread-native-time-*')}
    bundle,grant,_body,now,_before,evidence,_gate,_audit,_samples,_observations=fixture()
    capture=Capture(bundle);gate=IndependentGate(Backend(),capture=capture,clock=lambda:now,zone=lambda:'+08:00')
    audit=IndependentAudit(Backend(),clock=lambda:now)
    prepared=Prepared(deepcopy(bundle),capture.receipt,deepcopy(grant),evidence)
    report=execute(prepared,SigningInputs('synthetic-guest','synthetic-config'),
                   {'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'},capture,gate,audit,lambda:True,
                   [sys.executable,'-c',CHILD,mode],armed=mode!='dry')
    if {p.name for p in Path('/dev/shm').glob('weread-native-time-*')}-existing:raise ValueError('independent_runtime/cleanup')
    state,_=gate.read();phase=state['phase'] if state else None
    expected={'success':('INDEPENDENT_NATIVE_ACKNOWLEDGED','acknowledged',True),
              'dry':('INDEPENDENT_NATIVE_DRY_RUN_VERIFIED',None,False),
              'tamper':('UNVERIFIED',None,False),'bad_ready':('UNVERIFIED',None,False),
              'lost':('UNVERIFIED','claimed',True),'changed':('UNVERIFIED','claimed',True),
              'bad_ack':('UNVERIFIED','claimed',True)}[mode]
    if (report['result'],phase,report['dispatch_may_have_occurred'])!=expected:
        raise ValueError('independent_runtime/result '+mode+' '+repr(report))
    if (audit.read()[0] is not None)!=(phase is not None):raise ValueError('independent_runtime/audit')
    if report['authentication_posts']!=0 or report['real_accounting_verified'] is not False:raise ValueError('independent_runtime/report')
    prepared.close()


def main():
    if sys.platform!='linux' or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        raise ValueError('independent_runtime/tmpfs')
    os.environ['PYTHONPATH']=str(Path(__file__).resolve().parent)
    for mode in ('success','dry','tamper','bad_ready','lost','changed','bad_ack'):scenario(mode)
    print(json.dumps(dict(result='SYNTHETIC_INDEPENDENT_BROKER_VERIFIED',scenarios=7,account_data_posts=0,
                          authentication_posts=0,ambiguous_claims_not_replayed=True)))


if __name__=='__main__':main()
