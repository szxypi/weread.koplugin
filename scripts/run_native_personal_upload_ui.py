#!/usr/bin/env python3
"""Supervise one packaged upload UI trial inside a disposable tmpfs profile."""
import argparse,base64,json,os,re,signal,subprocess,sys,tempfile
from pathlib import Path
from native_trial_pipe import Frames,read_initial,write_initial
from personal_upload_trial import valid_book
from run_native_thought_trial import stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from verify_eink_renewal import validate_credentials

FLAGS={'permit_writes','chooser','cancel_no_request','heartbeat','journal_idle','cache_verified','file_unchanged','credential_audit','guard_selftest'}
COUNTS={'native_gets':10,'credential_gets':1,'puts':1,'notifies':1,'denied':0,'screenshots':0,'failed_line':10000}


def validate_stage(value,armed):
    fields=FLAGS|set(COUNTS)|{'result','phase'}|({'target'} if armed else set())
    if (not isinstance(value,dict) or set(value)!=fields or value['result']!='PASS' or value['phase']!='complete'
            or value['permit_writes'] is not armed or any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0<=value[k]<=limit for k,limit in COUNTS.items())
            or not all(value[k] for k in ('chooser','cancel_no_request','file_unchanged','credential_audit','guard_selftest'))
            or any(value[k] is not armed for k in ('heartbeat','journal_idle','cache_verified'))
            or value['failed_line'] or (value['native_gets']<2 if armed else value['native_gets']!=0)
            or any(value[k]!=(1 if armed else 0) for k in ('credential_gets','puts','notifies'))
            or armed and not valid_book(value['target'])):raise ValueError('native_upload_ui/stage')
    return value


def validate_input(value,armed,mock_port):
    fields={'credentials','name','shelf_books','rpc_token','permit_writes'}|({'mock_port'} if mock_port is not None else set())
    epub=isinstance(value,dict) and value.get('fixture')=='epub'
    large=isinstance(value,dict) and value.get('fixture')=='large_epub'
    near=isinstance(value,dict) and value.get('fixture')=='near_epub'
    fmt=value.get('fixture') if isinstance(value,dict) and value.get('fixture') in ('pdf','mobi','azw3') else None
    if epub:fields|={'fixture','body_base64'}
    if fmt:fields|={'fixture','body_base64'}
    if large or near:fields.add('fixture')
    if (not isinstance(value,dict) or set(value)!=fields or value['permit_writes'] is not armed or value.get('mock_port')!=mock_port
            or not isinstance(value['rpc_token'],str) or re.fullmatch('[a-f0-9]{32}',value['rpc_token']) is None
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000):raise ValueError('native_upload_ui/input')
    validate_credentials(value['credentials'])
    if epub:
        from synthetic_upload_epub import build
        if value['body_base64']!=base64.b64encode(build()).decode('ascii'):raise ValueError('native_upload_ui/fixture')
    if fmt:
        from synthetic_pdf_trial import build as build_pdf
        from synthetic_format_trial import build as build_format
        expected=build_pdf() if fmt=='pdf' else build_format(fmt)
        if value['body_base64']!=base64.b64encode(expected).decode('ascii'):raise ValueError('native_upload_ui/fixture')
    if mock_port is None:
        pattern=r'KOReaderSynthetic-[a-f0-9]{16}\.'+(fmt if fmt else 'epub' if epub or large or near else 'txt')
        if not isinstance(value['name'],str) or re.fullmatch(pattern,value['name']) is None:raise ValueError('native_upload_ui/input')
    elif (value['name']!=('SyntheticUpload.'+fmt if fmt else 'SyntheticNearEpub.epub' if near else 'SyntheticLargeEpub.epub' if large else 'SyntheticUploadEpub.epub' if epub else 'SyntheticUpload.txt') or value['credentials']!=dict(vid='900000',accessToken='mock-native-access',
          refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)):raise ValueError('native_upload_ui/mock')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true');parser.add_argument('--mock-port',type=int);args=parser.parse_args(argv)
    runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('bounded Linux runtime required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('native_upload_ui/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,stage=None)
    try:
        payload=read_initial(sys.stdin.buffer);validate_input(payload,args.armed,args.mock_port)
        with tempfile.TemporaryDirectory(prefix='weread-upload-ui-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            if payload.get('fixture')=='large_epub':
                import hashlib
                from large_epub_trial import BODY_SHA256_LARGE,BODY_SIZE
                from synthetic_upload_epub import build_large
                book=build_large()
                if len(book)!=BODY_SIZE or hashlib.sha256(book).hexdigest()!=BODY_SHA256_LARGE:raise ValueError('native_upload_ui/fixture')
                with (profile/payload['name']).open('xb') as stream:stream.write(book)
                del book
            if payload.get('fixture')=='near_epub':
                import hashlib
                from near_limit_epub_trial import BODY_SHA256_NEAR,BODY_SIZE
                from synthetic_near_limit_epub import write_fixture
                with (profile/payload['name']).open('x+b') as stream:
                    write_fixture(stream)
                    if stream.tell()!=BODY_SIZE:raise ValueError('native_upload_ui/fixture')
                    stream.seek(0);digest=hashlib.sha256()
                    for part in iter(lambda:stream.read(65536),b''):digest.update(part)
                    if digest.hexdigest()!=BODY_SHA256_NEAR:raise ValueError('native_upload_ui/fixture')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
                EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_UPLOAD_UI_ARMED='1' if args.armed else '0')
            env.pop('WEREAD_UPLOAD_UI_MOCK_PORT',None)
            if args.mock_port is not None:env['WEREAD_UPLOAD_UI_MOCK_PORT']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_personal_upload_ui_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],env=env,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);kind,stage=Frames(child.stdout,payload['rpc_token'],timeout=900 if payload.get('fixture')=='near_epub' else 140).next()
                if kind!='RESULT':raise ValueError('native_upload_ui/frame')
                result['stage']=stage
                if child.wait(timeout=10):raise ValueError('native_upload_ui/child')
                validate_stage(stage,args.armed)
            finally:stop_reader(child);child=None
            result.update(result='PASS',installed=check_installed(args.candidate,profile))
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    token=payload.get('rpc_token','') if isinstance(payload,dict) else ''
    if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
        sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
