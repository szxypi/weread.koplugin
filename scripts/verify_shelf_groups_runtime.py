#!/usr/bin/env python3
"""Packaged native group and popup regression; all data synthetic, no HTTP."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import zipfile

from shelf_groups_contract import project
from shelf_groups_ui_contract import validate


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();repo=Path(__file__).resolve().parent.parent;root=args.run_dir.resolve();runtime=args.koreader.resolve()
    root.mkdir(parents=True,exist_ok=False)
    for name in ('profile/plugins','evidence','xdg'):(root/name).mkdir(parents=True)
    (root/'xdg').chmod(0o700)
    candidate=root/'candidate.zip'
    subprocess.run(['bash',str(repo/'scripts/package_release.sh'),str(candidate)],check=True)
    with zipfile.ZipFile(candidate) as package:package.extractall(root/'profile/plugins')
    books=[dict(bookId=str(900000+i),title=f'合成书籍 {i}',author='测试作者',readUpdateTime=1000-i) for i in range(1,49)]
    books.append(dict(bookId='MP_WXS_900001',title='合成公众号'))
    archives=[dict(archiveId=i,name=('长分组名称用于检查菜单截断与翻页'*5 if i==2 else f'合成分组 {i}'),bookIds=([row['bookId'] for row in books[:20]] if i==1 else [books[i-1]['bookId']])) for i in range(1,23)]
    archives.extend([dict(archiveId=23,name='空分组',bookIds=[]),dict(archiveId=24,name='暂不可用书籍',bookIds=['999999']),
                     dict(archiveId=25,name='混合不可用书籍',bookIds=['999998','MP_WXS_900001']),dict(archiveId=26,name='公众号容器',bookIds=['MP_WXS_900001'])])
    shelf=dict(books=books,archive=archives);groups=project(shelf,'未命名分组','未分组')
    fixture=dict(shelf=shelf,expected_groups=groups,expected_shelf={row['bookId']:{} for row in books})
    (root/'evidence/fixture.json').write_text(json.dumps(fixture,ensure_ascii=False))
    env=dict(os.environ,KO_HOME=str(root/'profile'),WEREAD_SOURCE=str(root/'profile/plugins/weread.koplugin'),WEREAD_EVIDENCE=str(root/'evidence'),
             XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),
             EMULATE_READER_DPI=str(args.dpi),EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
    stages=[]
    for mode in ('live','reopen'):
        with (root/f'evidence/{mode}.log').open('w') as log:
            result=subprocess.run([str(runtime/'luajit'),str(repo/'spec/koreader/shelf_groups_runtime.lua')],cwd=runtime,
                                  env=dict(env,WEREAD_GROUP_MODE=mode),stdout=log,stderr=subprocess.STDOUT,timeout=90)
        raw=(root/f'evidence/{mode}.log').read_bytes();frame=b'\nWEREAD_GROUP_UI_RESULT='
        if result.returncode or raw.count(frame)!=1:raise RuntimeError('native synthetic group UI failed; inspect isolated log')
        stage=json.loads(raw.split(frame)[1])
        assert set(stage)=={'result','mode','http_requests','popup_cases','fresh_db_read','painted_views','group_coverage'}
        assert stage['result']=='PASS' and stage['mode']==mode and stage['http_requests']==0 and stage['popup_cases']==11 and stage['fresh_db_read'] is True
        assert stage['painted_views']==validate(stage['group_coverage'],mode,len(groups),True)
        assert b'[WeRead] forceRePaint failed:' not in raw
        stages.append(stage)
    report=dict(result='PASS',synthetic_only=True,stages=stages,physical_device=False)
    (root/'evidence/result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(result='PASS',groups=len(groups),popup_cases_per_process=11)))


if __name__=='__main__':main()
