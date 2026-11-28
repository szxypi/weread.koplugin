#!/usr/bin/env python3
"""Exercise the real-account full-search probe using only synthetic loopback."""
import argparse,json,os,subprocess,sys,threading
from pathlib import Path

from test_position_runtime import SearchMockServer
from mock_weread import CHAPTERS
from verify_cb_book_search import query_text


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--catalog',action='store_true')
    args=parser.parse_args(argv);server=SearchMockServer(0,True)
    def synthetic_source(uid,_revision=None):
        return '<html><body><p>合成章节'+str(uid)+' 内容开始。独特的河流山川与星光照亮旅程。尾声。</p></body></html>'
    server.chapter_source=synthetic_source
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        source=synthetic_source(2);keyword,offset=query_text(source,(16,12,8))
        if not keyword or not offset:raise ValueError('synthetic/query')
        rows=CHAPTERS if args.catalog else CHAPTERS[:2]
        payload=dict(owner='900000',cookies={'wr_vid':'900000','wr_skey':'synthetic-search-session'},
            book='CB_SyntheticResume',chapter='2',local_chapter='1',source=source,
            chapters=[dict(chapterUid=str(row['chapterUid']),chapterIdx=row['chapterIdx'],title='Synthetic chapter',wordCount=1000) for row in rows],
            keyword=keyword,expected_offset=offset[0],
            allowed=[dict(chapter='1',start=0,finish=0)],full_download_search=not args.catalog,cached_catalog_restore=args.catalog,
            synthetic_port=server.server_port)
        command=[sys.executable,str(Path(__file__).with_name('run_owner_book_search_ui.py')),
                 '--koreader',str(args.koreader),'--candidate',str(args.candidate)]
        child=subprocess.run(command,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                             timeout=240,env=dict(os.environ,SDL_VIDEODRIVER='dummy'))
        if child.returncode or len(child.stdout)>65536:raise ValueError('synthetic/full_search')
        result=json.loads(child.stdout);ui=result.get('ui',{})
        if (result.get('result')!='PASS' or result.get('profile_removed') is not True or ui.get('chapters')!=len(rows)
                or ui.get('denied_requests')!=0 or (ui.get('cached_catalog_restore') is not True if args.catalog
                    else ui.get('full_download_search') is not True or ui.get('checked')!=2)):
            raise ValueError('synthetic/full_search')
        allowed={'/web/book/chapterInfos','/web/book/chapter/e_0','/web/book/chapter/e_1',
                 '/web/book/chapter/e_2','/web/book/chapter/e_3'}
        if any(event['method']=='POST' and event['path'] not in allowed for event in server.events):
            raise ValueError('synthetic/write')
        print(json.dumps(dict(result='SYNTHETIC_CATALOG_RESTORE_VERIFIED' if args.catalog else 'SYNTHETIC_FULL_SEARCH_VERIFIED',
                              chapters=len(rows),real_account_posts=0)))
        return 0
    except Exception:
        print(json.dumps(dict(result='UNVERIFIED',real_account_posts=0)));return 1
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':raise SystemExit(main())
