#!/usr/bin/env python3
"""Guarded native menu worker for one independently reviewed time transfer."""
import argparse,json,os,re,resource,shutil,signal,subprocess,sys,time
from pathlib import Path

from native_time_bundle_gate import day
from cb_native_time_bundle_remote_archive import Relay
from check_cb_dry_candidate import check as check_candidate
from native_time_bundle_workspace import restore
from native_time_capture_evidence import validate_evidence
from native_trial_pipe import Frames,read_initial,reply,write_initial
from process_loss_runtime import enable_subreaper
from readtime_statistics import validate as validate_months
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from verify_eink_renewal import validate_credentials
from verify_owner_reading import validate_cookies


def main(argv=None,*,mock_only=False):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--mock-port',type=int,help='Synthetic account and loopback service only')
    parser.add_argument('--allow-live',action='store_true',help='Enable the separately guarded live transfer')
    for name in ('width','height','dpi'):parser.add_argument('--'+name,required=True,type=int)
    args=parser.parse_args(argv);runtime=args.koreader.resolve();source=args.source.resolve();candidate=args.candidate.resolve()
    if (sys.platform!='linux' or mock_only and (args.mock_port is None or args.allow_live)
            or args.mock_port is not None and not 1<=args.mock_port<=65535
            or (args.width,args.height,args.dpi)!=(1264,1680,300)
            or not (runtime/'luajit').is_file() or not candidate.is_file()
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('isolated Linux KOReader and tmpfs required')
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('guarded_native_worker/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=None;outcome='FAILED';workers_reaped=False;token=None;event=None;stage='input'
    try:
        payload=read_initial(sys.stdin.buffer)
        if (set(payload)!={'bundle','grant','cookies','months','token','armed'} or type(payload['armed']) is not bool
                or payload['armed'] and args.mock_port is None and not args.allow_live):
            raise ValueError('guarded_native_worker/input')
        token=payload['token'];bundle=payload['bundle'];grant=payload['grant'];plan=bundle['plan']
        if not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token):raise ValueError('guarded_native_worker/input')
        validate_evidence(plan,bundle['evidence']);validate_credentials(grant);validate_cookies(payload['cookies'],plan['owner'])
        validate_months(payload['months'])
        if grant['vid']!=plan['owner'] or plan['format']!='web_xhtml':raise ValueError('guarded_native_worker/owner')
        if args.mock_port is not None and (plan['owner']!='900000' or plan['book_id']!='900001'
                or grant['accessToken']!='mock-native-access' or grant['refreshToken']!='mock-native-refresh'
                or payload['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('guarded_native_worker/mock_scope')
        now=int(time.time())
        if now<plan['not_before'] or day(now)<=day(plan['start_time']):raise ValueError('guarded_native_worker/clock')
        stage='workspace';target=Path('/dev/shm/weread-native-time-'+token);os.mkdir(target,0o700);root=target
        profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
        check_candidate(source,candidate);extract_candidate(candidate,plugins)
        installed=check_installed(candidate,profile)
        if installed['bytes_match'] is not True or installed['files']!=check_candidate(source,candidate):
            raise ValueError('guarded_native_worker/candidate')
        epub,ledger=restore(bundle,root);relay=Relay(plan,root,epub)
        html=root/'synthetic.html';html.write_text('<html><body>'+'<p>Synthetic text for native UI.</p>'*120+'</body></html>')
        private={key:value for key,value in plan.items() if key!='archive_base64'}
        private.update(grant=grant,cookies=payload['cookies'],months=payload['months'],token=token,armed=payload['armed'])
        if args.mock_port is not None:private['mock_port']=args.mock_port
        env=dict(os.environ,KO_HOME=str(profile),TZ='Asia/Shanghai',LD_LIBRARY_PATH=str(runtime/'libs'),SDL_VIDEODRIVER='dummy',
                 EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                 EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
        for name in ('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy','WEREAD_CB_SYNTHETIC_DEBUG'):
            env.pop(name,None)
        command=[str(runtime/'luajit'),str(source/'spec/koreader/native_time_independent_ui_live.lua'),str(source),str(html),str(ledger),str(epub)]
        def emit(kind,value):
            raw=json.dumps(value,separators=(',',':')).encode()
            if len(raw)>3*1024*1024:raise ValueError('guarded_native_worker/frame')
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_'+kind.encode()+b'='+raw+b'\n');sys.stdout.buffer.flush()
        stage='ready';emit('STEP',dict(kind='ready',source=str(epub)))
        if read_reply(sys.stdin.buffer)!=dict(kind='ready',ok=True):raise ValueError('guarded_native_worker/denied')
        stage='worker';child=subprocess.Popen(command,cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,private);frames=Frames(child.stdout,token,timeout=120)
        claim_seen=False;ack_seen=False
        while True:
            kind,event=frames.next()
            if kind=='RESULT':break
            name=event.get('kind')
            if (name not in ('selection','claim','ack') or name=='claim' and claim_seen
                    or name=='ack' and (not payload['armed'] or not claim_seen or ack_seen)):
                raise ValueError('guarded_native_worker/order')
            if name=='claim':claim_seen=True
            if name=='ack':ack_seen=True
            offered=relay.prepare(event) if name=='claim' else event
            emit('STEP',offered);answer=read_reply(sys.stdin.buffer)
            if set(answer)!={'kind','ok'} or answer['kind']!=name or type(answer['ok']) is not bool:raise ValueError('guarded_native_worker/reply')
            if name=='claim' and not payload['armed'] and answer['ok']:
                reply(child.stdin,dict(kind='claim',ok=False));raise ValueError('guarded_native_worker/dry_approval')
            if name=='claim' and answer['ok']:
                try:relay.recheck()
                except ValueError:answer['ok']=False
            reply(child.stdin,answer)
        if (child.wait(timeout=10)!=0 or not claim_seen or event.get('result')!='PASS'
                or event.get('native_menu') is not True or event.get('background_service') is not True
                or event.get('local_phase')!=('none' if payload['armed'] else 'claimed')
                or ack_seen is not payload['armed'] or event.get('workers_reaped') is not True):
            raise ValueError('guarded_native_worker/worker')
        stop_reader(child);child=None;workers_reaped=True;outcome='ACKNOWLEDGED' if payload['armed'] else 'DRY_BLOCKED'
    except (Exception,KeyboardInterrupt) as error:
        if args.mock_port is not None and os.getenv('WEREAD_NATIVE_SYNTHETIC_DEBUG')=='1':
            safe={key:event.get(key) for key in ('result','failed_module','failed_line','task_kind','attempted','acknowledged','forwarded','local_phase')} if isinstance(event,dict) else None
            print(json.dumps({'stage':stage,'error_type':type(error).__name__,'worker':safe}),file=sys.stderr)
    finally:
        if child is not None:
            try:stop_reader(child);workers_reaped=True
            except Exception:workers_reaped=False
        if root is not None:shutil.rmtree(root,ignore_errors=True)
        removed=root is not None and not root.exists()
        if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
            value=dict(result=outcome,profile_removed=removed,workers_reaped=workers_reaped)
            raw=json.dumps(value,separators=(',',':')).encode()
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+raw+b'\n');sys.stdout.buffer.flush()
    return int(outcome not in ('ACKNOWLEDGED','DRY_BLOCKED') or not removed or not workers_reaped)


if __name__=='__main__':raise SystemExit(main())
