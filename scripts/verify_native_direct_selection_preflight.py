#!/usr/bin/env python3
"""Read-only owner selection bound to an independently downloaded E-Ink source."""
import argparse
import json
import resource

from native_direct_selection_preflight import bind_native_source
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe
from verify_native_chapter_package import ChapterProbe
from verify_owner_reading import reading_position
from verify_web_source_progress import BASE


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-offset',type=int,choices=range(51),default=15)
    args=parser.parse_args()
    if not args.saved_session:
        print(json.dumps({'result':'OFFLINE_ONLY','account_data_writes':0,'authentication_posts':0}));return 0
    report={'result':'UNVERIFIED','account_data_writes':0,'authentication_posts':0}
    saved=credentials=probe=None;phase='session'
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
        phase='sample';sample,_,_=ChapterProbe().inspect(credentials,args.book_offset)
        probe=SelectionProbe();probe.web.requested_book=sample['book_id'];phase='selection';probe.prepare(saved,credentials)
        phase='native_source';bound=bind_native_source(probe,credentials)
        phase='final';probe.baseline(credentials,'direct_selection_readonly_final')
        probe.web.verify_account()
        after=reading_position(probe.web.request('progress_after',BASE+'/web/book/getProgress?bookId='+bound['book_id']),bound['book_id'])
        if after!=probe.plan.web_position:raise ValueError('direct_selection_preflight/position')
        report.update(result='DIRECT_SELECTION_PREPARED_READONLY',native_web_source_matches=True,
            free_or_owned=True,original_annotations_and_shelf_unchanged=True,reading_position_unchanged=True,
            private_data_written_to_disk=False)
    except (Exception,KeyboardInterrupt) as error:
        report['phase']=phase
        if str(error) in {'direct_selection_preflight/chapter','direct_selection_preflight/source'}:report['reason']=str(error)
        elif 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
    finally:
        if probe:
            probe.web.shards.clear();probe.web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']!='DIRECT_SELECTION_PREPARED_READONLY')


if __name__=='__main__':raise SystemExit(main())
