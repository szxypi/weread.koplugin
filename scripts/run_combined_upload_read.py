#!/usr/bin/env python3
"""Upload and read one scoped synthetic book using one disposable profile."""
import argparse,json,os,re,signal,subprocess,sys,tempfile
from pathlib import Path
from native_trial_pipe import Frames,read_initial,write_initial
from run_native_personal_upload_ui import validate_input,validate_stage
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child
from verify_cb_progress import cb_id
from verify_owner_reading import decode_envelope,validate_cookies


def validate_gate(value,target,owner,mock_port):
    if not isinstance(value,dict) or set(value)!={'seq','ok','payload'} or type(value['seq']) is not int or value['seq']!=1 or value['ok'] is not True:
        raise ValueError('combined/gate')
    data=value['payload']
    fields={'book_id','chapter_uid','source_format','source_text','source_raw_sha256','source_sample_offset',
            'shelf_ids','shelf_books','cb_reading','vid','cookies','combined_upload_read'}
    if mock_port is not None:fields.add('cb_mock_port')
    if (not isinstance(data,dict) or set(data)!=fields or data['book_id']!=target or not cb_id(target)
            or data['vid']!=owner or data['cb_reading'] is not True or data['combined_upload_read'] is not True
            or data['source_format']!='web_xhtml' or not isinstance(data['chapter_uid'],str)
            or re.fullmatch(r'[1-9][0-9]{0,19}',data['chapter_uid']) is None
            or not isinstance(data['source_text'],str) or not 32<=len(data['source_text'].encode())<=128
            or any(ord(char)<32 for char in data['source_text'])
            or not isinstance(data['source_raw_sha256'],str) or re.fullmatch('[a-f0-9]{64}',data['source_raw_sha256']) is None
            or type(data['source_sample_offset']) is not int or not 0<=data['source_sample_offset']<=2*1024*1024
            or not isinstance(data['shelf_ids'],list) or not 1<=len(data['shelf_ids'])<=5000
            or any(not isinstance(item,str) or not item or len(item)>128 or re.fullmatch(r'[A-Za-z0-9_-]+',item) is None for item in data['shelf_ids'])
            or len(set(data['shelf_ids']))!=len(data['shelf_ids'])
            or data['shelf_ids'].count(target)!=1 or type(data['shelf_books']) is not int
            or data['shelf_books']!=len(data['shelf_ids'])):raise ValueError('combined/scope')
    validate_cookies(data['cookies'],owner)
    if mock_port is not None and (data['cb_mock_port']!=mock_port or owner!='900000' or target!='CB_SyntheticResume'
                                  or data['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('combined/mock')
    return data


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--mock-port',type=int);args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('Linux KOReader required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('combined/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,upload=None,stages=[],error='none')
    try:
        payload=read_initial(sys.stdin.buffer);validate_input(payload,True,args.mock_port)
        if payload.get('combined_upload') is not True:raise ValueError('combined/scope')
        with tempfile.TemporaryDirectory(prefix='weread-upload-ui-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
                EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
                EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_UPLOAD_UI_ARMED='1')
            env.pop('WEREAD_UPLOAD_UI_MOCK_PORT',None)
            if args.mock_port is not None:env['WEREAD_UPLOAD_UI_MOCK_PORT']=str(args.mock_port)
            upload_probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_personal_upload_ui_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(upload_probe)],env=env,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);kind,stage=Frames(child.stdout,payload['rpc_token'],timeout=150).next()
                if kind!='RESULT' or child.wait(timeout=10):raise ValueError('combined/upload')
                validate_stage(stage,True);result['upload']=stage;target=stage['target']
            finally:stop_reader(child);child=None
            prefix=b'WEREAD_NATIVE_THOUGHT_'+payload['rpc_token'].encode()+b'_'
            sys.stdout.buffer.write(b'\n'+prefix+b'STEP='+json.dumps(dict(seq=1,target=target),separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
            reading=validate_gate(read_reply(sys.stdin.buffer,timeout=120),target,payload['credentials']['vid'],args.mock_port)
            env.pop('WEREAD_UPLOAD_UI_MOCK_PORT',None);env['WEREAD_COMBINED_UPLOAD_READ']='1'
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_reading_probe.lua'
            for mode in ('live','reopen'):
                code,out,repaint=run_child([str(runtime/'luajit'),str(probe),mode],env,
                    json.dumps(reading,ensure_ascii=False).encode(),runtime,timeout=150)
                envelope=decode_envelope(out,reading['vid'],mode=mode,cb_reading=True,combined_profile=True)
                stage=envelope['report'];result['stages'].append(stage);reading['cookies']=envelope['cookies']
                if code or repaint or stage['result']!='PASS':raise ValueError('combined/reading')
            if any(result['stages'][0][key]!=result['stages'][1][key] for key in ('pages','shelf_books')):raise ValueError('combined/reading')
            result.update(result='PASS',installed=check_installed(args.candidate,profile),cookies=reading['cookies'])
    except Exception as exc:
        result['error']=str(exc) if str(exc) in ('combined/gate','combined/scope','combined/mock','combined/upload','combined/reading') else 'combined/unavailable'
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    token=payload.get('rpc_token','') if isinstance(payload,dict) else ''
    if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
        sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
