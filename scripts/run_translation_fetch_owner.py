#!/usr/bin/env python3
"""Two fresh native processes; all real reading files confined to Linux tmpfs."""
import argparse,hashlib,json,os,re,resource,sys,tempfile
from pathlib import Path
from run_persistent_ui_probe import extract_candidate,run_child
from run_owner_reading_probe import check_installed
from verify_owner_reading import validate_cookies
from translation_owner_excerpt import original_excerpt

FRAME=b'\nWEREAD_TRANSLATION_OWNER='
FLAGS={'native_reader','downloaded','bilingual','translated_text_visible','original_kept','bookmark_kept',
    'cache_path_kept','source_exact','shortcut','credential_audit','workers_reaped'}
RANGE_FLAGS={'range_catalog_verified','range_sources_verified','range_chapters_visible'}
ANNOTATION_FLAGS={'annotation_copied','annotation_text_verified','annotation_original_preserved','annotation_stage_complete',
                  'annotation_changed_source','annotation_shifted'}


def payload_valid(p,port=None,annotations=False,range_mode=False):
    fields={'vid','cookies','book_id','chapter_uid','title','author','source','source_sha256','blocks'}
    if annotations:fields.add('original_source')
    if range_mode:fields.update(('chapter_uids','source_hashes','block_counts'))
    if not isinstance(p,dict) or set(p)!=fields|({'mock_port'} if port is not None else set()):raise ValueError('translation_owner/input')
    if (not isinstance(p['vid'],str) or not re.fullmatch('[1-9][0-9]{0,19}',p['vid'])
            or any(not isinstance(p[k],str) or not re.fullmatch('[1-9][0-9]{0,19}',p[k]) for k in ('book_id','chapter_uid'))
            or not 1<=int(p['chapter_uid'])<=2147483647
            or any(not isinstance(p[k],str) or len(p[k].encode())>4096 or '\0' in p[k] for k in ('title','author'))
            or not isinstance(p['source'],str) or not 200<=len(p['source'].encode())<=200*1024
            or not isinstance(p['source_sha256'],str) or hashlib.sha256(p['source'].encode()).hexdigest()!=p['source_sha256']
            or type(p['blocks']) is not int or not 1<=p['blocks']<=20000):raise ValueError('translation_owner/input')
    if range_mode:
        ids,hashes,counts=p['chapter_uids'],p['source_hashes'],p['block_counts']
        if (not isinstance(ids,list) or len(ids)!=3
                or any(not isinstance(v,str) or not re.fullmatch('[1-9][0-9]{0,9}',v) or int(v)>2147483647 for v in ids)
                or len(set(ids))!=3 or ids[0]!=p['chapter_uid']
                or not isinstance(hashes,list) or len(hashes)!=3 or hashes[0]!=p['source_sha256']
                or any(not isinstance(v,str) or not re.fullmatch('[0-9a-f]{64}',v) for v in hashes)
                or not isinstance(counts,list) or len(counts)!=3 or counts[0]!=p['blocks']
                or any(type(v) is not int or not 1<=v<=20000 for v in counts)):
            raise ValueError('translation_owner/input')
    if annotations and p.get('original_source')!=original_excerpt(p['source']):raise ValueError('translation_owner/input')
    validate_cookies(p['cookies'],p['vid'])
    if port is not None and (type(port) is not int or not 1<=port<=65535 or type(p['mock_port']) is not int
            or p['mock_port']!=port or p['vid']!='900000' or p['book_id']!='900001'
            or p['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('translation_owner/mock')
    return p


def validate_stage(r,mode,annotations=False,range_mode=False):
    flags=FLAGS | (ANNOTATION_FLAGS if annotations else set()) | (RANGE_FLAGS if range_mode else set())
    if (mode not in ('live','reopen') or not isinstance(r,dict)
            or set(r)!=flags|{'result','mode','phase','screenshots','requests','forbidden','failed_line'}
            or r['mode']!=mode or r['result']!='PASS' or r['phase']!='complete' or any(r[k] is not True for k in flags)
            or any(type(r[k]) is not int or r[k]!=0 for k in ('screenshots','forbidden','failed_line'))
            or type(r['requests']) is not int or not (1<=r['requests']<=(64 if range_mode else 32) if mode=='live' else r['requests']==0)):
        raise ValueError('translation_owner/stage')
    return r


def decode(raw,mode,owner,annotations=False,range_mode=False):
    if not isinstance(raw,bytes) or len(raw)>1024*1024 or raw.count(FRAME)!=1:raise ValueError('translation_owner/frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or set(value)!={'report','cookies'}:raise ValueError('translation_owner/frame')
    return validate_stage(value['report'],mode,annotations,range_mode),validate_cookies(value['cookies'],owner)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167);p.add_argument('--mock-port',type=int)
    p.add_argument('--annotations',action='store_true');p.add_argument('--range',action='store_true')
    a=p.parse_args(argv);runtime=a.koreader.resolve()
    if a.range and a.annotations:p.error('range and annotations are separate scenarios')
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or any(not 1<=n<=4096 for n in (a.width,a.height,a.dpi))
            or a.mock_port is not None and not 1<=a.mock_port<=65535):p.error('bounded Linux native runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    root=None;result=dict(result='UNVERIFIED',stages=[],profile_removed=False,cookies={},account_data_posts=0,authentication_posts=0)
    try:
        raw=sys.stdin.buffer.read(256*1024+1)
        if len(raw)>256*1024:raise ValueError('translation_owner/input')
        payload=payload_valid(json.loads(raw),a.mock_port,a.annotations,a.range)
        with tempfile.TemporaryDirectory(prefix='weread-translation-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi))
            if a.annotations:env['WEREAD_TRANSLATION_OWNER_ANNOTATIONS']='1'
            if a.range:env['WEREAD_TRANSLATION_OWNER_RANGE']='1'
            script=Path(__file__).resolve().parent.parent/'spec/koreader/translation_fetch_owner.lua'
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(runtime/'luajit'),str(script),mode],env,json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode(),runtime,timeout=160)
                if code or repaint:
                    if len(out)<=1024*1024 and out.count(FRAME)==1:
                        diagnostic=json.loads(out.split(FRAME)[1]).get('report',{})
                        result['phase']=diagnostic.get('phase') if diagnostic.get('phase') in ('input','prepare','reader','download','copy','audit','complete') else 'other'
                        result['failed_line']=diagnostic.get('failed_line') if type(diagnostic.get('failed_line')) is int else 0
                    raise ValueError('translation_owner/reader')
                stage,cookies=decode(out,mode,payload['vid'],a.annotations,a.range);result['stages'].append(stage);payload['cookies']=cookies;result['cookies']=cookies
            result.update(result='PASS',installed=check_installed(a.candidate,profile))
    except Exception as error:
        result['reason']=str(error) if isinstance(error,ValueError) and re.fullmatch('translation_owner/[a-z_]+',str(error)) else 'translation_owner/runner'
    finally:result['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(b'\nWEREAD_TRANSLATION_OWNER_RUNNER='+json.dumps(result,separators=(',',':')).encode()+b'\n')
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
