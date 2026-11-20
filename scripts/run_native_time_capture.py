#!/usr/bin/env python3
"""Private native-statistics capture runner, confined to a disposable tmpfs."""
import argparse,base64,json,os,re,resource,signal,sys,tempfile
from pathlib import Path
from run_persistent_ui_probe import extract_candidate,run_child
from run_owner_reading_probe import check_installed
from verify_owner_reading import FRAME,PHASES,validate_stage,validate_cookies
from native_time_capture import validate,hashed,MAX_ARCHIVE


def payload_valid(p,mock_port=None,*,imported=False,cb_mock_port=None):
    if not isinstance(p,dict) or p.get('source_format') not in ('web_txt','web_xhtml') or not isinstance(p.get('native_time_capture'),dict):raise ValueError('native_capture/input')
    flag=p.get('cb_reading')
    if (type(imported) is not bool or flag is not None and flag is not True or (flag is True)!=imported
            or imported and p['source_format']!='web_xhtml'):raise ValueError('native_capture/input')
    from verify_cb_progress import cb_id
    if imported and not cb_id(p.get('book_id')) or not imported and cb_id(p.get('book_id')):raise ValueError('native_capture/input')
    cfg=p['native_time_capture']
    if (set(cfg)!={'device_sha256','baseline_sha256','book_version'} or not hashed(cfg['device_sha256']) or not hashed(cfg['baseline_sha256'])
            or type(cfg['book_version']) is not int or not 1<=cfg['book_version']<=2147483647
            or any(k in p for k in ('native_grant','native_source_excerpt','selection_preview','source_upload_preview','full_manifest','annotations','progress_preview','progress_roundtrip','selection_trial','native_reader_trial','native_initial_reader',
                                'native_timer_trial','native_close_trial','native_recovery','raw_cloud_preview','initial_plan_preview','unstarted_preview'))):raise ValueError('native_capture/input')
    validate_cookies(p['cookies'],p['vid'])
    if p.get('time_capture_mock_port')!=mock_port:raise ValueError('native_capture/mock')
    if p.get('cb_mock_port')!=cb_mock_port or cb_mock_port is not None and (not imported or mock_port is not None
            or p['vid']!='900000' or p['book_id']!='CB_SyntheticResume' or p['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('native_capture/mock')
    if mock_port is not None and (p['vid']!='900000' or p['book_id']!='900001' or p['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('native_capture/mock')
    return p


def decode(raw,payload,*,imported=False):
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024 or raw.count(FRAME)!=1:raise ValueError('native_capture/frame')
    envelope=json.loads(raw.split(FRAME)[1]);stage=envelope['report'];addon=stage.pop('native_time_capture')
    validate_stage(stage,'live',cb_reading=imported)
    if stage['result']!='PASS':raise ValueError('native_capture/reader')
    flags={'real_statistics','actual_clock','exact_source','ledger_reopened','same_day_deferred'}
    if (not isinstance(addon,dict) or set(addon)!=flags|{'phase','seconds','rows','archive_bytes','failed_line'}
            or addon['phase']!='complete' or type(addon['failed_line']) is not int or addon['failed_line']!=0 or any(addon[k] is not True for k in flags)
            or any(type(addon[k]) is not int or not low<=addon[k]<=high for k,low,high in (('seconds',5,12),('rows',1,12),('archive_bytes',1,MAX_ARCHIVE)))):
        raise ValueError('native_capture/stage')
    captured=validate(envelope['candidate_private'],imported=imported);cfg=payload['native_time_capture']
    if (any(captured[k]!=payload[k] for k in ('book_id','chapter_uid')) or captured['owner']!=payload['vid']
            or captured['format']!=payload['source_format'] or captured['raw_sha256']!=payload['source_raw_sha256'] or captured['book_version']!=cfg['book_version']
            or captured['device_sha256']!=cfg['device_sha256'] or captured['baseline_sha256']!=cfg['baseline_sha256'] or captured['seconds']!=addon['seconds']
            or len(captured['rows'])!=addon['rows'] or len(base64.b64decode(captured['archive_base64']))!=addon['archive_bytes']):raise ValueError('native_capture/binding')
    return stage,addon,captured,validate_cookies(envelope['cookies'],payload['vid'])


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--mock-port',type=int);parser.add_argument('--cb-mock-port',type=int)
    parser.add_argument('--cb-reading',action='store_true');parser.add_argument('--sqlite-evidence',action='store_true');args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or any(not 1<=n<=4096 for n in (args.width,args.height,args.dpi))
            or args.mock_port is not None and not 1<=args.mock_port<=65535
            or args.cb_mock_port is not None and (not args.cb_reading or not 1<=args.cb_mock_port<=65535 or args.mock_port is not None)):
        parser.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_s,_f):raise ValueError('native_capture/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    root=None;result=dict(result='UNVERIFIED',profile_removed=False,account_data_posts=0,authentication_posts=0,cookies={},capture=None)
    try:
        raw=sys.stdin.buffer.read(256*1024+1)
        if len(raw)>256*1024:raise ValueError('native_capture/input')
        payload=payload_valid(json.loads(raw),args.mock_port,imported=args.cb_reading,cb_mock_port=args.cb_mock_port);result['cookies']=payload['cookies']
        with tempfile.TemporaryDirectory(prefix='weread-reading-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),TZ='Asia/Shanghai',LD_LIBRARY_PATH=str(runtime/'libs'),
                     EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
                     EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi))
            folder=Path(__file__).resolve().parent.parent/'spec/koreader'
            code,out,repaint=run_child([str(runtime/'luajit'),str(folder/'owner_reading_probe.lua'),'live',str(folder/'owner_native_time_capture_case.lua')],env,raw,runtime,timeout=180)
            # Preserve only typed diagnostics; never emit raw child logs.
            if code or repaint:
                if out.count(FRAME)==1:
                    diagnostic=json.loads(out.split(FRAME)[1]).get('report',{})
                    result['diagnostic']={'phase':diagnostic.get('phase') if diagnostic.get('phase') in PHASES else 'other'}
                    for key,maximum in (('failed_line',10000),('last_http_status',599),('denied_kind',1024),('denied_route',1024),('denied_flags',1024)):
                        value=diagnostic.get(key)
                        if type(value) is int and 0<=value<=maximum:result['diagnostic'][key]=value
                    addon=diagnostic.get('native_time_capture',{})
                    value=addon.get('failed_line');result['capture_failed_line']=value if type(value) is int and 0<=value<=10000 else 0
                raise ValueError('native_capture/reader')
            stage,addon,captured,cookies=decode(out,payload,imported=args.cb_reading)
            evidence=None
            if args.sqlite_evidence:
                from native_time_sqlite_snapshot import take
                evidence=take(profile,root,captured,imported=args.cb_reading)
            result.update(result='PASS',stage=stage,native_capture=addon,capture=captured,cookies=cookies,
                          installed=check_installed(args.candidate,profile))
            if args.sqlite_evidence:result['sqlite_evidence']=evidence
    except Exception as error:
        result['failure_type']=type(error).__name__ if type(error).__name__ in ('ValueError','KeyError','AssertionError','TypeError') else 'other'
        if isinstance(error,ValueError) and re.fullmatch(r'(?:native_capture|capture_snapshot|capture_evidence)/[a-z_]+',str(error)):result['failure_reason']=str(error)
    finally:result['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(b'\nWEREAD_NATIVE_TIME_CAPTURE_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n')
    return int(result['result']!='PASS' or not result['profile_removed'])

if __name__=='__main__':raise SystemExit(main())
