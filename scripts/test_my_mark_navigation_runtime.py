#!/usr/bin/env python3
"""Synthetic original-text buttons, native jumps and separate offline reopen."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import threading
from unittest.mock import patch

from my_cloud_marks_model import project as marks_project
from my_mark_target import project
from my_thought_target import project as thought_target
from bookmark_point import from_mark as bookmark_target
from my_cloud_thoughts_model import complete as thoughts_project
from run_my_mark_navigation_ui import FRAME,DOWNLOAD_FRAME,validate


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--imported',action='store_true',help='exercise imported-book quote navigation')
    cached=parser.add_mutually_exclusive_group()
    cached.add_argument('--no-catalog',action='store_true',help='locate saved notes using only the downloaded EPUB source')
    cached.add_argument('--partial-book',action='store_true',help='locate saved notes in a book with some chapters downloaded')
    parser.add_argument('--download-missing',action='store_true');parser.add_argument('--variant',choices=['thoughts','bookmarks']);parser.add_argument('--personal-display',action='store_true');parser.add_argument('--txt',action='store_true');parser.add_argument('--txt-utf16',action='store_true');parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args()
    if args.imported and args.download_missing:parser.error('imported fixture uses cached navigation')
    if args.txt and not args.imported:parser.error('TXT fixture requires an imported book')
    if args.txt_utf16 and not args.txt:parser.error('UTF-16 range requires TXT')
    if (args.no_catalog or args.partial_book) and (args.download_missing or args.personal_display):
        parser.error('incomplete book fixtures use cached note navigation')
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],capture_output=True,check=True)
    book_id='CB_SyntheticNotes' if args.imported else '900001'
    source=dict(bookId=book_id,updated=[],chapters=[]);chapters=[]
    for index in (1,2):
        uid=str(index);body='<h1>合成章节 '+uid+'</h1>'+''.join('<p>第'+str(n)+'段：'+('墨水屏原生阅读保留章节与文字的位置，翻页不改变原文归属。'*4)+'</p>' for n in range(1,18))
        selected=['这是第'+uid+'章的第一条合成划线，点击后应准确显示在原生阅读器。','第二条合成划线包含中文、空格 A & B 和表情 😀，应保留实际文字。','短引用']
        body+='<p>'+selected[0]+'</p><p>'+selected[1].replace('&','&amp;')+'</p><p>唯一的第三段前文'+selected[2]+'后面仍有完整的上下文。</p>'
        raw=('😀 合成章节 '+uid+'\n'+''.join('第'+str(n)+'段：'+('墨水屏原生阅读保留章节与文字的位置，翻页不改变原文归属。'*4)+'\n' for n in range(1,18))
             +selected[0]+'\n'+selected[1]+'\n唯一的第三段前文'+selected[2]+'后面仍有完整的上下文。\n') if args.txt else '<html><body>'+body+'</body></html>'
        rows=[];targets=[]
        for number,quote in enumerate(selected):
            encoded=quote if args.txt else quote.replace('&','&amp;');start=raw.index(encoded)
            row=dict(bookmarkId=f'synthetic-{index}-{number}',type=1,chapterUid=index,chapterIdx=index,markText=quote,range=f'{start}-{start+len(encoded)}')
            if args.txt_utf16:
                first=len(raw[:start].encode('utf-16-le'))//2
                last=first+len(encoded.encode('utf-16-le'))//2
                row['range']=f'{first}-{last}'
            if args.variant=='thoughts':
                row=dict(reviewId=row['bookmarkId'],type=1,chapterUid=index,chapterIdx=index,range=row['range'],abstract=quote,
                         content=f'合成想法 {index}-{number}：这段附注不用于原文定位。',isPrivate=number%2,chapterName='合成章节 '+uid)
            elif args.variant=='bookmarks':
                point=len(raw[:start].encode('utf-16-le'))//2 if args.txt_utf16 else start
                row.update(type=0,range=str(point),markText=quote if number<2 else '短引用后面仍有完整的上下文。')
            rows.append(row);source['updated'].append(row)
            if args.txt:
                targets.append(dict(chapter_offset=len(raw[:start].encode('utf-16-le'))//2,raw_sha256=hashlib.sha256(raw.encode()).hexdigest()))
        source['chapters'].append(dict(chapterUid=index,title='合成章节 '+uid))
        projector=thought_target if args.variant=='thoughts' else bookmark_target if args.variant=='bookmarks' else project
        chapters.append(dict(chapter_uid=uid,raw=raw,rows=rows,targets=targets if args.txt else [projector(raw,book_id,uid,row) for row in rows],format='web_txt' if args.txt else 'web_xhtml'))
    if args.variant=='thoughts':
        reviews=[dict(reviewId=row['reviewId'],review=dict(row,bookId=book_id,userVid=900000)) for row in source['updated']]
        reviews.extend([dict(reviewId='synthetic-no-source',review=dict(reviewId='synthetic-no-source',bookId=book_id,userVid=900000,content='合成无引用想法',type=0)),
                        dict(reviewId='synthetic-missing-range',review=dict(reviewId='synthetic-missing-range',bookId=book_id,userVid=900000,content='合成缺少范围',type=1,chapterUid=1,abstract='引用文字'))])
        model=thoughts_project(dict(reviews=reviews,totalCount=len(reviews),hasMore=0),book_id,'900000',1000)
    else:model=marks_project(source,book_id,'900000',1000)
    payload=dict(book_id=book_id,owner='900000',synthetic=True,model=model,chapters=chapters)
    if args.no_catalog:payload['no_catalog']=True
    if args.partial_book:payload['partial_book']=True
    command=['python3',str(repo/'scripts/run_my_mark_navigation_ui.py'),'--koreader',str(args.koreader),'--candidate',str(candidate),'--synthetic',
        '--screenshots',str(root/'screenshots'),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
    if args.variant:payload['variant']=args.variant;command.extend(['--variant',args.variant])
    if args.personal_display:command.append('--personal-display')
    server=None
    try:
        if args.download_missing:
            from mock_weread import MockServer
            server=MockServer(0,None);threading.Thread(target=server.serve_forever,daemon=True).start()
            payload.update(download_missing=True,cookies=dict(wr_vid='900000',wr_skey='synthetic-note-cookie'),mock_endpoint='http://127.0.0.1:'+str(server.server_port))
            command.append('--download-missing')
            sources={int(row['chapter_uid']):row['raw'] for row in chapters}
            with patch('mock_weread.chapter_html',side_effect=lambda uid:sources[uid]):
                child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=600)
        else:child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=600)
    finally:
        if server:server.shutdown();server.server_close()
    frame=DOWNLOAD_FRAME if args.download_missing else FRAME;assert child.stdout.count(frame)==1
    result=json.loads(child.stdout.split(frame)[1]);result=result['report'] if args.download_missing else result
    (root/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    assert child.returncode==0 and result['result']=='PASS' and result['profile_removed'] and result['installed_bytes_match'],result
    for row,mode in zip(result['stages'],('live','reopen')):validate(row,mode,6,2,shots=True,download=args.download_missing,personal=args.personal_display)
    if server:assert not any(path in {'/web/book/read','/login','/web/login/renewal','/review/add','/review/useredit','/review/delete'} for path,_query in server.request_totals)
    print(json.dumps(result))


if __name__=='__main__':main()
