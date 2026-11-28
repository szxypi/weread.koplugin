#!/usr/bin/env python3
"""Read-only audit, then exact cleanup of the retained native-batch fixture."""
import argparse,hashlib,json,resource,time
from cb_cloud_position import state
from readtime_statistics import compare
from secure_native_session import NativeSessionStore
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import check
from synthetic_upload_epub import TEXT
from verify_cb_fixture_native_batch import NativeRead,backend,stores
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe,acknowledged,readback
from verify_position_roundtrip import canonical
from verify_readtime_upload import counters,expected_statistics
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

OBSERVATION_SERVICE='org.codex.weread.cb-native-batch-fixture-observation-v1'


def run(saved,session,native,grant,journal,seed_intent,time_intent,observation,*,apply=False,probe_factory=Probe):
    report=dict(result='UNVERIFIED',phase='preflight',fixture_only=True,positive_time_replays=0,cleanup_posts=0,
                private_data_in_report=False,original_time_trial_verified=False)
    web=reader=None
    try:
        record,receipt=journal.read();owner=saved['vid']
        if not record or record['phase']!='imported' or record['plan']['owner']!=owner or native.load(owner)!=grant:
            raise ValueError('cb_batch_cleanup/owner')
        target=record['target'];attempt=record['attempt'];seed_receipt=seed_intent.backend.load()
        raw=time_intent.backend.load();intent=json.loads(raw) if raw else None
        evidence_raw=backend('org.codex.weread.cb-native-batch-fixture-baseline-v1').load()
        evidence=json.loads(evidence_raw) if evidence_raw else None
        if (not seed_intent.verify(seed_receipt,owner,target,attempt) or not isinstance(intent,dict)
                or intent.get('attempt')!=attempt or intent.get('owner')!=hashlib.sha256(owner.encode()).hexdigest()
                or intent.get('book')!=hashlib.sha256(target.encode()).hexdigest() or not time_intent.verify(intent,raw)
                or not evidence or evidence.get('attempt')!=attempt or evidence.get('owner_sha256')!=intent['owner']
                or evidence.get('book_sha256')!=intent['book']
                or hashlib.sha256(canonical(evidence['baseline']).encode()).hexdigest()!=intent.get('baseline')):
            raise ValueError('cb_batch_cleanup/intent')
        if observation.load() is not None:raise ValueError('cb_batch_cleanup/already_observed')
        baseline=evidence['baseline'];payload=baseline['body'];book=payload['books'][0];hours=book['hours']
        if book['bookId']!=target or book['readingTime']!=2 or sum(row['readingTime'] for row in hours)!=2:
            raise ValueError('cb_batch_cleanup/body')
        probe=probe_factory(journal,lambda value:native.load(owner)==value)
        check(record['plan'],grant,probe.shelf(grant),target,True)
        web=CbReadingProbe();web.vid=owner;web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if (sample['book_id']!=target or sample['source_format']!='web_xhtml' or TEXT not in sample['source']
                or sample['source_raw_sha256']!=baseline['source']):raise ValueError('cb_batch_cleanup/source')
        reader=WebSourceProbe();reader.vid=owner
        for cookie in web.cookies:reader.set_cookie(cookie.name,cookie.value)
        reader.verify_account();reader.book_id=target;reader.chapter=sample['chapter_uid']
        api=NativeRead(grant,target);observations=[]
        for _i in range(2):
            native_raw=api.progress();web_raw=reader.request('progress_after',BASE+'/web/book/getProgress?bookId='+target)
            native_point=state(native_raw,target,sample['chapters'],'native');web_point=state(web_raw,target,sample['chapters'],'web')
            native_counts,web_counts=counters(native_raw,target),counters(web_raw,target);stats=api.stats()
            wanted=dict(baseline['counters'],readingTime=baseline['counters']['readingTime']+2)
            if (native_point.get('kind')!='located' or web_point.get('kind')!='located'
                    or native_point.get('summary_present') or web_point.get('summary_present')
                    or any(native_point[k]!=baseline['position'][k] or web_point[k]!=baseline['position'][k]
                           for k in ('chapter_uid','chapter_idx','chapter_offset','raw_percent'))
                    or native_counts!=wanted or web_counts!=wanted):raise ValueError('cb_batch_cleanup/position')
            month=str(baseline['stats']['baseTime']);candidates=[]
            for zone in ('+08:00',hours[0]['timeZone']):
                for days in (0,1):
                    expected=expected_statistics(baseline['stats'],book['timestamp']-2,2,time_zone=zone)
                    expected['readDays']=baseline['stats']['readDays']+days;candidates.append({month:expected})
            if not any(compare(candidate,{month:stats}) is not None for candidate in candidates):
                raise ValueError('cb_batch_cleanup/statistics')
            observations.append(dict(native=native_point,web=web_point,counters=native_counts,stats=stats))
        if observations[0]!=observations[1]:raise ValueError('cb_batch_cleanup/unstable')
        check(record['plan'],grant,probe.shelf(grant),target,True)
        report.update(result='READ_ONLY_PREVIEW',phase='audited',source_verified=True,coordinates_unchanged=True,
                      summary_missing_both_channels=True,book_daily_monthly_increased_two=True)
        if not apply:return report
        snapshot=dict(schema=1,owner_sha256=intent['owner'],book_sha256=intent['book'],attempt=attempt,
            prior_claim_sha256=hashlib.sha256(raw).hexdigest(),baseline_sha256=intent['baseline'],observed_at=int(time.time()),
            observation=observations[0],prior_trial_verified=False)
        encoded=canonical(snapshot).encode();observation.save(encoded)
        if observation.load()!=encoded:raise ValueError('cb_batch_cleanup/observation')
        report['observation_saved']=True
        check(record['plan'],grant,probe.shelf(grant),target,True)
        if native.load(owner)!=grant or not time_intent.verify(intent,raw) or not seed_intent.verify(seed_receipt,owner,target,attempt):
            raise ValueError('cb_batch_cleanup/changed')
        receipt=journal.advance(receipt,'cleanup_pending');report.update(result='UNVERIFIED',phase='cleanup_pending')
        ok=False
        try:ok=acknowledged(probe.cleanup(grant,receipt))
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,grant,record['plan'],target,False,3 if ok else 1,time.sleep)
        if not ok or not restored:raise ValueError('cb_batch_cleanup/unconfirmed')
        check(record['plan'],grant,probe.shelf(grant),target,False);journal.advance(receipt,'restored')
        report.update(result='FIXTURE_REMOVED',phase='restored',fixture_removal_confirmed=True,original_shelf_restored=True)
    except Exception as error:
        if isinstance(error,ValueError) and str(error).startswith('cb_batch_cleanup/'):report['reason']=str(error)
    finally:
        if reader:
            if reader.authenticated:
                try:save_refreshed_web_session(session,saved,reader)
                except Exception:report['result']='UNVERIFIED'
            reader.close()
        if web:web.samples.clear();web.close()
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
        report=run(saved,session,native,grant,*stores(),MacKeychain(service=OBSERVATION_SERVICE,account=ACCOUNT),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',positive_time_replays=0,cleanup_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_REMOVED'))


if __name__=='__main__':raise SystemExit(main())
