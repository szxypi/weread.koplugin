#!/usr/bin/env python3
"""Synthetic original-text buttons, native jumps and separate offline reopen."""
import argparse
import json
from pathlib import Path
import subprocess

from my_cloud_marks_model import project as marks_project
from my_mark_target import project
from run_my_mark_navigation_ui import FRAME,validate


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args()
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],capture_output=True,check=True)
    source=dict(bookId='900001',updated=[],chapters=[]);chapters=[]
    for index in (1,2):
        uid=str(index);body='<h1>合成章节 '+uid+'</h1>'+''.join('<p>第'+str(n)+'段：'+('墨水屏原生阅读保留章节与文字的位置，翻页不改变原文归属。'*4)+'</p>' for n in range(1,18))
        selected=['这是第'+uid+'章的第一条合成划线，点击后应准确显示在原生阅读器。','第二条合成划线包含中文、空格 A & B 和表情 😀，应保留实际文字。','短引用']
        body+='<p>'+selected[0]+'</p><p>'+selected[1].replace('&','&amp;')+'</p><p>唯一的第三段前文'+selected[2]+'后面仍有完整的上下文。</p>'
        raw='<html><body>'+body+'</body></html>';rows=[]
        for number,quote in enumerate(selected):
            encoded=quote.replace('&','&amp;');start=raw.index(encoded)
            row=dict(bookmarkId=f'synthetic-{index}-{number}',type=1,chapterUid=index,chapterIdx=index,markText=quote,range=f'{start}-{start+len(encoded)}')
            rows.append(row);source['updated'].append(row)
        source['chapters'].append(dict(chapterUid=index,title='合成章节 '+uid))
        chapters.append(dict(chapter_uid=uid,raw=raw,rows=rows,targets=[project(raw,'900001',uid,row) for row in rows]))
    payload=dict(book_id='900001',owner='900000',synthetic=True,model=marks_project(source,'900001','900000',1000),chapters=chapters)
    command=['python3',str(repo/'scripts/run_my_mark_navigation_ui.py'),'--koreader',str(args.koreader),'--candidate',str(candidate),'--synthetic',
        '--screenshots',str(root/'screenshots'),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi)]
    child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=600)
    assert child.stdout.count(FRAME)==1
    result=json.loads(child.stdout.split(FRAME)[1]);(root/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    assert child.returncode==0 and result['result']=='PASS' and result['profile_removed'] and result['installed_bytes_match'],result
    for row,mode in zip(result['stages'],('live','reopen')):validate(row,mode,6,2,shots=True)
    print(json.dumps(result))


if __name__=='__main__':main()
