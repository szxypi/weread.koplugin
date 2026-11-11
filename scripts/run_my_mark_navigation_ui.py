#!/usr/bin/env python3
"""Private source/mark cache navigation in two real native processes; no HTTP."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_MY_MARK_NAVIGATION_RESULT='
FLAGS={'native_filemanager','native_reader','archive_worker','heartbeat','exact_targets','workers_reaped','credential_audit'}
COUNTS={'failed_line','requests','located','buttons','source_files','screenshots'}
PERSONAL_FLAGS={'personal_display','personal_native_text','personal_position_notes_unchanged','personal_file_unchanged'}
PERSONAL_COUNTS={'personal_spans'}
DOWNLOAD_FLAGS={'missing_cache','download_confirmed','cancel_zero_requests','downloaded_source_verified','no_data_posts'}
DOWNLOAD_COUNTS={'confirmations','downloaded_chapters','http_gets','catalog_posts','content_posts','forbidden_requests','http_failures'}
DOWNLOAD_FRAME=b'\nWEREAD_NOTE_DOWNLOAD_RESULT='


def public_report(value):
    """Only fixed status/count fields may leave the captured private pipe."""
    if not isinstance(value,dict):return {}
    result={}
    if value.get('result') in ('PASS','UNVERIFIED'):result['result']=value['result']
    for key in ('profile_removed','installed_bytes_match'):
        if type(value.get(key)) is bool:result[key]=value[key]
    if type(value.get('installed_files')) is int and 0<=value['installed_files']<=1000:result['installed_files']=value['installed_files']
    result['stages']=[]
    if isinstance(value.get('stages'),list):
        for stage in value['stages'][:2]:
            if not isinstance(stage,dict):continue
            item={}
            for key in FLAGS|DOWNLOAD_FLAGS|PERSONAL_FLAGS:
                if type(stage.get(key)) is bool:item[key]=stage[key]
            for key in COUNTS|DOWNLOAD_COUNTS|PERSONAL_COUNTS:
                if type(stage.get(key)) is int and 0<=stage[key]<=100000:item[key]=stage[key]
            for key,allowed in [('result',('PASS','UNVERIFIED')),('mode',('live','reopen')),('phase',('init','navigate','close','complete'))]:
                if stage.get(key) in allowed:item[key]=stage[key]
            result['stages'].append(item)
    return result


def validate(value,mode,count,chapters,*,shots=False,download=False,personal=False):
    if mode not in ('live','reopen') or type(count) is not int or not 1<=count<=5000 or type(chapters) is not int or not 1<=chapters<=8:raise ValueError('ui_scope')
    flags=FLAGS|DOWNLOAD_FLAGS if download else FLAGS;counts=COUNTS|DOWNLOAD_COUNTS if download else COUNTS
    if personal:flags=flags|PERSONAL_FLAGS;counts=counts|PERSONAL_COUNTS
    if not isinstance(value,dict) or set(value)!=flags|counts|{'result','mode','phase'}:raise ValueError('ui_schema')
    if any(type(value[key]) is not bool or not value[key] for key in FLAGS):raise ValueError('ui_flags')
    if personal and (any(value[key] is not True for key in PERSONAL_FLAGS) or type(value['personal_spans']) is not int or value['personal_spans']!=count):raise ValueError('ui_personal')
    if download:
        if any(type(value[key]) is not bool for key in DOWNLOAD_FLAGS):raise ValueError('ui_flags')
        if not value['downloaded_source_verified'] or not value['no_data_posts']:raise ValueError('ui_flags')
        if any(value[key]!=(mode=='live') for key in ['missing_cache','download_confirmed','cancel_zero_requests']):raise ValueError('ui_flags')
    if any(type(value[key]) is not int or value[key]<0 for key in counts):raise ValueError('ui_counts')
    if (value['result']!='PASS' or value['mode']!=mode or value['phase']!='complete' or value['failed_line']
            or value['screenshots']!=((3 if download and mode=='live' else 2) if shots else 0) or value['located']!=count
            or value['buttons']!=count or value['source_files']!=chapters+(0 if download else 1)):raise ValueError('ui_incomplete')
    if not download and value['requests']:raise ValueError('ui_incomplete')
    if download:
        if value['forbidden_requests'] or value['http_failures'] or value['requests']!=value['http_gets']+value['catalog_posts']+value['content_posts']:raise ValueError('ui_transport')
        if mode=='live':
            if (value['confirmations']!=chapters or value['downloaded_chapters']!=chapters or not chapters*5<=value['requests']<=chapters*14
                    or not chapters<=value['http_gets']<=chapters*4 or value['catalog_posts']!=chapters
                    or not chapters*3<=value['content_posts']<=chapters*8):raise ValueError('ui_download')
        elif value['requests'] or value['confirmations'] or value['downloaded_chapters']:raise ValueError('ui_offline')
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--download-missing',action='store_true');parser.add_argument('--variant',choices=['thoughts']);parser.add_argument('--synthetic',action='store_true');parser.add_argument('--screenshots',type=Path)
    parser.add_argument('--personal-display',action='store_true');args=parser.parse_args(argv)
    if args.personal_display and (args.variant or args.download_missing):parser.error('personal display requires cached own highlights')
    if args.screenshots and not args.synthetic:parser.error('screenshots require synthetic input')
    runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('Linux runtime and positive dimensions required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    report=dict(result='UNVERIFIED',profile_removed=False,installed_bytes_match=False,stages=[]);root=None;cookies={}
    try:
        raw=sys.stdin.buffer.read(12*1024*1024+1)
        if len(raw)>12*1024*1024:raise ValueError('input_limit')
        payload=json.loads(raw);chapters=len(payload['chapters']);count=sum(len(row['rows']) for row in payload['chapters'])
        if payload.get('variant')!=args.variant:raise ValueError('input_scope')
        if (payload.get('download_missing') is True)!=args.download_missing:raise ValueError('input_scope')
        if args.download_missing:
            from verify_owner_reading import validate_cookies
            cookies=validate_cookies(payload['cookies'],payload['owner'])
        if not 1<=chapters<=8 or not 1<=count<=5000:raise ValueError('input_limit')
        if (payload.get('synthetic') is True)!=args.synthetic:raise ValueError('input_scope')
        if args.screenshots:args.screenshots.mkdir(parents=True,exist_ok=False)
        with tempfile.TemporaryDirectory(prefix='weread-marknav-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            if args.synthetic:env['WEREAD_MARKNAV_SYNTHETIC']='1'
            if args.variant:env['WEREAD_MARKNAV_VARIANT']=args.variant
            if args.personal_display:env['WEREAD_PERSONAL_DISPLAY']='1'
            if args.download_missing:env['WEREAD_NOTE_DOWNLOAD']='1'
            if args.screenshots:env['WEREAD_MARKNAV_SHOTS']=str(args.screenshots.resolve())
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/my_mark_navigation_probe.lua'
            for mode in ('live','reopen'):
                if args.download_missing:payload['cookies']=cookies;raw=json.dumps(payload,ensure_ascii=False).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,raw,runtime,timeout=max(240,count*25))
                if len(out)>8*1024*1024 or out.count(FRAME)!=1:raise ValueError('ui_frame')
                value=json.loads(out.split(FRAME)[1])
                if args.download_missing:
                    if not isinstance(value,dict) or set(value)!={'report','cookies'}:raise ValueError('ui_frame')
                    cookies=validate_cookies(value['cookies'],payload['owner']);value=value['report']
                report['stages'].extend(public_report(dict(stages=[value]))['stages'])
                if code or repaint:raise ValueError('ui_child')
                validate(value,mode,count,chapters,shots=bool(args.screenshots),download=args.download_missing,personal=args.personal_display)
            files=0
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if item.is_dir():continue
                    actual=profile/'plugins'/item.filename
                    if actual.is_symlink() or actual.read_bytes()!=archive.read(item):raise ValueError('candidate_layout')
                    files+=1
            report.update(result='PASS',installed_bytes_match=True,installed_files=files)
    except (Exception,subprocess.TimeoutExpired):pass
    finally:report['profile_removed']=root is not None and not root.exists()
    value=dict(report=report,cookies=cookies) if args.download_missing else report
    sys.stdout.buffer.write((DOWNLOAD_FRAME if args.download_missing else FRAME)+json.dumps(value,ensure_ascii=False).encode()+b'\n')
    return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
