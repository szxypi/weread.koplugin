#!/usr/bin/env python3
"""Exercise the owner missing-resume harness against synthetic loopback data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import BOOK_ID,MockServer
from verify_owner_reading import SourceText,decode_envelope
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import identifier
from verify_cb_progress import cb_id


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    choice=parser.add_mutually_exclusive_group();choice.add_argument('--reader-estimate',action='store_true');choice.add_argument('--reader-typography',action='store_true');choice.add_argument('--reader-margins',action='store_true');choice.add_argument('--reader-display',action='store_true')
    parser.add_argument('--reader-neighbor',action='store_true')
    args=parser.parse_args()
    if args.reader_neighbor and not args.reader_estimate:parser.error('--reader-neighbor requires --reader-estimate')
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    archive=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(archive)],check=True,capture_output=True)
    server=MockServer(0,root/'requests.jsonl');server.cb_reading=True
    server.progress[BOOK_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=120,progress=37,summary='Synthetic progress')
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        shelf=server.route('GET','https://weread.qq.com/web/shelf/sync',{})[1]['books']
        raw=server.chapter_source(2);reader=SourceText();reader.feed(raw);text=reader.samples[0]
        payload=dict(vid='900000',book_id=BOOK_ID,chapter_uid='2',source_text=text,
            source_sample_offset=FilteredSource(raw).locate(text)[0],source_format='web_xhtml',
            source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),
            shelf_ids=[str(row['bookId']) for row in shelf if cb_id(row['bookId']) or identifier(str(row['bookId']))],shelf_books=len(shelf),
            cookies=dict(wr_vid='900000',wr_skey='mock_key'),missing_resume_probe=True,resume_warning_probe=True,resume_mock_port=server.server_port)
        if args.reader_estimate:payload['reader_estimate_probe']=True
        if args.reader_neighbor:
            payload['reader_neighbor']=dict(uid='3',direction=1,
                raw_sha256=hashlib.sha256(server.chapter_source(3).encode()).hexdigest())
        if args.reader_typography:payload['reader_typography_probe']=True
        if args.reader_margins:payload['reader_margins_probe']=True
        if args.reader_display:payload['reader_display_probe']=True
        command=['python3',str(repo/'scripts/run_owner_reading_probe.py'),'--koreader',str(args.koreader),'--candidate',str(archive),
            '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),
            '--missing-resume','--resume-warning','--resume-mock-port',str(server.server_port)]
        if args.reader_estimate:command.append('--reader-estimate')
        if args.reader_neighbor:command.append('--reader-neighbor')
        if args.reader_typography:command.append('--reader-typography')
        if args.reader_margins:command.append('--reader-margins')
        if args.reader_display:command.append('--reader-display')
        child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=400,env=os.environ.copy())
        envelope=decode_envelope(child.stdout,'900000',missing_resume=True,resume_warning=True,reader_estimate=args.reader_estimate,reader_neighbor=args.reader_neighbor,reader_typography=args.reader_typography,reader_margins=args.reader_margins,reader_display=args.reader_display);report=envelope['report']
        (root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        if child.returncode or report['result']!='PASS':raise ValueError('missing_resume_native_unverified')
        for (path,_body),count in server.request_totals.items():
            if path in ('/web/book/read','/login','/web/login/renewal'):assert count==0
        print('PASS: isolated owner harness; synthetic fallback, target chapter and fresh offline reopen')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
