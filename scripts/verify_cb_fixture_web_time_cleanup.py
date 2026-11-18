#!/usr/bin/env python3
"""Audit and remove the exact retained Web-time test fixture, without replay.

The prior time result stays UNVERIFIED. Its readback is preserved in Keychain
before the separately journaled, single fixture removal. Offline by default.
"""
import argparse
import hashlib
import json
import resource
import time

from cb_fixture_position import LONG_SUMMARY,plan as position_plan
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import check
from synthetic_upload_epub import TEXT
from verify_cb_fixture_web_time import NativeRead,position,stores
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe,acknowledged,readback
from verify_position_roundtrip import canonical
from verify_readtime_upload import counters
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

OBSERVATION_SERVICE='org.codex.weread.cb-web-time-fixture-observation-v1'


def run(saved,session,native,grant,journal,seed_intent,time_intent,observation,*,apply=False,probe_factory=Probe):
    report=dict(result='UNVERIFIED',phase='preflight',fixture_only=True,positive_time_replays=0,cleanup_posts=0,
                private_data_in_report=False,original_time_trial_verified=False)
    web=reader=None
    try:
        record,receipt=journal.read();owner=saved['vid']
        if not record or record['phase']!='imported' or record['plan']['owner']!=owner or native.load(owner)!=grant:
            raise ValueError('cb_time_cleanup/owner')
        target=record['target'];attempt=record['attempt'];seed_receipt=seed_intent.backend.load()
        raw=time_intent.backend.load();intent=json.loads(raw) if raw else None
        if (not seed_intent.verify(seed_receipt,owner,target,attempt) or not isinstance(intent,dict)
                or intent.get('attempt')!=attempt or intent.get('owner')!=hashlib.sha256(owner.encode()).hexdigest()
                or intent.get('book')!=hashlib.sha256(target.encode()).hexdigest() or not time_intent.verify(intent,raw)):
            raise ValueError('cb_time_cleanup/intent')
        if observation.load() is not None:raise ValueError('cb_time_cleanup/already_observed')
        report['phase']='shelf'
        probe=probe_factory(journal,lambda value:native.load(owner)==value)
        before=probe.shelf(grant);check(record['plan'],grant,before,target,True)
        web=CbReadingProbe();web.vid=owner;web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        report['phase']='source'
        if sample['book_id']!=target or sample['source_format']!='web_xhtml' or TEXT not in sample['source']:
            raise ValueError('cb_time_cleanup/source')
        planned=position_plan(target,sample,require_unstarted=False);chapters=sample['chapters']
        api=NativeRead(grant,target);observations=[]
        reader=WebSourceProbe();reader.vid=owner
        for cookie in web.cookies:reader.set_cookie(cookie.name,cookie.value)
        reader.verify_account();reader.book_id=target;reader.chapter=planned['chapter']
        report['phase']='readback'
        for _i in range(2):
            native_raw=api.progress();web_raw=reader.request('progress_after',BASE+'/web/book/getProgress?bookId='+target)
            native_point=position(native_raw,target,chapters,'native');web_point=position(web_raw,target,chapters)
            nc,wc=counters(native_raw,target),counters(web_raw,target);stats=api.stats()
            report['readback_checks']=dict(position_matches=native_point==web_point,counters_match=nc==wc,
                observed_two_seconds=nc['readingTime']==2,chapter_matches=web_point['chapter_uid']==planned['chapter'],
                coordinate_matches=web_point['chapter_offset']==planned['first'],summary_matches=web_point['summary']==LONG_SUMMARY)
            if (native_point!=web_point or nc!=wc or nc['readingTime']!=2 or web_point['chapter_uid']!=planned['chapter']
                    or web_point['chapter_offset']!=planned['first'] or web_point['summary']!=LONG_SUMMARY):
                raise ValueError('cb_time_cleanup/position')
            observations.append(dict(position=web_point,counters=nc,stats=stats))
        if observations[0]!=observations[1]:raise ValueError('cb_time_cleanup/unstable')
        report['phase']='final_shelf'
        check(record['plan'],grant,probe.shelf(grant),target,True)
        snapshot=dict(schema=1,owner_sha256=hashlib.sha256(owner.encode()).hexdigest(),book_sha256=hashlib.sha256(target.encode()).hexdigest(),
            attempt=attempt,prior_claim_sha256=hashlib.sha256(raw).hexdigest(),source_sha256=sample['source_raw_sha256'],
            observed_at=int(time.time()),observation=observations[0],prior_trial_verified=False)
        encoded=canonical(snapshot).encode()
        report.update(readonly_audit_passed=True,channels_agree=True,synthetic_book_observed_seconds=2,
                      original_statistics_baseline_unavailable=True,phase='audited')
        if not apply:report['result']='READ_ONLY_PREVIEW';return report
        observation.save(encoded)
        if observation.load()!=encoded:raise ValueError('cb_time_cleanup/observation')
        report['observation_saved']=True
        check(record['plan'],grant,probe.shelf(grant),target,True)
        if native.load(owner)!=grant or not time_intent.verify(intent,raw) or not seed_intent.verify(seed_receipt,owner,target,attempt):
            raise ValueError('cb_time_cleanup/changed')
        receipt=journal.advance(receipt,'cleanup_pending');report['phase']='cleanup_pending'
        ok=False
        try:ok=acknowledged(probe.cleanup(grant,receipt))
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,grant,record['plan'],target,False,3 if ok else 1,time.sleep)
        if not ok or not restored:raise ValueError('cb_time_cleanup/unconfirmed')
        check(record['plan'],grant,probe.shelf(grant),target,False)
        journal.advance(receipt,'restored')
        report.update(result='FIXTURE_REMOVED',phase='restored',fixture_removal_confirmed=True,original_shelf_restored=True)
    except Exception as error:
        report['failure_type']=type(error).__name__
        trace=error.__traceback__
        while trace and trace.tb_next:trace=trace.tb_next
        if trace:report['failure_line']=trace.tb_lineno
        if isinstance(error,ValueError) and str(error).startswith('cb_time_cleanup/'):
            report['reason']=str(error)
    finally:
        if reader:
            if reader.authenticated:
                try:save_refreshed_web_session(session,saved,reader)
                except Exception:report['result']='UNVERIFIED'
            reader.close()
        if web:
            if web.authenticated and not reader:
                try:save_refreshed_web_session(session,saved,web)
                except Exception:report['result']='UNVERIFIED'
            web.samples.clear();web.close()
        if saved:saved.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',positive_time_replays=0,cleanup_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        observation=MacKeychain(service=OBSERVATION_SERVICE,account=ACCOUNT)
        report=run(saved,session,native,grant,*stores(),observation,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',positive_time_replays=0,cleanup_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_REMOVED'))


if __name__=='__main__':raise SystemExit(main())
