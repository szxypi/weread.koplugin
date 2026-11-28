#!/usr/bin/env python3
"""One supervised direct-chapter bookmark dry run and optional round trip."""
import argparse
import json
import resource

from native_direct_highlight_trial_broker import execute
from native_direct_cross_bookmark_trial import prepare_origin,verify as verify_cross
from native_direct_selection_preflight import bind_native_source
from native_direct_txt_marks import TxtMarkProbe
from secure_bookmark_trial import BookmarkTrialStore
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_probe import prepare_web_handoff
from verify_native_bookmark_trial import NativeBookmarkProbe
from verify_native_chapter_package import ChapterProbe
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--txt',action='store_true',help='Use a regular zero-version TXT chapter')
    parser.add_argument('--book-offset',type=int,choices=range(51))
    parser.add_argument('--cross-runner-json',help='JSON array of private cross-chapter runner arguments')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command) or (args.apply or args.cross_runner_json) and not args.saved_session:
        parser.error('saved session and private runner required together')
    if args.txt and args.cross_runner_json:
        parser.error('cross-chapter validation currently requires EPUB')
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0}
    if not args.saved_session:print(json.dumps(report));return 0
    saved=credentials=probe=None;phase='intent';store=BookmarkTrialStore(native=True)
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        cross_runner=json.loads(args.cross_runner_json) if args.cross_runner_json else None
        if cross_runner is not None and (not isinstance(cross_runner,list) or not cross_runner or len(cross_runner)>40
                or any(not isinstance(item,str) or not item or len(item)>4096 for item in cross_runner)):
            raise ValueError('direct_bookmark_trial/cross_runner')
        if (other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending()
                or HighlightTrialStore().read()!=(None,None) or HighlightTrialStore(native=True).read()!=(None,None)
                or BookmarkTrialStore().read()!=(None,None) or store.read()!=(None,None)):
            raise ValueError('direct_bookmark_trial/other_pending')
        phase='session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
        offset=args.book_offset if args.book_offset is not None else 0 if args.txt else 15
        phase='sample'
        if args.txt:
            probe=TxtMarkProbe(bookmark=True);source=probe.prepare(saved,credentials,offset)
        else:
            sample,_,_=ChapterProbe().inspect(credentials,offset)
            probe=NativeBookmarkProbe();probe.source.web.requested_book=sample['book_id']
            phase='selection';probe.prepare(saved,credentials)
            phase='source';source=bind_native_source(probe.source,credentials)
        saved=prepare_web_handoff(session,saved,probe.source)
        origin=None
        if cross_runner:
            phase='cross_preflight';origin=prepare_origin(credentials,source);report['cross_preflight_verified']=True
        phase='dry_run';execute(probe,credentials,store,args.lua_command,source=source,armed=False,report=report,bookmark=True,
            on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
        if args.apply:
            phase='recheck';saved=prepare_web_handoff(session,saved,probe.source)
            if args.txt:
                probe.recheck_source(credentials);fresh=source
            else:fresh=bind_native_source(probe.source,credentials)
            if any(source[key]!=fresh[key] for key in ('book_id','uid','book_version','source_sha256')):
                raise ValueError('direct_bookmark_trial/source')
            if cross_runner and prepare_origin(credentials,fresh)!=origin:raise ValueError('direct_bookmark_trial/source')
            probe.source.baseline(credentials,'direct_bookmark_after_preview')
            cross=(lambda target:verify_cross(probe,credentials,fresh,origin,target,cross_runner)['result']=='PASS') if cross_runner else None
            phase='apply';execute(probe,credentials,store,args.lua_command,source=fresh,armed=True,report=report,bookmark=True,
                on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web),on_created=cross)
        report['authentication_posts']=0
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase,no_automatic_replay=True,authentication_posts=0)
        if phase!='apply':report['account_data_posts']=0
        if 'HTTP 401' in str(error) or str(error)=='chapter/http_401':report['reason']='auth_expired'
        elif 'HTTP 429' in str(error) or str(error)=='chapter/http_429':report['reason']='rate_limited'
        elif str(error) in {'direct_bookmark_trial/other_pending','direct_bookmark_trial/source','native_bookmark/existing',
                'direct_selection_preflight/chapter','direct_selection_preflight/source',
                'direct_txt_mark/format','direct_txt_mark/chapter','direct_txt_mark/existing',
                'direct_txt_mark/baseline_changed','direct_txt_mark/source_changed','bookmark_trial/txt_preview',
                'direct_roundtrip/changed','direct_roundtrip/catalog','direct_roundtrip/source'}:report['reason']=str(error)
        if type(error).__name__ in {'ValueError','PreflightError','ProbeError','StoreError','KeyError','TypeError'}:report['error_type']=type(error).__name__
        try:
            state,_=store.read();report.update(intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0)
        except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            if not args.txt:probe.source.web.shards.clear()
            probe.source.web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
