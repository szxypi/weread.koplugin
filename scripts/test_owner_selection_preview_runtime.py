#!/usr/bin/env python3
"""Opt-in synthetic native submit-boundary and fresh offline draft acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading

from annotation_experiment_model import note_text
from mock_weread import BOOK_ID,MockServer
from owner_selection_preview import choose,compare,decode
from my_cloud_marks_model import identifier
from verify_owner_reading import SourceText
from verify_source_coordinates import FilteredSource


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args()
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    archive=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(archive)],check=True,capture_output=True)
    server=MockServer(0,root/'requests.jsonl');server.selection_fixture=True
    server.progress[BOOK_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=120,progress=37,summary="合成进度")
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        shelf=server.route('GET','https://weread.qq.com/web/shelf/sync',{})[1]['books']
        raw=server.chapter_source(2);parser=SourceText();parser.feed(raw);text=parser.samples[0]
        selected=choose(raw,{},BOOK_ID,'2',2);row=selected['reference']
        credentials=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
        payload=dict(vid='900000',book_id=BOOK_ID,chapter_uid='2',source_text=text,source_sample_offset=FilteredSource(raw).locate(text)[0],
            source_format='web_xhtml',source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),shelf_ids=[str(row['bookId']) for row in shelf if identifier(str(row['bookId']))],shelf_books=len(shelf),
            cookies=dict(wr_vid='900000',wr_skey='mock_key'),selection_mock_port=server.server_port,
            selection_preview=dict(credentials=credentials,first=selected['first'],last=selected['last'],reference=row,
                body=dict(bookId=BOOK_ID,chapterUid='2',bookVersion=700,type=1,range=row['range'],abstract=row['markText'],isPrivate=1,content=note_text('1'*32))))
        command=['python3',str(repo/'scripts/run_owner_reading_probe.py'),'--koreader',str(args.koreader),'--candidate',str(archive),
            '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--selection-thought-preview','--mock-port',str(server.server_port)]
        child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=600,env=os.environ.copy())
        envelope=decode(child.stdout,'900000');report=envelope['report']
        if child.returncode or report['result']!='PASS':
            (root/'result.json').write_text(json.dumps(report,indent=2)+'\n');raise ValueError('selection_native_unverified')
        compare(envelope['selection_private'],raw,payload)
        assert server.selection_posts==0
        for (path,_body),count in server.request_totals.items():
            if path in ('/review/add','/review/useredit','/review/delete','/web/book/read','/login','/web/login/renewal'):assert count==0
        report.update(independent_model=True,forwarded_account_posts=0,synthetic_only=True)
        (root/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
