#!/usr/bin/env python3
"""Time-only then one first-position request on a fresh synthetic TXT.

The two operations use separate permanent one-shot records. Unknown outcomes
retain the exact fixture; the next stage cannot start before two-channel time
and statistics readback. This tests protocol behavior, not production UI.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import resource
import tempfile
import time

from cb_fixture_position import body as fixture_body
from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from cb_txt_initial_fixture_plan import plan as position_plan
from cb_unstarted_position_fixture_flow import run as position_flow
from fetch_weread_epub import sorted_query, weread_sign
from secure_native_session import NativeSessionStore, project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_reading import CbReadingProbe
from verify_cb_txt_fixture import Journal, Receipt
from verify_cb_unstarted_time_fixture import run as time_fixture
from verify_position_roundtrip import WRITE_URL
from verify_web_source_progress import WebSourceProbe


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-unstarted-position-' + name + '-v1', account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-unstarted-position-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')), Receipt(backend=backend('receipt')),
            Intent(backend=backend('time'), lock=lock('time')), Evidence(backend=backend('time-baseline'), lock=lock('time-baseline')),
            Intent(backend=backend('position'), lock=lock('position')),
            Evidence(backend=backend('position-baseline'), lock=lock('position-baseline')))


class PositionProbe(WebSourceProbe):
    """The only possible POST is a single exact, durably claimed request."""
    def __init__(self, plan, owner, authority, intent):
        super().__init__(); self.vid=owner;self.owner=owner;self.book_id=plan['book'];self.chapter=plan['chapter'];self.plan=plan
        self.authority=authority;self.intent=intent;self.expected=None;self.reservation=None;self.permit=None;self.sent=0

    def guard(self, stage, url, body):
        if stage=='first_position':
            if (not self.authenticated or self.vid!=self.owner or self.book_id!=self.plan['book']
                    or not any(c.name=='wr_vid' and c.value==self.owner for c in self.cookies)
                    or self.sent!=1 or url!=WRITE_URL or body!=self.expected
                    or not self.authority() or self.reservation is None
                    or not self.intent.verify(self.reservation,self.permit)
                    or type(body.get('ct')) is not int or not 0<=time.time()-body['ct']<=30):
                raise ValueError('unstarted_position/scope')
            return
        return super().guard(stage,url,body)

    def bind(self, body):
        if self.expected is not None or not isinstance(body,dict) or not self.authority():
            raise ValueError('unstarted_position/bind')
        self.expected=deepcopy(body)

    def send_once(self, body, permit, reservation):
        if (self.sent or self.expected is None or body!=self.expected or not self.authority()
                or not self.intent.verify(reservation,permit)):
            raise ValueError('unstarted_position/consumed')
        self.reservation=reservation;self.permit=permit;self.sent=1
        try:return self.request('first_position',WRITE_URL,body)
        finally:self.permit=None


def position_trial(context, report, intent, evidence, *, probe_factory=PositionProbe, sleep=time.sleep, payload_check=None,
                   fixture='txt'):
    if fixture == 'epub':
        from cb_fixture_position import plan as planner
        from verify_cb_initial_fixture_ui_trial import xhtml_summary as summarize
        source_format = 'web_xhtml'
    elif fixture == 'txt':
        planner = position_plan
        summarize = lambda sample, plan: PlainSource(sample['source']).excerpt(plan['first'])['text']
        source_format = 'web_txt'
    else: raise ValueError('unstarted_position/format')
    if intent.backend.load() is not None or evidence.backend.load() is not None:
        raise ValueError('unstarted_position/consumed')
    sample=context['sample']; source_hash=context['source_hash']; owner=context['owner']; target_id=context['target']
    # Read the source again after time reporting: the original read context may
    # have changed even when its no-chapter position stayed the same.
    def source():
        if not context['authority']() or not context['shelf_current'](): raise ValueError('unstarted_position/owner')
        web=context['connect'](CbReadingProbe,target_id)
        try:
            current=web.inspect(target_id);web.verify_account()
            if (current.get('source_raw_sha256')!=source_hash or current.get('source_format')!=source_format
                    or current.get('chapters')!=sample['chapters'] or current.get('book_id')!=target_id
                    or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                    or not all(web.last_checks.values())):
                raise ValueError('unstarted_position/source')
            context['persist'](web);return current
        finally:web.samples.clear();web.close()
    fresh=source();plan=planner(target_id,fresh)
    summary=summarize(fresh,plan)
    target=dict(book=target_id,chapter=plan['chapter'],index=plan['index'],offset=plan['first'],
                percent=plan['percent'],summary=summary)
    probe=probe_factory(plan,owner,lambda:context['authority']() and context['shelf_current'](),intent)
    try:
        for key,value in context['cookies']().items():probe.set_cookie(key,value)
        probe.verify_account(); reservation={}
        def prepare(_before,_stats):
            current=source();again=planner(target_id,current)
            for key in ('book','chapter','index','first','percent'):
                if again[key]!=plan[key]:raise ValueError('unstarted_position/source_changed')
            value=fixture_body(again,'enter');value['sm']=summary
            value['s']=weread_sign(sorted_query({key:part for key,part in value.items() if key!='s'}))
            if payload_check is not None and payload_check(again,summary,value) is not True:
                raise ValueError('unstarted_position/payload_mismatch')
            return value
        def reserve(before,stats,payload):
            snapshot=dict(source=source_hash,position=before['web']['projection'],updated_at=context['latest']['updated'],
                          counters={k:before['native']['counters'][k]['value'] for k in ('readingTime','recordReadingTime','ttsTime')},
                          stats=stats,body=payload)
            evidence.save(dict(schema=1,owner_sha256=hashlib.sha256(owner.encode()).hexdigest(),
                book_sha256=hashlib.sha256(target_id.encode()).hexdigest(),attempt=context['attempt'],baseline=snapshot))
            return intent.reserve(owner,target_id,context['attempt'],hashlib.sha256(canonical(snapshot)).hexdigest())
        def claim(value):reservation['value']=value;return intent.claim(value)
        def allowed(permit):
            return context['authority']() and context['shelf_current']() and (permit is None or (
                'value' in reservation and intent.verify(reservation['value'],permit)))
        def send(payload,permit):return probe.send_once(payload,permit,reservation['value'])
        result=position_flow(target,context['pair'],context['stats'],prepare,reserve,probe.bind,claim,allowed,send,sleep=sleep)
        report['position_posts']=probe.sent;report['position_write_uncertain']=result['write_uncertain']
        if result['result']=='PASS':
            # Only report a complete success if the same actual source still
            # exists after the position change; failure leaves the book intact.
            after=source()
            if after.get('source_raw_sha256')!=source_hash:
                result.update(result='UNVERIFIED',cleanup_allowed=False)
        probe.verify_account();context['persist'](probe)
        return result
    finally:
        if probe.authenticated:context['persist'](probe)
        probe.close()


def execute(saved,session,native,grant,journal,receipt,time_intent,time_evidence,position_intent,position_evidence,*,apply=False,**kwargs):
    if position_intent.backend.load() is not None or position_evidence.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,position_write_uncertain=False)
    def after(context,report):return position_trial(context,report,position_intent,position_evidence,fixture=kwargs.get('fixture','txt'))
    result=time_fixture(saved,session,native,grant,journal,receipt,time_intent,time_evidence,
                        apply=apply,after_time=after,**kwargs)
    if (result.get('result')=='UNSTARTED_TIME_FIXTURE_VERIFIED'
            and result.get('position_probe',{}).get('result')=='PASS'):
        result['result']='UNSTARTED_TIME_AND_POSITION_VERIFIED'
    elif result.get('result')=='UNSTARTED_TIME_FIXTURE_VERIFIED':
        result['result']='UNVERIFIED'
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,position_write_uncertain=args.apply,
                    authentication_posts=0,fixture_only=True,private_data_in_report=False)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result));return int(result['result'] not in ('READ_ONLY_PREVIEW','UNSTARTED_TIME_AND_POSITION_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
