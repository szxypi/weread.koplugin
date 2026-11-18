#!/usr/bin/env python3
"""Read-only audit of the single claimed CB native-batch fixture request."""
import argparse,hashlib,json,os,resource,time
from cb_cloud_position import state
from readtime_statistics import compare
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_upload_epub import TEXT
from verify_cb_fixture_native_batch import stores,backend,NativeRead
from verify_cb_reading import CbReadingProbe
from verify_readtime_upload import counters,expected_statistics
from verify_position_roundtrip import canonical
from verify_web_source_progress import BASE,WebSourceProbe


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',positive_time_replays=0,account_data_writes=0,private_data_in_report=False)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=reader=None;phase='session'
    try:
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid']);journal,seed,intent=stores();record,_=journal.read()
        if not record or record['phase']!='imported' or record['plan']['owner']!=saved['vid']:raise ValueError('audit/record')
        target=record['target'];time_raw=intent.backend.load();time_record=json.loads(time_raw) if time_raw else None
        baseline_raw=backend('org.codex.weread.cb-native-batch-fixture-baseline-v1').load()
        evidence=json.loads(baseline_raw) if baseline_raw else None
        if (not time_record or not evidence or not intent.verify(time_record,time_raw) or evidence.get('attempt')!=record['attempt']
                or evidence.get('owner_sha256')!=hashlib.sha256(saved['vid'].encode()).hexdigest()
                or evidence.get('book_sha256')!=hashlib.sha256(target.encode()).hexdigest()
                or hashlib.sha256(canonical(evidence['baseline']).encode()).hexdigest()!=time_record.get('baseline')
                or not seed.verify(seed.backend.load(),saved['vid'],target,record['attempt'])):raise ValueError('audit/intent')
        baseline=evidence['baseline'];payload=baseline['body'];rows=payload['books'][0]['hours']
        if payload['books'][0]['bookId']!=target or payload['books'][0]['readingTime']!=2 or sum(row['readingTime'] for row in rows)!=2:
            raise ValueError('audit/body')
        phase='source';web=CbReadingProbe();web.vid=saved['vid'];web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if sample['source_raw_sha256']!=baseline['source'] or TEXT not in sample['source']:raise ValueError('audit/source')
        chapters=sample['chapters'];reader=WebSourceProbe();reader.vid=saved['vid']
        for cookie in web.cookies:reader.set_cookie(cookie.name,cookie.value)
        reader.verify_account();reader.book_id=target;reader.chapter=sample['chapter_uid']
        api=NativeRead(grant,target);phase='readback';observations=[]
        for index in range(2):
            if index:time.sleep(2)
            native=api.progress();remote=reader.request('progress_after',BASE+'/web/book/getProgress?bookId='+target)
            native_count,web_count=counters(native,target),counters(remote,target);stats=api.stats()
            native_state=state(native,target,chapters,'native');web_state=state(remote,target,chapters,'web')
            fields=('chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')
            native_position={key:native_state[key] for key in fields} if native_state.get('kind')=='located' else None
            web_position={key:web_state[key] for key in fields} if web_state.get('kind')=='located' else None
            base=baseline['counters'];expected=dict(base,readingTime=base['readingTime']+2)
            before=baseline['stats'];month=str(before['baseTime']);observed={month:stats};previous={month:before}
            current=payload['books'][0]['timestamp'];start=current-2
            candidates=[]
            for zone in ('+08:00',rows[0]['timeZone']):
                for days in (0,1):
                    candidate=expected_statistics(before,start,2,time_zone=zone);candidate['readDays']=before['readDays']+days
                    candidates.append({month:candidate})
            matched=any(compare(candidate,observed) is not None for candidate in candidates)
            row=dict(native_position_same=native_position==baseline['position'],web_position_same=web_position==baseline['position'],
                native_state=native_state.get('kind'),web_state=web_state.get('kind'),
                native_summary_present=native_state.get('summary_present') is True,web_summary_present=web_state.get('summary_present') is True,
                native_coordinates_same=native_position is not None and all(native_position[k]==baseline['position'][k]
                    for k in ('chapter_uid','chapter_idx','chapter_offset','raw_percent')),
                web_coordinates_same=web_position is not None and all(web_position[k]==baseline['position'][k]
                    for k in ('chapter_uid','chapter_idx','chapter_offset','raw_percent')),
                native_seconds_delta=native_count['readingTime']-base['readingTime'],web_seconds_delta=web_count['readingTime']-base['readingTime'],
                other_native_counters_same=all(native_count[k]==base[k] for k in ('recordReadingTime','ttsTime')),
                other_web_counters_same=all(web_count[k]==base[k] for k in ('recordReadingTime','ttsTime')),
                monthly_seconds_delta=stats['totalReadTime']-before['totalReadTime'],days_delta=stats['readDays']-before['readDays'],
                exact_target_statistics=matched,stats_unchanged=compare(previous,observed) is not None)
            observations.append(row)
        report.update(result='READ_ONLY_AUDIT',phase='complete',observations=observations,source_unchanged=True,
                      old_trial_verified=False,baseline_binding_valid=True,fixture_retained=True)
    except Exception as error:
        trace=error.__traceback__
        while trace and trace.tb_next:trace=trace.tb_next
        report.update(result='UNVERIFIED',phase=phase,failure_type=type(error).__name__,failure_line=trace.tb_lineno if trace else 0,
                      failure_file=os.path.basename(trace.tb_frame.f_code.co_filename) if trace else '')
    finally:
        if reader:reader.close()
        if web:web.samples.clear();web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result']!='READ_ONLY_AUDIT')


if __name__=='__main__':raise SystemExit(main())
