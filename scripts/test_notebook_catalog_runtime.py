#!/usr/bin/env python3
"""Synthetic installed plugin UI, native transport and offline restart acceptance."""
import argparse
import json
from pathlib import Path
import subprocess
from notebook_catalog_model import project
from run_notebook_catalog_ui import FRAME,validate_stage


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--owner-search',action='store_true');args=parser.parse_args()
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False);repo=Path(__file__).resolve().parent.parent
    candidate=root/'candidate.zip';subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True,capture_output=True)
    rows=[]
    for index in range(45):
        book_id=str(900001+index)
        title=f'合成😀书籍 {index+1}' if index==0 else f'合成书籍 {index+1}'
        author='合成作者🙂' if index==1 else '合成作者'
        if args.owner_search and index==3:title='合成实例'
        rows.append(dict(bookId=book_id,book=dict(bookId=book_id,title=title,author=author),
                         noteCount=index,reviewCount=index%4,bookmarkCount=index%3,sort=1000-index))
    source=dict(books=rows,totalBookCount=len(rows));expected=project(source,1000)
    payload=dict(source=source,owner='900000',now=1000,synthetic=True,
        credentials=dict(vid='900000',accessToken='synthetic-notebook-access',refreshToken='synthetic-notebook-refresh',deviceId='1'*32))
    command=['python3',str(repo/'scripts/run_notebook_catalog_ui.py'),'--koreader',str(args.koreader),'--candidate',str(candidate),
        '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--synthetic']
    if args.owner_search:
        from owner_notebook_search_cases import prepare
        payload['search_cases']=prepare(expected);command.append('--owner-search')
    child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=360)
    assert child.stdout.count(FRAME)==1
    value=json.loads(child.stdout.split(FRAME)[1])
    if child.returncode:
        (root/'failure.json').write_text(json.dumps(value.get('ui',{}),indent=2)+'\n');raise RuntimeError('native notebook UI failed')
    assert value['model']==expected and value['native']==expected
    assert value['ui']['installed_bytes_match'] and value['ui']['profile_removed']
    for stage,mode in zip(value['ui']['stages'],('live','reopen')):validate_stage(stage,mode,45,owner_search=args.owner_search)
    (root/'result.json').write_text(json.dumps(value['ui'],indent=2)+'\n');print(json.dumps(value['ui']))


if __name__=='__main__':main()
