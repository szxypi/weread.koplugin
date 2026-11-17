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
    def __init__(self,port,cb=False):
        super().__init__(port)
        self.cb_reading=cb
        self.search_book='CB_SyntheticResume' if cb else '900001'

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
            first=synthetic_search_source(1).index('amberneedle')
            if query['chapterUid']==['1'] and query['posBegin']==['0'] and query['posEnd']==['0']:
                uid,more=1,1
            elif query['chapterUid']==['1'] and query['posBegin']==[str(first)] and query['posEnd']==[str(first+11)]:
                uid,more=2,0
            else:raise ValueError('invalid synthetic search cursor')
            start=synthetic_search_source(uid).index('amberneedle')
            return 200,dict(scrollDownHasMore=more,results=[dict(chapterUid=uid,posBegin=start,posEnd=start+11,
                text='synthetic context amberneedle',matchWords=[dict(posBegin=start,posEnd=start+11,word='amberneedle')])])
        return super().route(method,target,data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--probe", choices=("precision", "source-dom", "source-state", "navigation", "cloud-source", "quick-search", "book-search"), default="precision",
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
    args = parser.parse_args()
    if min(args.width, args.height, args.dpi) <= 0:
        parser.error("screen dimensions and DPI must be positive")
    if args.source_format != 'web_xhtml' and args.probe != 'source-state':
        parser.error('--source-format web_txt requires --probe source-state')
    if args.search_scope != 'full' and args.probe != 'quick-search':
        parser.error('--search-scope chapter requires --probe quick-search')
    if (args.search_missing or args.search_catalog_missing or args.search_renewal or args.search_cb) and args.probe!='book-search':
        parser.error('search fixture options require --probe book-search')
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    server = SearchMockServer(0,args.search_cb) if args.probe=='book-search' else MockServer(0)
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
                                        EMULATE_READER="1", EMULATE_READER_W=str(args.width),
                                        EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                                        EMULATE_BW_SCREEN="1", EMULATE_BB_TYPE="BB8")
        log = root / "evidence/runtime.log"
        try:
            with log.open("w") as out:
                probe = {"precision": "position_precision_smoke.lua", "source-dom": "source_dom_smoke.lua",
                         "source-state": "source_position_smoke.lua", "navigation": "progress_navigation_smoke.lua",
                         "cloud-source": "cloud_source_smoke.lua", "quick-search": "quick_search_smoke.lua",
                         "book-search": "book_search_ui_smoke.lua"}[args.probe]
                result = subprocess.run(["./luajit", str(REPO / "spec/koreader" / probe)],
                                        cwd=runtime, env=environment, stdout=out, stderr=subprocess.STDOUT, timeout=120)
            if result.returncode == 0 and args.probe == 'quick-search':
                server.shutdown();thread.join()
                with (root / 'evidence/reopen.log').open('w') as out:
                    reopened=subprocess.run(['./luajit',str(REPO/'spec/koreader'/probe)],cwd=runtime,
                        env=environment | {'WEREAD_TEST_QUICK_REOPEN':'1'},stdout=out,stderr=subprocess.STDOUT,timeout=120)
                assert reopened.returncode==0, 'offline search reopen failed; inspect isolated runtime log'
        finally:
            if thread.is_alive():server.shutdown();thread.join()
        if result.returncode == 0:
            raw=log.read_bytes()
            assert b'[WeRead] forceRePaint failed:' not in raw, 'native repaint failed; inspect the isolated runtime log'
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
                marker=b'\nWEREAD_BOOK_SEARCH_UI='
                assert raw.count(marker)==1, 'missing online book search result'
                value=json.loads(raw.split(marker,1)[1].splitlines()[0])
                expected=dict(result='PASS',pages=2,results=2,verified_navigation=True,network_worker=True,
                              downloaded=args.search_missing,catalog_downloaded=args.search_catalog_missing)
                if args.search_renewal:expected['renewal_scenarios']=True
                if args.search_cb:expected['imported_search']=True
                assert value==expected, 'online search result mismatch'
                assert server.request_totals[('/web/book/search_v2','')]==(7 if args.search_renewal else 2), 'unexpected search request count'
                assert server.request_totals[('/web/login/renewal','')]==(2 if args.search_renewal else 0), 'unexpected renewal count'
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
