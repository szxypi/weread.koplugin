#!/usr/bin/env python3
"""Exercise the private owner home runner using only a loopback service."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

import test_native_direct_position_runtime as fixture
from test_native_direct_position_runtime import BODY, Handler, REPO


class StoreHandler(Handler):
    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if getattr(self.server,'time_preflight',False):
            txt=getattr(self.server,'plain_text',False)
            value=None
            if getattr(self.server,'live_time',False) and target.hostname=='i.weread.qq.com' \
                    and target.path=='/book/batchUploadProgress' and self.command=='POST':
                request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                self.server.valid &= (len(request.get('books',[]))==1 and request['books'][0].get('bookId')=='42'
                    and request['books'][0].get('bookVersion')==(0 if txt else 1))
                if self.server.time_ack:
                    self.server.time_delta+=request['books'][0]['readingTime'];value={'succ':1}
                    if txt and not self.server.no_position:self.server.time_summary=request['books'][0]['summary']
                else:value={'succ':0}
            if target.hostname=='i.weread.qq.com' and target.path=='/book/getProgress' and self.command=='GET':
                value=dict(timestamp=int(time.time()),bookId='42',chapterUid=37,chapterIdx=1,chapterOffset=1,progress=50,
                    summary='Synthetic point',readingTime=100+getattr(self.server,'time_delta',0),recordReadingTime=0,ttsTime=0)
                if self.server.no_position:
                    value.update(chapterUid=0,chapterOffset=0,progress=0,
                        readingTime=getattr(self.server,'time_initial',0)+getattr(self.server,'time_delta',0))
                    value.pop('chapterIdx');value.pop('summary')
            elif target.hostname=='weread.qq.com' and target.path=='/web/book/getProgress' and self.command=='GET':
                value=dict(bookId='42',chapterUid=37,chapterIdx=1,chapterOffset=1,progress=50,summary='Synthetic point')
                if txt:
                    value.update(readingTime=100+getattr(self.server,'time_delta',0),recordReadingTime=0,ttsTime=0)
                if self.server.no_position:
                    value.update(chapterUid=0,chapterOffset=0,progress=0,
                        readingTime=getattr(self.server,'time_initial',0)+getattr(self.server,'time_delta',0),
                        recordReadingTime=0,ttsTime=0);value.pop('chapterIdx');value.pop('summary')
            elif target.hostname=='weread.qq.com' and target.path=='/web/book/chapterInfos' and self.command=='POST':
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                self.server.valid &= body==dict(bookIds=['42'])
                book=dict(bookId='42') if txt else dict(bookId='42',bookVersion=1)
                value=dict(data=[dict(bookId='42',book=book,
                    updated=[dict(chapterUid=37,chapterIdx=1),dict(chapterUid=38,chapterIdx=2)])])
            elif target.hostname=='i.weread.qq.com' and target.path=='/readdata/detail' and self.command=='GET':
                month=int(parse_qs(target.query)['baseTime'][0]);delta=getattr(self.server,'time_delta',0)
                day=(int(time.time())+28800)//86400*86400-28800
                value=dict(baseTime=month,readTimes={str(day):delta} if delta else {},totalReadTime=delta,readDays=int(delta>0))
                if delta and getattr(self.server,'time_add_zero',False):
                    value['readTimes'][str(month if month!=day else month+86400)]=0
            elif target.hostname=='i.weread.qq.com' and target.path=='/config' and self.command=='GET':
                value=dict(token='synthetic-config')
            elif target.hostname=='i.weread.qq.com' and target.path=='/feature' and self.command=='GET':
                value=dict(feature={})
            if txt and value is not None and 'summary' in value and getattr(self.server,'time_delta',0):
                summary=self.server.time_summary
                if summary:value['summary']=summary
                else:value.pop('summary')
            if value is not None:
                self.server.calls.append((self.command,target.hostname,target.path))
                self.server.leaked |= any(key.lower() in ('vid','accesstoken','cookie') for key in self.headers)
                raw=json.dumps(value).encode();self.send_response(200);self.send_header('Content-Length',str(len(raw)))
                self.end_headers();self.wfile.write(raw);return
        if self.command == 'GET' and target.hostname == 'i.weread.qq.com' and target.path in ('/store/search','/book/info'):
            self.server.leaked |= any(key.lower() in ('vid','accesstoken','cookie') for key in self.headers)
            self.server.calls.append((self.command,target.hostname,target.path))
            if target.path == '/store/search':
                self.server.valid &= parse_qs(target.query) == dict(keyword=['Synthetic'],scope=['10'],count=['20'],maxIdx=['0'])
                data = dict(books=[dict(bookId='42',title='Synthetic book',author='Fixture',searchIdx=1)],hasMore=0)
            else:
                self.server.valid &= parse_qs(target.query) == dict(bookId=['42'])
                txt=getattr(self.server,'plain_text',False)
                data = dict(bookId='42',title='Synthetic book',author='Fixture',format='txt' if txt else 'epub',version=0 if txt else 1)
            raw=json.dumps(data).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
            return
        return super().dispatch()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--store-only', action='store_true')
    parser.add_argument('--quick-only', action='store_true')
    parser.add_argument('--progress-only', action='store_true')
    parser.add_argument('--reminder-only', action='store_true')
    parser.add_argument('--time-only', action='store_true')
    parser.add_argument('--time-preflight-only', action='store_true')
    parser.add_argument('--no-position-only', action='store_true')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), StoreHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-home-test-', dir='/dev/shm') as directory:
            candidate = Path(directory)/'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           check=True, capture_output=True)
            cases=((600, 800, 167, False, False, False), (1264, 1680, 300, False, False, False),
                (600, 800, 167, True, False, False), (1264, 1680, 300, True, False, False),
                (600, 800, 167, True, True, False), (1264, 1680, 300, True, True, False),
                (600, 800, 167, True, True, True), (1264, 1680, 300, True, True, True))
            for width, height, dpi, full_ui, store_search, quick_search in cases:
                if args.store_only and not store_search:
                    continue
                if args.quick_only and not quick_search:
                    continue
                if args.progress_only and (not full_ui or store_search):
                    continue
                if args.reminder_only and (not full_ui or store_search):
                    continue
                if (args.time_only or args.time_preflight_only or args.no_position_only) and (not full_ui or store_search):
                    continue
                server.time_preflight=args.time_preflight_only or args.no_position_only
                server.no_position=args.no_position_only
                server.mode = 'preview' if server.time_preflight else 'selection_direct_overlay'
                server.calls, server.leaked, server.valid, server.review = [], False, True, None
                fixture.BODY = BODY.replace('<body>','<head><style>/* synthetic */ p{margin-left:7px}</style></head><body>') if store_search else BODY
                payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                    refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},
                    book_id='42', uid='37', book_version=1, source_sha256=hashlib.sha256(fixture.BODY.encode()).hexdigest(),
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                command = [sys.executable, str(REPO/'scripts/run_native_direct_home_owner.py'),
                    '--koreader', str(args.koreader), '--candidate', str(candidate), '--width', str(width),
                    '--height', str(height), '--dpi', str(dpi)]
                if full_ui:
                    command.append('--full-ui')
                if args.progress_only:
                    command.append('--progress-estimate')
                    payload['progress_estimate']=dict(order=1,count=2,before=0,words=500,total=1000)
                if args.reminder_only:
                    command.append('--offline-reminder')
                if args.time_only or args.time_preflight_only or args.no_position_only:
                    command.extend(('--offline-time','--offline-time-ui'))
                if args.time_preflight_only or args.no_position_only:
                    command.append('--offline-time-preflight')
                if args.no_position_only:
                    command.append('--no-position-guidance')
                if store_search:
                    command.append('--store-search')
                    payload['store_search_keyword']='Synthetic'
                    payload['inline_style']='/* synthetic */ p{margin-left:7px}'
                if quick_search:
                    command.append('--quick-search')
                child = subprocess.run(command, input=json.dumps(payload).encode(),
                    capture_output=True, timeout=900 if args.reminder_only else 480)
                marker = b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
                assert child.stdout.count(marker) == 1
                result = json.loads(child.stdout.split(marker, 1)[1].splitlines()[0])
                assert child.returncode == 0 and result['result'] == 'PASS', result
                assert all(result[key] is True for key in ('profile_removed','source_matches','home_record',
                    'offline_home_resume','page_restored','network_blocked','credential_file_audit','installed_bytes_match'))
                assert result.get('full_ui', False) is full_ui
                assert result.get('store_search', False) is store_search
                assert result.get('inline_style_verified', False) is store_search
                assert result.get('quick_search', False) is quick_search
                assert result.get('progress_estimate_verified',False) is args.progress_only
                assert result.get('offline_reminder_verified',False) is args.reminder_only
                assert result.get('offline_time_verified',False) is (args.time_only or args.time_preflight_only or args.no_position_only)
                assert result.get('offline_time_ui_verified',False) is (args.time_only or args.time_preflight_only or args.no_position_only)
                assert result.get('offline_time_preflight_verified',False) is (args.time_preflight_only or args.no_position_only)
                assert result.get('no_position_guidance_verified',False) is args.no_position_only
                assert server.valid and not server.leaked
                allowed=('/store/search','/book/info','/book/chapterInfos','/book/chapterdownload')
                if args.time_preflight_only or args.no_position_only:
                    allowed+=('/book/getProgress','/shelf/sync','/readdata/detail','/config','/feature','/api/userInfo',
                              '/web/book/chapterInfos','/web/book/getProgress','/web/book/chapter/e_0','/web/book/chapter/e_1',
                              '/web/book/chapter/e_3','/web/reader/42','/web/reader/42k37')
                unexpected={path for _,_,path in server.calls if path not in allowed
                    and not ((args.time_preflight_only or args.no_position_only) and path.startswith('/web/reader/'))}
                assert not unexpected, sorted(unexpected)
                assert any(path=='/store/search' for _,_,path in server.calls) is store_search
                if quick_search:
                    assert sum(path=='/store/search' for _,_,path in server.calls)==2
        print('PASS: owner home runner against synthetic service at both screen sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
