#!/usr/bin/env python3
"""Read-only two-chapter full-downloader check; private data stays in RAM/tmpfs."""
import argparse
import json
import resource
import subprocess

from native_chapter_remote_reference import search_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_native_chapter_package import ChapterProbe
from verify_translation_preflight import TranslationWebProbe


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true',required=True)
    parser.add_argument('--book-offset',type=int,default=0,choices=range(0,51))
    parser.add_argument('--live-web',action='store_true',help='Use the plugin Web downloader for the same chapters')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER,required=True)
    args=parser.parse_args()
    report=dict(result='UNVERIFIED',account_data_writes=0,authorization_requests=0,
                credentials_written_to_files=False,chapter_content_only_on_tmpfs=True)
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
        sample,first,_native=ChapterProbe().inspect(credentials,args.book_offset)
        candidates=sorted((row for row in sample['expected']['chapters']
                           if row['uid']>0 and row.get('wordCount',0)>=200 and row['free_or_owned']),
                          key=lambda row:row['uid'])
        if len(candidates)<2 or candidates[0]['uid']!=first['uid']:
            raise ValueError('insufficient_chapters')
        web=TranslationWebProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items(): web.set_cookie(key,value)
        web.verify_account();chapters=[]
        for index,row in enumerate(candidates[:2],1):
            if not web.inspect_content(sample,chapter_uid=row['uid']).get('content_decoded'):
                raise ValueError('web_unavailable')
            raw=web.content_sample['source']
            if not 0<len(raw.encode())<=2*1024*1024:
                raise ValueError('source_size')
            chapters.append(dict(chapterUid=str(row['uid']),chapterIdx=index,title='Temporary chapter',
                                 source=raw,search_token=search_token(raw.encode())))
        payload=dict(owner=True,credentials=credentials,book_id=sample['book_id'],
                     book_version=sample['expected']['version'],chapters=chapters)
        if args.live_web:
            payload.update(live_web=True,cookies=saved['cookies'])
        encoded=json.dumps(payload,ensure_ascii=False).encode()
        if len(encoded)>5*1024*1024: raise ValueError('source_size')
        child=subprocess.run(args.lua_command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                             timeout=180,check=False)
        marker=b'WEREAD_FULL_RESULT='
        if child.returncode or child.stdout.count(marker)!=1 or len(child.stdout)>65536:
            raise ValueError('native_full_unverified')
        result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
        if (set(result)!={'ok','owner','chapters','styles','images','live_web','credential_audit'} or result['ok'] is not True
                or result['owner'] is not True or result['chapters']!=2
                or result['live_web'] is not args.live_web
                or result['credential_audit'] is not args.live_web
                or type(result['styles']) is not int or not 1<=result['styles']<=2
                or type(result['images']) is not int or not 1<=result['images']<=2):
            raise ValueError('native_full_unverified')
        if args.live_web:
            offline_marker=b'WEREAD_FULL_OFFLINE_RESULT='
            if child.stdout.count(offline_marker)!=1:
                raise ValueError('native_full_unverified')
            offline=json.loads(child.stdout.split(offline_marker,1)[1].splitlines()[0])
            if offline!=dict(ok=True,chapters=2,images=result['images'],network_blocked=True):
                raise ValueError('native_full_unverified')
        report.update(result='PASS',chapters=2,native_chapters=2,styles=result['styles'],
                      image_chapters=result['images'],source_metadata_preserved=True,offline_rendered=True,
                      live_web_download=args.live_web)
        if args.live_web:
            report['offline_new_process']=True
            report['temporary_files_credential_audit']=True
    except Exception as exc:
        allowed={'insufficient_chapters','web_unavailable','source_size','native_full_unverified'}
        report['reason']=str(exc) if str(exc) in allowed else 'preflight_or_network_failed'
    print(json.dumps(report,ensure_ascii=False))
    return int(report['result']!='PASS')


if __name__=='__main__':
    raise SystemExit(main())
