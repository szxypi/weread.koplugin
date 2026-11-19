#!/usr/bin/env python3
"""Check local fractional or source/DOM positions in packaged, isolated KOReader."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
from urllib.parse import parse_qs, urlsplit

from mock_weread import MockServer, prepare, chapter_html

REPO = Path(__file__).resolve().parent.parent


def synthetic_search_source(uid):
    return '<html><body><p>chapter '+str(uid)+' '+('ordinary synthetic text '*80)+'amberneedle</p></body></html>'


class SearchMockServer(MockServer):
    def __init__(self,port,cb=False,current_fallback=False,empty=False,large_uid=False):
        super().__init__(port)
        self.cb_reading=cb
        self.current_fallback=current_fallback
        self.empty=empty
        self.search_book='CB_SyntheticResume' if cb else '900001'
        self.second_uid='9007199254740993' if large_uid else 2

    def chapter_source(self,uid,revision=None):
        return synthetic_search_source(uid)

    def route(self,method,target,data):
        url=urlsplit(target)
        if method=='GET' and url.path=='/web/book/search_v2':
            # Let the shared mock apply its configured delay/status before the
            # search-specific synthetic response is generated.
            try:return super().route(method,target,data)
            except LookupError:pass
            query=parse_qs(url.query)
            expected={'bookId','chapterUid','keyword','posBegin','posEnd','mode','count'}
            if (set(query)!=expected or query['bookId']!=[self.search_book] or query['keyword']!=['amberneedle']
                    or query['mode']!=['scrollDown'] or query['count']!=['50']):
                raise ValueError('invalid synthetic search query')
            if self.empty:
                return 200,dict(scrollDownHasMore=0,results=[])
            if self.current_fallback:
                if query['posBegin']!=['0'] or query['posEnd']!=['0']:raise ValueError('invalid fallback cursor')
                if query['chapterUid']==['1']:return 200,dict(scrollDownHasMore=0,results=[])
                if query['chapterUid']==['2']:
                    start=synthetic_search_source(2).index('amberneedle')
                    return 200,dict(scrollDownHasMore=0,results=[dict(chapterUid=2,posBegin=start,posEnd=start+11,
                        text='synthetic context amberneedle',matchWords=[dict(posBegin=start,posEnd=start+11,word='amberneedle')])])
                raise ValueError('invalid fallback chapter')
            first=synthetic_search_source(1).index('amberneedle')
            if query['chapterUid']==['1'] and query['posBegin']==['0'] and query['posEnd']==['0']:
                uid,more=1,1
            elif query['chapterUid']==['1'] and query['posBegin']==[str(first)] and query['posEnd']==[str(first+11)]:
                uid,more=self.second_uid,0
            else:raise ValueError('invalid synthetic search cursor')
            start=synthetic_search_source(uid).index('amberneedle')
            return 200,dict(scrollDownHasMore=more,results=[dict(chapterUid=uid,posBegin=start,posEnd=start+11,
                text='synthetic context amberneedle',matchWords=[dict(posBegin=start,posEnd=start+11,word='amberneedle')])])
        return super().route(method,target,data)


class TimeMockServer(MockServer):
    def __init__(self,port):
        super().__init__(port);self.time_reports=0

    def route(self,method,target,data):
        if method=='POST' and urlsplit(target).path=='/web/book/read' and data.get('rt',0)!=0:
            if type(data['rt']) is not int or data['rt']!=10:raise ValueError('invalid synthetic reading duration')
            self.time_reports+=1
        return super().route(method,target,data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--probe", choices=("precision", "source-dom", "source-state", "navigation", "cloud-source", "cb-cloud-view", "cb-sync", "quick-search", "book-search", "cached-search", "home-local-recent"), default="precision",
                        help="fractional navigation (default), source/DOM mapping, live reader-state capture, or chapter handoff")
    parser.add_argument("--width", type=int, default=600)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--dpi", type=int, default=167)
    parser.add_argument('--source-format', choices=('web_xhtml','web_txt'), default='web_xhtml')
    parser.add_argument('--search-scope', choices=('full','chapter'), default='full')
    parser.add_argument('--search-missing', action='store_true')
    parser.add_argument('--search-catalog-missing', action='store_true')
    parser.add_argument('--search-renewal', action='store_true')
    parser.add_argument('--search-cb', action='store_true')
    parser.add_argument('--search-large-uid', action='store_true')
    parser.add_argument('--search-current-fallback', action='store_true')
    parser.add_argument('--search-offline-fallback', action='store_true')
    parser.add_argument('--search-no-login-fallback', action='store_true')
    parser.add_argument('--search-empty-local', action='store_true')
    parser.add_argument('--search-local-download', action='store_true')
    parser.add_argument('--search-local-interrupt', action='store_true')
    parser.add_argument('--search-local-restart', action='store_true')
    parser.add_argument('--cached-signed-out', action='store_true')
    parser.add_argument('--cached-no-catalog', action='store_true')
    parser.add_argument('--cached-full', action='store_true')
    parser.add_argument('--cached-incomplete', action='store_true')
    parser.add_argument('--cached-dual', action='store_true')
    parser.add_argument('--cached-ignore-case', action='store_true')
    parser.add_argument('--cached-unicode-case', action='store_true')
    parser.add_argument('--cached-txt-source', action='store_true')
    parser.add_argument('--cached-canonical-case', choices=('source','query'))
    parser.add_argument('--cached-restore-catalog', action='store_true')
    parser.add_argument('--cached-limit', action='store_true')
    parser.add_argument('--cached-large-uid', action='store_true')
    parser.add_argument('--cb-cloud-single', action='store_true')
    parser.add_argument('--cb-sync-noack', action='store_true')
    parser.add_argument('--cb-sync-cloud', action='store_true')
    parser.add_argument('--cb-sync-timer', action='store_true')
    parser.add_argument('--cb-sync-timer-unknown', action='store_true')
    parser.add_argument('--cb-sync-close', choices=('confirmed','changed','unknown'), default='')
    parser.add_argument('--cb-sync-time', choices=('confirmed','changed','unknown'), default='')
    parser.add_argument('--cb-cloud-gap', action='store_true')
    args = parser.parse_args()
    if args.cached_canonical_case and not args.cached_unicode_case:parser.error('--cached-canonical-case requires --cached-unicode-case')
    if args.cached_txt_source and not args.cached_unicode_case:parser.error('--cached-txt-source requires --cached-unicode-case')
    if args.cached_unicode_case:args.cached_ignore_case=True
    if min(args.width, args.height, args.dpi) <= 0:
        parser.error("screen dimensions and DPI must be positive")
    if args.source_format != 'web_xhtml' and args.probe != 'source-state':
        parser.error('--source-format web_txt requires --probe source-state')
    if args.search_scope != 'full' and args.probe != 'quick-search':
        parser.error('--search-scope chapter requires --probe quick-search')
    if (args.search_missing or args.search_catalog_missing or args.search_renewal or args.search_current_fallback
            or args.search_offline_fallback or args.search_no_login_fallback or args.search_empty_local) and args.probe!='book-search' or args.search_cb and args.probe not in ('book-search','cached-search'):
        parser.error('search fixture options require --probe book-search')
    if args.search_local_download and (args.probe!='book-search' or not args.search_cb or not args.search_missing
                                       or args.search_renewal or args.search_current_fallback or args.search_catalog_missing):
        parser.error('local download fixture requires imported book search with a missing chapter')
    if args.search_local_interrupt and not args.search_local_download:
        parser.error('local interruption fixture requires local download')
    if args.search_local_restart and not args.search_local_interrupt:
        parser.error('local restart fixture requires local interruption')
    if (args.cached_signed_out or args.cached_no_catalog or args.cached_full or args.cached_incomplete or args.cached_dual
            or args.cached_ignore_case or args.cached_restore_catalog or args.cached_limit or args.cached_large_uid) and args.probe!='cached-search':
        parser.error('cached search options require --probe cached-search')
    if args.cached_restore_catalog and (not args.cached_no_catalog or args.cached_signed_out or args.cached_full or args.search_cb):
        parser.error('catalog restore fixture requires signed-in ordinary cached search without a catalog')
    if args.cached_limit and (args.cached_no_catalog or args.cached_signed_out or args.cached_ignore_case):
        parser.error('limited search fixture requires a signed-in cached book and catalog')
    if args.cached_full and not args.cached_no_catalog:
        parser.error('--cached-full requires --cached-no-catalog')
    if args.cached_incomplete and not args.cached_full:
        parser.error('--cached-incomplete requires --cached-full')
    if args.cached_dual and not args.cached_full:
        parser.error('--cached-dual requires --cached-full')
    if (args.cb_sync_noack or args.cb_sync_cloud or args.cb_sync_timer or args.cb_sync_timer_unknown or args.cb_sync_close or args.cb_sync_time) and args.probe!='cb-sync':parser.error('CB sync option requires cb-sync')
    if sum(bool(x) for x in (args.cb_sync_noack,args.cb_sync_cloud,args.cb_sync_timer,args.cb_sync_timer_unknown,args.cb_sync_close,args.cb_sync_time))>1:parser.error('select one CB sync outcome')
    if (args.cb_cloud_single or args.cb_cloud_gap) and args.probe not in ('cb-cloud-view','cb-sync'):
        parser.error('imported cloud options require --probe cb-cloud-view')
    if args.search_current_fallback and (not args.search_cb or args.search_missing or args.search_renewal):
        parser.error('current fallback requires a cached CB search fixture')
    if args.search_large_uid and (args.probe!='book-search' or not args.search_cb or args.search_missing
                                  or args.search_catalog_missing or args.search_renewal or args.search_current_fallback
                                  or args.search_local_download or args.search_offline_fallback or args.search_no_login_fallback):
        parser.error('large chapter search requires a complete imported-book fixture')
    if args.search_offline_fallback and (args.search_missing or args.search_catalog_missing or args.search_renewal
                                         or args.search_current_fallback or args.search_local_download or args.search_no_login_fallback):
        parser.error('offline fallback requires the complete cached search fixture')
    if args.search_no_login_fallback and (args.search_missing or args.search_catalog_missing or args.search_renewal
                                          or args.search_current_fallback or args.search_local_download):
        parser.error('signed-out fallback requires the complete cached search fixture')
    if args.search_empty_local and (args.search_cb or args.search_missing or args.search_catalog_missing or args.search_renewal
                                    or args.search_current_fallback or args.search_local_download
                                    or args.search_offline_fallback or args.search_no_login_fallback):
        parser.error('empty-result local search requires the ordinary complete cached fixture')
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    server = SearchMockServer(0,args.search_cb,args.search_current_fallback,args.search_empty_local,args.search_large_uid) if args.probe=='book-search' else TimeMockServer(0) if args.cb_sync_time else MockServer(0)
    if args.probe in ('cb-cloud-view','cb-sync'):
        from verify_source_coordinates import FilteredSource
        server.cb_reading=True
        needle=('窗外的风穿过树梢，带来远处山谷的回声。' if args.cb_cloud_gap else '')+'这是第6章的第16段。我们沿着小路慢慢前行'
        target_offset=FilteredSource(chapter_html(6)).locate(needle)[0]
        offset=target_offset-1 if args.cb_cloud_gap else target_offset
        server.progress['CB_SyntheticResume']=dict(chapterUid=6,chapterIdx=6,chapterOffset=offset,progress=83,summary='Synthetic cloud target')
    if args.probe == 'cloud-source':
        from verify_source_coordinates import FilteredSource
        offset=FilteredSource(chapter_html(6)).locate('这是第6章的第16段。我们沿着小路慢慢前行')[0]
        server.progress['900001']=dict(chapterUid=6,chapterIdx=6,chapterOffset=offset,progress=83,summary='Synthetic cloud target')
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        (root / "xdg").mkdir(mode=0o700)
        server.log_path = root / "evidence/requests.jsonl"
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = os.environ | dict(KO_HOME=str(root / "profile"), WEREAD_EVIDENCE=str(root / "evidence"),
                                        XDG_RUNTIME_DIR=str(root / "xdg"),
                                        WEREAD_TEST_SOURCE_FORMAT=args.source_format,
                                        WEREAD_TEST_SEARCH_SCOPE=args.search_scope,
                                        WEREAD_TEST_SEARCH_MISSING='1' if args.search_missing else '0',
                                        WEREAD_TEST_SEARCH_CATALOG_MISSING='1' if args.search_catalog_missing else '0',
                                        WEREAD_TEST_SEARCH_RENEWAL='1' if args.search_renewal else '0',
                                        WEREAD_TEST_SEARCH_CB='1' if args.search_cb else '0',
                                        WEREAD_TEST_SEARCH_LARGE_UID='1' if args.search_large_uid else '0',
                                        WEREAD_TEST_SEARCH_CURRENT_FALLBACK='1' if args.search_current_fallback else '0',
                                        WEREAD_TEST_SEARCH_OFFLINE_FALLBACK='1' if args.search_offline_fallback else '0',
                                        WEREAD_TEST_SEARCH_NO_LOGIN_FALLBACK='1' if args.search_no_login_fallback else '0',
                                        WEREAD_TEST_SEARCH_EMPTY_LOCAL='1' if args.search_empty_local else '0',
                                        WEREAD_TEST_SEARCH_LOCAL_DOWNLOAD='1' if args.search_local_download else '0',
                                        WEREAD_TEST_SEARCH_LOCAL_INTERRUPT='1' if args.search_local_interrupt else '0',
                                        WEREAD_TEST_SEARCH_LOCAL_RESTART='1' if args.search_local_restart else '0',
                                        WEREAD_TEST_CACHED_SIGNED_OUT='1' if args.cached_signed_out else '0',
                                        WEREAD_TEST_CACHED_NO_CATALOG='1' if args.cached_no_catalog else '0',
                                        WEREAD_TEST_CACHED_FULL='1' if args.cached_full else '0',
                                        WEREAD_TEST_CACHED_INCOMPLETE='1' if args.cached_incomplete else '0',
                                        WEREAD_TEST_CACHED_DUAL='1' if args.cached_dual else '0',
                                        WEREAD_TEST_CACHED_IGNORE_CASE='1' if args.cached_ignore_case else '0',
                                        WEREAD_TEST_CACHED_UNICODE_CASE='1' if args.cached_unicode_case else '0',
                                        WEREAD_TEST_CACHED_TXT_SOURCE='1' if args.cached_txt_source else '0',
                                        WEREAD_TEST_CACHED_CANONICAL_CASE=args.cached_canonical_case or '',
                                        WEREAD_TEST_CACHED_RESTORE_CATALOG='1' if args.cached_restore_catalog else '0',
                                        WEREAD_TEST_CACHED_LIMIT='1' if args.cached_limit else '0',
                                        WEREAD_TEST_CACHED_LARGE_UID='1' if args.cached_large_uid else '0',
                                        WEREAD_TEST_CB_CLOUD_SINGLE='1' if args.cb_cloud_single else '0',
                                        WEREAD_TEST_CB_SYNC_NOACK='1' if args.cb_sync_noack else '0',
                                        WEREAD_TEST_CB_SYNC_CLOUD='1' if args.cb_sync_cloud else '0',
                                        WEREAD_TEST_CB_SYNC_TIMER='1' if args.cb_sync_timer or args.cb_sync_timer_unknown else '0',
                                        WEREAD_TEST_CB_TIMER_UNKNOWN='1' if args.cb_sync_timer_unknown else '0',
                                        WEREAD_TEST_CB_SYNC_CLOSE=args.cb_sync_close,
                                        WEREAD_TEST_CB_SYNC_TIME=args.cb_sync_time,
                                        WEREAD_TEST_CB_CLOUD_TARGET=str(target_offset) if args.probe in ('cb-cloud-view','cb-sync') else '',
                                        WEREAD_TEST_CB_CLOUD_GAP='1' if args.cb_cloud_gap else '0',
                                        EMULATE_READER="1", EMULATE_READER_W=str(args.width),
                                        EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                                        EMULATE_BW_SCREEN="1", EMULATE_BB_TYPE="BB8")
        log = root / "evidence/runtime.log"
        try:
            with log.open("w") as out:
                probe = {"precision": "position_precision_smoke.lua", "source-dom": "source_dom_smoke.lua",
                         "source-state": "source_position_smoke.lua", "navigation": "progress_navigation_smoke.lua",
                         "cloud-source": "cloud_source_smoke.lua", "quick-search": "quick_search_smoke.lua",
                         "cb-cloud-view": "cb_cloud_view_smoke.lua", "cb-sync": "cb_sync_ui_smoke.lua",
                         "book-search": "book_search_ui_smoke.lua", "cached-search": "cached_search_ui_smoke.lua",
                         "home-local-recent": "home_local_recent_smoke.lua"}[args.probe]
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / probe)],
                                        cwd=runtime, env=environment, stdout=out, stderr=subprocess.STDOUT, timeout=120)
            if result.returncode == 0 and args.search_local_restart:
                initial=log.read_bytes();marker=b'\nWEREAD_SEARCH_DOWNLOAD_PAUSED='
                assert initial.count(marker)==1 and json.loads(initial.split(marker,1)[1].splitlines()[0])=={'result':'PASS','checkpoint':True}
                with (root/'evidence/reopen.log').open('w') as out:
                    result=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_SEARCH_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
            if result.returncode == 0 and args.probe == 'quick-search':
                server.shutdown();thread.join()
                with (root / 'evidence/reopen.log').open('w') as out:
                    reopened=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_QUICK_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert reopened.returncode==0, 'offline search reopen failed; inspect isolated runtime log'
            if result.returncode == 0 and args.probe == 'cb-cloud-view':
                server.shutdown();thread.join()
                with (root / 'evidence/reopen.log').open('w') as out:
                    reopened=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_CB_CLOUD_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert reopened.returncode==0, 'offline imported cloud view reopen failed; inspect isolated runtime log'
            if result.returncode == 0 and args.probe == 'cb-sync' and (args.cb_sync_noack or args.cb_sync_timer_unknown or args.cb_sync_close=='unknown' or args.cb_sync_time=='unknown'):
                server.shutdown();thread.join()
                with (root / 'evidence/reopen.log').open('w') as out:
                    reopened=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_CB_SYNC_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert reopened.returncode==0, 'offline imported sync reopen failed; inspect isolated runtime log'
            if result.returncode == 0 and args.probe == 'home-local-recent':
                server.shutdown();thread.join()
                with (root / 'evidence/reopen.log').open('w') as out:
                    reopened=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_HOME_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert reopened.returncode==0, 'offline home reopen failed; inspect isolated runtime log'
                phases=[('WEREAD_TEST_HOME_ACCOUNT_SWITCH','account-switch.log'),
                        ('WEREAD_TEST_HOME_ACCOUNT_REOPEN','account-reopen.log'),
                        ('WEREAD_TEST_HOME_UNKNOWN_LEGACY','unknown-legacy.log'),
                        ('WEREAD_TEST_HOME_CLAIM_REOPEN','claim-reopen.log')]
                if environment.get('WEREAD_TEST_CLAIM_SCROLL')=='1':
                    phases.append(('WEREAD_TEST_HOME_SCROLL_REOPEN','scroll-reopen.log'))
                for flag,filename in phases:
                    with (root/'evidence'/filename).open('w') as out:
                        checked=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                            env=environment | {flag:'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                    assert checked.returncode==0, 'offline account ownership check failed; inspect isolated runtime log'
            if result.returncode == 0 and args.probe == 'cached-search' and args.cached_no_catalog and not args.cached_restore_catalog:
                server.shutdown();thread.join()
                with (root / 'evidence/reopen.log').open('w') as out:
                    reopened=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_CACHED_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert reopened.returncode==0, 'offline downloaded chapter reopen failed; inspect isolated runtime log'
                with (root / 'evidence/stale.log').open('w') as out:
                    stale=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_CACHED_STALE':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert stale.returncode==0, 'offline changed chapter fallback failed; inspect isolated runtime log'
        finally:
            if thread.is_alive():server.shutdown();thread.join()
        if result.returncode == 0:
            raw=log.read_bytes()
            assert b'[WeRead] forceRePaint failed:' not in raw, 'native repaint failed; inspect the isolated runtime log'
            if args.probe == 'home-local-recent':
                marker=b'\nWEREAD_HOME_LOCAL_RECENT='
                for reopened,content in ((False,raw),(True,(root/'evidence/reopen.log').read_bytes())):
                    assert content.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in content
                    value=json.loads(content.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',reopen=reopened,home_selection=True,account_isolation=True,
                                       shelf_unchanged=True,saved_page=True,requests=0), 'native home result mismatch'
                marker=b'\nWEREAD_HOME_ACCOUNT_SWITCH='
                for reopened,filename in ((False,'account-switch.log'),(True,'account-reopen.log')):
                    content=(root/'evidence'/filename).read_bytes()
                    assert content.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in content
                    value=json.loads(content.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',reopen=reopened,independent_pending=True,
                                       independent_position=True,independent_dispatch=True,native_pages=True,
                                       native_note_preserved=True,repagination=True,requests=0), 'account ownership mismatch'
                content=(root/'evidence/unknown-legacy.log').read_bytes();marker=b'\nWEREAD_UNKNOWN_NATIVE_LEGACY='
                assert content.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in content
                value=json.loads(content.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',original_page=True,not_claimed=True,explicit_claim=True,
                                   pending_preserved=True,native_note_preserved=True,requests=0), 'unknown legacy mismatch'
                content=(root/'evidence/claim-reopen.log').read_bytes();marker=b'\nWEREAD_NATIVE_CLAIM_REOPEN='
                assert content.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in content
                value=json.loads(content.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',fresh_process=True,chosen_page=True,previous_page_preserved=True,
                                   native_note_preserved=True,requests=0), 'native claim reopen mismatch'
                if environment.get('WEREAD_TEST_CLAIM_SCROLL')=='1':
                    content=(root/'evidence/scroll-reopen.log').read_bytes();marker=b'\nWEREAD_NATIVE_SCROLL_REOPEN='
                    assert content.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in content
                    value=json.loads(content.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',fresh_process=True,visible_anchor=True,native_note_preserved=True,
                                       requests=0), 'native scroll reopen mismatch'
                request_log=root/'evidence/requests.jsonl'
                assert not request_log.exists() or not request_log.read_bytes(), 'local home made a mock request'
            if args.probe == 'cb-sync' and args.cb_sync_cloud:
                marker=b'\nWEREAD_CB_SYNC_CLOUD='
                assert raw.count(marker)==1, 'missing imported cloud choice result'
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',choice=True,native_navigation=True,pending_preserved=True,
                    automatic_disabled=True,single=args.cb_cloud_single)
                assert server.request_totals[('/web/book/read','')]==0, 'cloud choice wrote imported progress'
            if args.probe == 'cb-sync' and not args.cb_sync_cloud:
                marker=b'\nWEREAD_CB_MANUAL_SYNC='
                assert raw.count(marker)==1, 'missing imported manual sync result'
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',choice=True,changed_remote_stopped=True,explicit_upload=True,
                    native_point=True,pending_cleared=not args.cb_sync_noack,journal_cleared=not args.cb_sync_noack,
                    automatic_disabled=not (args.cb_sync_timer or args.cb_sync_timer_unknown),single=args.cb_cloud_single,uncertain=args.cb_sync_noack,
                    timer_verified=args.cb_sync_timer or args.cb_sync_timer_unknown,timer_unknown=args.cb_sync_timer_unknown,
                    close_outcome=args.cb_sync_close,time_outcome=args.cb_sync_time)
                expected_writes=4 if args.cb_sync_timer_unknown else 3 if args.cb_sync_timer or args.cb_sync_close in ('confirmed','unknown') or args.cb_sync_time in ('confirmed','unknown') else 2
                assert server.request_totals[('/web/book/read','')]==expected_writes, 'imported sync sent an unexpected number of writes'
                if args.cb_sync_time:
                    assert server.time_reports==(0 if args.cb_sync_time=='changed' else 1), 'CB time sent an unexpected duration or repeated a report'
                if args.cb_sync_noack or args.cb_sync_timer_unknown or args.cb_sync_close=='unknown' or args.cb_sync_time=='unknown':
                    reopened_raw=(root/'evidence/reopen.log').read_bytes();marker=b'\nWEREAD_CB_SYNC_REOPEN='
                    assert reopened_raw.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in reopened_raw
                    reopened=json.loads(reopened_raw.split(marker,1)[1].splitlines()[0])
                    assert reopened==dict(result='PASS',fresh_process=True,journal_preserved=True,pending_preserved=True,
                                          automatic_disabled=True,requests=0), 'uncertain imported sync recovery mismatch'
            if args.probe == 'cb-cloud-view':
                marker=b'\nWEREAD_CB_CLOUD_VIEW='
                assert raw.count(marker)==1, 'missing imported cloud view result'
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',native_navigation=True,pending_preserved=True,upload_disabled=True,
                                   local_reopen=True,download_confirmed=args.cb_cloud_single,approximate=args.cb_cloud_gap,source_preview=True), 'imported cloud view mismatch'
                assert server.request_totals[('/web/book/read','')]==0, 'read-only view sent reading progress'
                reopened_raw=(root/'evidence/reopen.log').read_bytes();marker=b'\nWEREAD_CB_CLOUD_REOPEN='
                assert reopened_raw.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in reopened_raw
                value=json.loads(reopened_raw.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',fresh_process=True,offline=True,pending_preserved=True,
                                   upload_disabled=True,requests=0), 'offline imported cloud reopen mismatch'
            if args.probe == 'cached-search' and args.cached_restore_catalog:
                marker=b'\nWEREAD_CACHED_CATALOG_RESTORE='
                assert raw.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in raw
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',catalog_restored=True,rescan=True,cancel_safe=True,
                                   missing=4,pending_preserved=True), 'cached catalog restoration mismatch'
                assert server.request_totals[('/web/book/chapterInfos','')]==1, 'unexpected catalog request count'
                assert all(event['method']!='POST' or event['path']=='/web/book/chapterInfos' for event in server.events), 'unexpected modifying request'
                print('PASS: '+str(log));return
            if args.probe == 'cached-search':
                if args.cached_limit:
                    marker=b'\nWEREAD_CACHED_SEARCH_LIMIT='
                    assert raw.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in raw
                    value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',warning_first=True,download_available=True,
                                       cancel_preserved=True,network_requests=0), 'limited cached search mismatch'
                    assert not server.events, 'limited cached search made a mock request'
                    print('PASS: '+str(log));return
                marker=b'\nWEREAD_CACHED_SEARCH_UI='
                assert raw.count(marker)==1, 'missing cached search result'
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                assert value==dict(result='PASS',results=1 if args.cached_incomplete else 2,unavailable=0 if args.cached_no_catalog else 1,
                                   navigation=True,cancel_resume=True,signed_out=args.cached_signed_out,
                                   imported=args.search_cb,no_catalog=args.cached_no_catalog,full=args.cached_full,
                                   incomplete=args.cached_incomplete,dual=args.cached_dual,
                                   ignore_ascii_case=args.cached_ignore_case), 'cached search result mismatch'
                request_log=root/'evidence/requests.jsonl'
                assert not request_log.exists() or not request_log.read_bytes(), 'cached search made a mock request'
                if args.cached_no_catalog:
                    reopened=(root/'evidence/reopen.log').read_bytes()
                    marker=b'\nWEREAD_CACHED_SEARCH_REOPEN='
                    assert reopened.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in reopened
                    value=json.loads(reopened.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',file_position=True,pending_preserved=True), 'offline reopen result mismatch'
                    stale=(root/'evidence/stale.log').read_bytes();marker=b'\nWEREAD_CACHED_SEARCH_STALE='
                    assert stale.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in stale
                    value=json.loads(stale.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',cancel_preserved=True,explicit_fallback=True), 'changed chapter result mismatch'
            if args.probe == 'quick-search':
                marker=b'\nWEREAD_QUICK_SEARCH_RESULT='
                for reopened,content in ((False,raw),(True,(root/'evidence/reopen.log').read_bytes())):
                    assert content.count(marker)==1 and b'[WeRead] forceRePaint failed:' not in content, 'missing native search result'
                    value=json.loads(content.split(marker,1)[1].splitlines()[0])
                    assert value==dict(result='PASS',scope=args.search_scope,reopen=reopened,quick_menu=True,native_search=True,
                                       target_page_after_start=True,requests=0), 'native search result mismatch'
                request_log=root/'evidence/requests.jsonl'
                assert not request_log.exists() or not request_log.read_bytes(), 'native search made a mock request'
            if args.probe == 'book-search':
                if args.search_local_restart:raw=(root/'evidence/reopen.log').read_bytes()
                marker=b'\nWEREAD_BOOK_SEARCH_UI='
                assert raw.count(marker)==1, 'missing online book search result'
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                expected=dict(result='PASS',pages=2,results=1 if args.search_current_fallback else 2,verified_navigation=True,network_worker=True,
                              downloaded=args.search_missing,catalog_downloaded=args.search_catalog_missing)
                if args.search_local_download:
                    expected=dict(result='PASS',local_download_search=True,unavailable_before=1,results=2,
                                  cancel_safe=True,current_file_preserved=True,navigation_verified=True)
                    if args.search_local_interrupt:expected['interrupted_resume_verified']=True
                if args.search_renewal:expected['renewal_scenarios']=True
                if args.search_cb and not args.search_local_download:expected['imported_search']=True
                if args.search_current_fallback:expected['current_fallback']=True
                if args.search_offline_fallback:
                    expected=dict(result='PASS',offline_entry=True,disconnect_fallback=True,
                                  cloud_results_preserved=True,offline_results=2,offline_network_requests=0)
                if args.search_no_login_fallback:
                    expected=dict(result='PASS',signed_out_entry=True,offline_results=2,network_requests=0)
                if args.search_empty_local:
                    expected=dict(result='PASS',empty_online=True,local_results=2,local_network_requests=0)
                assert value==expected, 'online search result mismatch'
                search_requests=(2 if args.search_local_restart else 1) if args.search_local_download else 7 if args.search_renewal else 2
                if not args.search_missing and not args.search_renewal and not args.search_current_fallback:
                    search_requests+=1 # reopen the online results after the offline handoff
                if args.search_offline_fallback:search_requests=1
                if args.search_no_login_fallback:search_requests=0
                if args.search_empty_local:search_requests=1
                assert server.request_totals[('/web/book/search_v2','')]==search_requests, 'unexpected search request count'
                assert server.request_totals[('/web/login/renewal','')]==(2 if args.search_renewal else 0), 'unexpected renewal count'
                assert server.request_totals[('/web/book/read','')]==0, 'search navigation wrote reading progress'
                if args.search_local_interrupt:
                    from fetch_weread_epub import weread_e
                    first_reads=[event for event in server.events if event['path']=='/web/book/chapter/e_0'
                                 and event.get('encoded_chapter')==weread_e(1) and event['status']==200]
                    assert len(first_reads)==1, 'resuming download requested the completed chapter again'
                for event in server.events:
                    if event['method']=='POST':
                        assert (args.search_renewal and event['path'] in {'/__control','/web/login/renewal'}
                            or event['path']=='/web/book/chapterInfos'
                            or event['path'] in {'/web/book/chapter/e_0','/web/book/chapter/e_1',
                                                 '/web/book/chapter/e_2','/web/book/chapter/e_3'}), 'unexpected modifying request'
                if args.search_missing:
                    assert server.request_totals[('/web/book/chapter/e_0','')]>0, 'missing chapter was not downloaded'
                if args.search_catalog_missing:
                    assert server.request_totals[('/web/book/chapterInfos','')]>0, 'missing catalog was not loaded'
        print(("PASS" if result.returncode == 0 else "FAIL") + f": {log}")
        raise SystemExit(result.returncode)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
