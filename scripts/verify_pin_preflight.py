#!/usr/bin/env python3
"""Read-only candidate and three-channel baselines for a pin observation."""
import argparse
import hashlib
import json
from urllib.parse import urlencode
from native_shelf_trial import bind,check
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_eink_login import BASE
from verify_native_shelf_trial import ShelfTrialProbe
from verify_pin_gateway import SERVICE,KeyWeb,gateway,validate
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class PinProbe(ShelfTrialProbe):
    def __init__(self):super().__init__();self.target=None
    def guard(self,stage,url,body):
        if (stage=='pin_progress' and self.target and body is None
                and url==BASE+'/book/getProgress?'+urlencode({'bookId':self.target})):return
        return super().guard(stage,url,body)


def fingerprint(value):return hashlib.sha256(canonical(value)).hexdigest()


def progress_fingerprint(value):
    # The service includes its current clock, which is not reading state.
    # Retain and compare every other field, including unknown future fields.
    if not isinstance(value,dict):raise ValueError('pin/progress_invalid')
    projected=dict(value)
    if 'timestamp' in projected:
        if type(projected['timestamp']) is not int or projected['timestamp']<0:raise ValueError('pin/progress_invalid')
        del projected['timestamp']
    return fingerprint(projected)


def reading_fingerprint(value):
    # Membership operations can legitimately change this one metadata field.
    # All reading fields and all unknown fields remain part of the digest.
    progress_fingerprint(value)
    book=value.get('book')
    if not isinstance(book,dict) or type(book.get('updateTime')) is not int or book['updateTime']<0:
        raise ValueError('pin/progress_invalid')
    projected=dict(value);projected.pop('timestamp',None);projected['book']=dict(book)
    del projected['book']['updateTime']
    return fingerprint(projected)


def prepare(probe,web,credentials,key,report,*,progress_digest=progress_fingerprint):
    native=probe.prepare(credentials)
    membership=native['membership'];probe.target=membership['book_id']
    native_now=probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials)
    web_now=web.request('shelf',WEB+'/web/shelf/sync')
    def read_gateway():
        report['gateway_read_posts']+=1
        return gateway(key)
    official=read_gateway()
    plans={'native':native}
    for name,source in (('web',web_now),('gateway',official)):
        try:plans[name]=bind(membership,source)
        except (ValueError,TypeError,KeyError):raise ValueError('pin/baseline_'+name) from None
    for name,source in (('native',native_now),('web',web_now),('gateway',official)):check(plans[name],source,False)
    progress=probe.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
    again=probe.request('pin_progress',BASE+'/book/getProgress?'+urlencode({'bookId':probe.target}),credentials=credentials)
    if (progress_digest(progress)!=progress_digest(again)
            or progress_fingerprint(progress)!=progress_fingerprint(again)):
        raise ValueError('pin/progress_changed')
    for name,source in (('native',probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials)),
                        ('web',web.request('shelf',WEB+'/web/shelf/sync')),('gateway',read_gateway())):check(plans[name],source,False)
    return plans,progress_digest(progress),hashlib.sha256(key.encode()).hexdigest()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,gateway_read_posts=0)
    saved=credentials=key=None;probe=PinProbe();web=KeyWeb()
    try:
        if args.saved_session:
            from verify_native_thought_trial import other_pending
            from secure_pin_trial import PinTrialStore
            if other_pending() or PinTrialStore().pending():raise ValueError('pin/pending')
            sessions=SessionStore();saved=sessions.load();owner=saved['vid'];credentials=NativeSessionStore().load(owner)
            raw=MacKeychain(service=SERVICE,account=ACCOUNT).load()
            key=validate(json.loads(raw),owner)['key'];web.vid=owner
            for name,value in saved['cookies'].items():web.set_cookie(name,value)
            web.verify_account();plans,progress_sha,skill_sha=prepare(probe,web,credentials,key,report)
            web.verify_account();save_refreshed_web_session(sessions,saved,web)
            report.update(result='PREFLIGHT_VERIFIED',candidate_absent=True,baseline_channels=3,
                native_shelf_books=probe.payload['shelf_books'],
                plan_fingerprint=fingerprint(dict(plans=plans,progress_sha256=progress_sha,skill_sha256=skill_sha)))
    except Exception as error:
        report['result']='UNVERIFIED'
        if str(error) in {'pin/baseline_web','pin/baseline_gateway','pin/progress_changed','pin/pending'}:
            report['detail']=str(error)
    finally:
        report['native_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in probe.report['stages']]
        report['web_stages']=[{k:r[k] for k in ('stage','status') if k in r} for r in web.report['stages']]
        web.close();key=None
        if credentials:credentials.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
