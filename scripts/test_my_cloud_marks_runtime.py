#!/usr/bin/env python3
"""Synthetic native Menu/TextViewer, error, save and close/cancel acceptance."""
import argparse
import json
from pathlib import Path
import subprocess
from run_my_cloud_marks_ui import FRAME,validate_stage
from my_cloud_marks_model import project
from my_cloud_thoughts_model import complete


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--variant',choices=['thoughts']);parser.add_argument('--run-dir',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167);args=parser.parse_args()
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True,capture_output=True)
    source=dict(bookId='900001',updated=[],chapters=[dict(chapterUid=7,title='合成章节：长名称与中文分页')])
    for index in range(45):
        kind=0 if index%10==0 else 2 if index==44 else 1
        row=dict(bookmarkId=f'synthetic-mark-{index}',type=kind,chapterUid=7,style=1,colorStyle=0,createTime=1000+index)
        if kind!=0:row['markText']=f'合成划线 {index+1}：原生文字显示与中文分页 😀。'+('这是长引用，点开后应完整显示。\n'*40 if index==1 else '第二句。')
        else:row['abstract']='合成书签的章节摘要。'
        source['updated'].append(row)
    if args.variant=='thoughts':
        source=dict(bookId='900001',reviews=[],totalCount=45,hasMore=0)
        for index in range(45):
            row=dict(reviewId=f'synthetic-thought-{index}',bookId='900001',userVid=900000,content=f'合成想法 {index+1}：原生文字、中文分页 😀。',
                chapterUid='7' if index==0 else 7,chapterIdx=1,type=1,isPrivate=index%2,chapterName='合成想法章节',createTime=1000+index)
            if index==44:row['content']=''
            if index%10:row['abstract']='合成引用原文。'+('长引用保持完整。\n'*40 if index==1 else '第二句。')
            source['reviews'].append(dict(reviewId=row['reviewId'],review=row))
        expected=complete(source,'900001','900000',1000)
    else:expected=project(source,'900001','900000',1000)
    payload=dict(source=source,book_id='900001',owner='900000',now=1000,synthetic=True,
        credentials=dict(vid='900000',accessToken='synthetic-mark-access',refreshToken='synthetic-mark-refresh',deviceId='1'*32))
    if args.variant:payload['variant']=args.variant
    command=['python3',str(repo/'scripts/run_my_cloud_marks_ui.py'),'--koreader',str(args.koreader),'--candidate',str(candidate),
        '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--synthetic','--screenshots',str(root/'screenshots')]
    if args.variant:command.extend(['--variant',args.variant])
    child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=360)
    assert child.stdout.count(FRAME)==1
    value=json.loads(child.stdout.split(FRAME)[1])
    if child.returncode:
        (root/'failure.json').write_text(json.dumps(value.get('ui',{}),indent=2)+'\n');raise RuntimeError('native own-mark UI failed')
    assert value['model']==expected and value['native']==expected
    assert value['ui']['installed_bytes_match'] and value['ui']['profile_removed']
    for stage,mode in zip(value['ui']['stages'],('live','reopen')):validate_stage(stage,mode,45,synthetic=True,shots=True,thoughts=args.variant=='thoughts')
    (root/'result.json').write_text(json.dumps(value['ui'],indent=2)+'\n');print(json.dumps(value['ui']))


if __name__=='__main__':main()
