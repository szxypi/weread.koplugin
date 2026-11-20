#!/usr/bin/env python3
"""One native zero-version time request on a newly imported self-authored TXT.

Offline by default. The temporary book, first native position, pre-dispatch
evidence and one native time request have separate one-shot records. A missing
acknowledgement or mismatched readback stops without replay or fixture cleanup.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import resource
import secrets
import tempfile
import time

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent as TimeIntent
from cb_initial_fixture_intent import Intent as InitialIntent
from cb_native_readtime_model import batch as positive_batch
from readtime_upload_model import confirmed, guest_token, local_zone
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_fixture_web_time import NativeRead
from verify_cb_initial_fixture_ui_trial import ui_command
from verify_cb_txt_fixture import Journal, Receipt
from verify_cb_txt_initial_fixture_ui_trial import execute as first_execute
from verify_cb_txt_native_time_fixture_ui_trial import read_pair
from verify_cb_txt_version_fixture import inspect_fixture
from verify_eink_login import BASE, NativeProbe
from verify_native_statistics import period
from verify_position_roundtrip import canonical
from verify_readtime_upload import counters, expected_statistics


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-txt-zero-native-batch-' + name + '-v1', account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-txt-zero-native-batch-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')), Receipt(backend=backend('receipt')),
            InitialIntent(backend=backend('initial'), lock=lock('initial')),
            TimeIntent(backend=backend('send'), lock=lock('send')),
            Evidence(backend=backend('baseline'), lock=lock('baseline')))


def zero_batch(grant, target, start, now, guest, config, summary, random1, random2, zone):
    # The native signature does not include bookVersion. Build the standard
    # bounded two-second request, then set the actually observed wire value.
    rows = [dict(start_time=start, duration=2, time_zone=zone, book_version=1)]
    value = positive_batch(grant, target, rows, guest, config, now, random1, now * 1000, random2,
                           current_zone=zone, summary=summary)
    value['books'][0]['bookVersion'] = 0
    return value


class ZeroBatchProbe(NativeRead):
    def __init__(self, credentials, book, authority):
        super().__init__(credentials, book); self.authority=authority; self.used=set(); self.sent=0; self.expected=None
    def capability(self, name):
        routes={'config':('/config?token=1','batch_config'),'feature':('/feature?synckey=0','batch_feature')}
        if name not in routes or name in self.used or not self.authority(): raise ValueError('txt_zero/scope')
        self.used.add(name); path,stage=routes[name]
        return NativeProbe.request(self,stage,BASE+path,credentials=self.credentials)
    def bind(self, value, summary):
        if self.expected is not None or not self.authority() or not isinstance(value,dict) or len(value.get('books',[]))!=1:
            raise ValueError('txt_zero/scope')
        book=value['books'][0]
        if (book.get('bookId')!=self.book or type(book.get('bookVersion')) is not int or book['bookVersion']!=0
                or book.get('summary')!=summary or book.get('readingTime')!=2 or book.get('isResendReadingInfo')!=1
                or sum(hour.get('readingTime',0) for hour in book.get('hours',[]))!=2): raise ValueError('txt_zero/body')
        self.expected=deepcopy(value)
    def send_once(self, value, permit):
        if self.sent or self.expected is None or value!=self.expected or not self.authority() or not permit():
            raise ValueError('txt_zero/consumed')
        stamp=value['books'][0].get('timestamp')
        if type(stamp) is not int or not 0<=time.time()-stamp<30: raise ValueError('txt_zero/stale')
        self.sent=1
        return NativeProbe.request(self,'batch_write',BASE+'/book/batchUploadProgress',body=value,credentials=self.credentials,timeout=20)


def zero_trial(context, report, grant, intent, evidence, api, version_inspector, *, clock=time.time,
               monotonic=time.monotonic, sleep=time.sleep, random=secrets.randbelow):
    plan=context['plan']; offset=plan['first']; summary=PlainSource(context['sample']['source']).excerpt(offset)['text']
    expected=dict(readingTime=0,recordReadingTime=0,ttsTime=0)
    report.update(native_time_posts_known=0,native_time_write_uncertain=False,native_time_acknowledged=False)
    def authority(): return context['authority']() and context['shelf_current']()
    if not authority() or context['attest']()!=context['command']: return False
    version={}
    if not version_inspector(version) or version.get('native_version_category')!='zero' or any(
            version.get(key)!='absent' for key in ('catalog_root_version_category','catalog_book_version_category')): return False
    before,updated=read_pair(context,offset,summary,expected)
    if before!=context['initial_observed'] or read_pair(context,offset,summary,expected)!=(before,updated): return False
    stats=api.stats()
    if counters(api.progress(),context['target'])!=expected or api.stats()!=stats: return False
    config=api.capability('config'); guest,_=guest_token(api.capability('feature'))
    zone=local_zone(); wall=clock(); mono=monotonic(); start=math.ceil(wall)
    if zone!='+08:00' or int(wall+60+28800)//86400!=int(wall+28800)//86400: return False
    sleep(max(0,start+2-wall)+.01)
    if not 2<=monotonic()-mono<=4 or not 0<=clock()-(start+2)<2: return False
    if (not authority() or context['attest']()!=context['command'] or api.stats()!=stats
            or read_pair(context,offset,summary,expected)!=(before,updated)): return False
    version_again={}
    if (not version_inspector(version_again) or version_again!=version or not authority()
            or context['attest']()!=context['command'] or api.stats()!=stats
            or read_pair(context,offset,summary,expected)!=(before,updated)): return False
    now=int(clock())
    if (now<start+2 or now>start+30 or (start+28800)//86400!=(now+28800)//86400
            or period('monthly',start)[0]!=period('monthly',now)[0]): return False
    payload=zero_batch(grant,context['target'],start,now,guest,config.get('token'),summary,random(1000),random(1000),zone)
    candidates=[]
    for delta in (0,1):
        item=expected_statistics(stats,start,2,time_zone=zone);item['readDays']=stats['readDays']+delta;candidates.append(item)
    baseline=dict(source=context['source_hash'],position=before['web']['projection'],updated_at=updated,
                  counters=expected,stats=stats,body=payload)
    evidence.save(dict(schema=1,owner_sha256=hashlib.sha256(context['owner'].encode()).hexdigest(),
        book_sha256=hashlib.sha256(context['target'].encode()).hexdigest(),attempt=context['attempt'],baseline=baseline))
    bound=hashlib.sha256(canonical(baseline).encode()).hexdigest()
    reservation=intent.reserve(context['owner'],context['target'],context['attempt'],bound)
    api.bind(payload,summary);permit=intent.claim(reservation)
    if (not authority() or not intent.verify(reservation,permit) or api.stats()!=stats
            or read_pair(context,offset,summary,expected)!=(before,updated)): return False
    report['native_time_write_uncertain']=True
    try: response=api.send_once(payload,lambda:authority() and intent.verify(reservation,permit))
    finally: report['native_time_posts_known']=api.sent
    report['native_time_acknowledged']=confirmed(response)
    if not report['native_time_acknowledged']: return False
    target_counts=dict(expected,readingTime=2);matched=None
    for index in range(4):
        if index:sleep(min(index*2,5))
        current_stats=api.stats()
        if current_stats not in [stats,*candidates]: return False
        try: value,_stamp=read_pair(context,offset,summary,target_counts)
        except ValueError:
            if counters(api.progress(),context['target']) not in (expected,target_counts): return False
            continue
        if current_stats in candidates and counters(api.progress(),context['target'])==target_counts:
            matched=value;break
    if matched is None or read_pair(context,offset,summary,target_counts)[0]!=matched: return False
    if any(matched[channel][field]!=before[channel][field] for channel in ('native','web') for field in ('presence','projection')): return False
    if not authority() or not intent.verify(reservation,permit): return False
    report.update(native_time_write_uncertain=False,zero_version_native_batch_verified=True,
                  book_seconds_delta=2,statistics_seconds_delta=2,dual_readback=True)
    return True


def execute(saved,session,native,grant,journal,receipt,initial,intent,evidence,command,*,apply=False,
            first=first_execute,api_factory=ZeroBatchProbe,inspector=inspect_fixture):
    if intent.backend.load() is not None or evidence.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,native_time_write_uncertain=False)
    def after(context,report):
        def authority(): return context['authority']() and native.load(context['owner'])==grant
        def version_check(summary):
            session_view=dict(vid=context['owner'],cookies=context['cookies']())
            return inspector(session_view,grant,context['target'],lambda value:authority() and value==grant,
                             summary,expected_source=context['source_hash'])
        return zero_trial(context,report,grant,intent,evidence,api_factory(grant,context['target'],authority),version_check)
    result=first(saved,session,native,grant,journal,receipt,initial,command,apply=apply,after_verified=after)
    if type(result.get('account_data_writes_known')) is int:
        result['account_data_writes_known']+=result.get('native_time_posts_known',0)
    if result.get('result')=='CB_TXT_FIRST_NATIVE_UI_VERIFIED' and result.get('zero_version_native_batch_verified') is True:
        result['result']='CB_TXT_ZERO_NATIVE_BATCH_VERIFIED'
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        command=ui_command();session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),command,apply=args.apply)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,native_time_write_uncertain=args.apply)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result));return int(result['result'] not in ('READ_ONLY_PREVIEW','CB_TXT_ZERO_NATIVE_BATCH_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
