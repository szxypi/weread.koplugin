#!/usr/bin/env python3
"""Exercise real KOReader home/reopen flow using only the synthetic mock service."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from urllib.parse import urlsplit

from mock_weread import BOOKS,MockServer,png,annotation
from my_cloud_marks_model import project as marks_project
from verify_owner_reading import FRAME,SourceText,decode_envelope
from verify_source_coordinates import FilteredSource


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--store',action='store_true')
    parser.add_argument('--cover',action='store_true')
    parser.add_argument('--marks',action='store_true')
    args=parser.parse_args()
    if args.cover and not args.store:parser.error('--cover requires --store')
    if args.marks and not args.store:parser.error('--marks requires --store')
    if args.cover:BOOKS[0]['cover']='https://cdn.weread.qq.com/mock/cover.png'
    server=MockServer(0);route=server.route
    if args.marks:
        server.selection_fixture=True
        row=annotation(1);row.update(bookmarkId='synthetic-home-highlight',type=1,style=1,colorStyle=0,chapterUid=1,createTime=1700000000)
        server.selection_marks={'synthetic-home-highlight':row}
    def off_shelf(method,target,data):
        parsed=urlsplit(target)
        if args.cover and method=='GET' and parsed.hostname=='cdn.weread.qq.com' and parsed.path=='/mock/cover.png':
            return 200,png()
        status,value=route(method,target,data)
        if method=='GET' and parsed.path=='/web/shelf/sync' and status==200:
            value=dict(value);value['books']=[row for row in value['books'] if row['bookId']!='900001']
        return status,value
    server.route=off_shelf
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=None;child=None
    try:
        source=server.chapter_source(1);parser_text=SourceText();parser_text.feed(source)
        sample=parser_text.samples[0]
        payload=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'},book_id='900001',chapter_uid='1',
            source_text=sample,source_raw_sha256=hashlib.sha256(source.encode()).hexdigest(),
            source_sample_offset=FilteredSource(source).locate(sample)[0],source_format='web_xhtml',
            shelf_ids=[row['bookId'] for row in BOOKS[1:]],shelf_books=len(BOOKS)-1,off_shelf_home=True,
            off_shelf_row={key:BOOKS[0][key] for key in ('bookId','title','author')},off_shelf_mock_port=server.server_port)
        if args.store:
            payload.update(off_shelf_store=True,store_search_keyword='山谷',native_grant={
                'vid':'900000','accessToken':'mock-native-access','refreshToken':'mock-native-refresh','deviceId':'0'*32})
        if args.cover:payload['off_shelf_cover']=True
        if args.marks:
            raw=server.route('GET','https://i.weread.qq.com/book/bookmarklist?bookId=900001&synckey=0',{})[1]
            payload.update(off_shelf_marks=True,native_marks_expected=marks_project(raw,'900001','900000',1))
        runner=Path(__file__).with_name('run_owner_reading_probe.py')
        cmd=[sys.executable,str(runner),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
             '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),
             '--off-shelf-home','--off-shelf-mock-port',str(server.server_port)]
        if args.store:cmd.append('--off-shelf-store')
        if args.cover:cmd.append('--off-shelf-cover')
        if args.marks:cmd.append('--off-shelf-marks')
        child=subprocess.run(cmd,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=320,
                             env=os.environ|{'WEREAD_SYNTHETIC_DEBUG':'1'})
        envelope=decode_envelope(child.stdout,'900000',off_shelf_home=True,off_shelf_store=args.store,off_shelf_cover=args.cover,off_shelf_marks=args.marks)
        report=envelope['report']
        writes=sum(event['method']=='POST' and event['path']!='/web/book/chapterInfos'
                   and not event['path'].startswith('/web/book/chapter/e_') for event in server.events)
        if child.returncode or report['result']!='PASS' or writes:raise ValueError('synthetic_home_failed')
        print(json.dumps({'result':'SYNTHETIC_HOME_VERIFIED','stages':report['stages'],
                          'profile_removed':report['profile_removed'],'account_data_writes':writes}))
        return 0
    except Exception:
        if report is None and child and child.stdout.count(FRAME)==1:
            try:report=json.loads(child.stdout.split(FRAME)[1]).get('report')
            except Exception:pass
        print(json.dumps({'result':'UNVERIFIED','reason':'synthetic_home_failed','diagnostic':report,
                          'synthetic_events':[{key:event.get(key) for key in ('method','path','status')} for event in server.events],
                          'synthetic_debug':child.stderr.decode(errors='replace')[-4096:] if child else ''}));return 1
    finally:
        server.shutdown();thread.join();server.server_close()


if __name__=='__main__':raise SystemExit(main())
