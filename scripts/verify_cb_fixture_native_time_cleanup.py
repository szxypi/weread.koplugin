#!/usr/bin/env python3
"""Clean the stopped native-time fixture only when no UI write was claimed."""
import argparse,hashlib,json,re,resource,time
from cb_cloud_position import state
from cb_fixture_position import LONG_SUMMARY,plan as position_plan
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,SessionStore
from synthetic_epub_trial import check
from synthetic_upload_epub import TEXT
from verify_cb_fixture_native_time_trial import stores
from verify_cb_fixture_web_time import NativeRead
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe,acknowledged,readback
from verify_readtime_upload import counters
from verify_translation_preflight import save_refreshed_web_session


def run(saved,session,native,grant,journal,seed_intent,ui_intent,*,apply=False,probe_factory=Probe):
    report=dict(result='UNVERIFIED',phase='preflight',fixture_only=True,ui_writes_claimed=0,cleanup_posts=0,private_data_in_report=False)
    web=None
    try:
        record,receipt=journal.read();owner=saved['vid']
        if not record or record['phase']!='imported' or record['plan']['owner']!=owner or native.load(owner)!=grant:
            raise ValueError('native_time_cleanup/owner')
        target=record['target'];attempt=record['attempt'];seed_receipt=seed_intent.backend.load()
        ui_raw=ui_intent.backend.load();ui=json.loads(ui_raw) if ui_raw else None
        if (not seed_intent.verify(seed_receipt,owner,target,attempt) or not isinstance(ui,dict)
                or set(ui)!={'schema','scope','owner','book','attempt','baseline','claimed'}
                or ui.get('schema')!=1 or ui.get('scope')!=ACCOUNT or type(ui.get('claimed')) is not int or ui['claimed']!=0
                or ui.get('owner')!=hashlib.sha256(owner.encode()).hexdigest()
                or ui.get('book')!=hashlib.sha256(target.encode()).hexdigest() or ui.get('attempt')!=attempt
                or not isinstance(ui.get('baseline'),str) or not re.fullmatch('[a-f0-9]{64}',ui['baseline'])
                or not ui_intent.verify(ui,ui_raw)):
            raise ValueError('native_time_cleanup/claimed')
        probe=probe_factory(journal,lambda value:native.load(owner)==value)
        check(record['plan'],grant,probe.shelf(grant),target,True)
        web=CbReadingProbe();web.vid=owner;web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if sample['book_id']!=target or sample['source_format']!='web_xhtml' or TEXT not in sample['source']:
            raise ValueError('native_time_cleanup/source')
        planned=position_plan(target,sample,require_unstarted=False)
        progress=state(sample['context']['progress'],target,sample['chapters'],'web')
        if (progress.get('kind')!='located' or progress['chapter_uid']!=planned['chapter']
                or progress['chapter_offset']!=planned['first'] or progress['summary']!=LONG_SUMMARY):
            raise ValueError('native_time_cleanup/position')
        api=NativeRead(grant,target);observed=counters(api.progress(),target)
        if observed['readingTime']!=0:raise ValueError('native_time_cleanup/unexpected_time')
        check(record['plan'],grant,probe.shelf(grant),target,True)
        report.update(result='READ_ONLY_PREVIEW',phase='audited',source_verified=True,no_time_recorded=True)
        if not apply:return report
        if native.load(owner)!=grant or not ui_intent.verify(ui,ui_raw) or not seed_intent.verify(seed_receipt,owner,target,attempt):
            raise ValueError('native_time_cleanup/changed')
        receipt=journal.advance(receipt,'cleanup_pending');report.update(result='UNVERIFIED',phase='cleanup_pending')
        ok=False
        try:ok=acknowledged(probe.cleanup(grant,receipt))
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,grant,record['plan'],target,False,3 if ok else 1,time.sleep)
        if not ok or not restored:raise ValueError('native_time_cleanup/unconfirmed')
        check(record['plan'],grant,probe.shelf(grant),target,False);journal.advance(receipt,'restored')
        report.update(result='FIXTURE_REMOVED',phase='restored',fixture_removal_confirmed=True,original_shelf_restored=True)
    except Exception as error:
        if isinstance(error,ValueError) and str(error).startswith('native_time_cleanup/'):report['reason']=str(error)
    finally:
        if web:
            if web.authenticated:
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
        print(json.dumps(dict(result='OFFLINE_ONLY',ui_writes_claimed=0,cleanup_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',ui_writes_claimed=0,cleanup_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_REMOVED'))


if __name__=='__main__':raise SystemExit(main())
