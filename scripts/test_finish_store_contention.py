#!/usr/bin/env python3
"""Compare synthetic journal reads during concurrent shelf-cache writes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--run-dir',type=Path,required=True)
    parser.add_argument('--pairs',type=int,default=3,choices=range(1,11))
    parser.add_argument('--kind',choices=('finish_journal','private_journal','finish_queue','membership_queue'),default='finish_journal')
    args=parser.parse_args()
    runtime=args.koreader.resolve();baseline=args.baseline.resolve();candidate=args.candidate.resolve()
    root=args.run_dir.resolve();root.mkdir(parents=True,exist_ok=False)
    probe=Path(__file__).resolve().parent.parent/'spec/koreader/finish_store_contention_probe.lua'
    stores={'finish_journal':'finish_change_store.lua','private_journal':'shelf_flag_change_store.lua',
        'finish_queue':'finish_queue_store.lua','membership_queue':'membership_queue_store.lua'}
    report={'result':'UNVERIFIED','synthetic_only':True,'kind':args.kind,'pairs':[],
        'baseline_sha256':digest(baseline/'weread/lib'/stores[args.kind]),
        'candidate_sha256':digest(candidate/'weread/lib'/stores[args.kind]),
        'probe_sha256':digest(probe),'profiles_removed':False}
    shared=candidate/'weread/lib/account_store_read.lua'
    if shared.is_file():report['candidate_shared_sha256']=digest(shared)
    temporary=None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-contention-',dir='/dev/shm') as temporary:
            for index in range(args.pairs):
                pair={}
                for name,source in (('baseline',baseline),('candidate',candidate)):
                    profile=Path(temporary)/f'{name}-{index}'
                    process=subprocess.run([str(runtime/'luajit'),str(probe),str(source),str(profile),'stress',args.kind],cwd=runtime,
                        stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120,check=False)
                    if process.returncode:raise ValueError(f'{name} probe failed')
                    values=json.loads(process.stdout.splitlines()[-1]);pair[name]=values
                    if values.get('success',-1)+values.get('storage',-1)!=5000 or values.get('concurrent_saves',0)<1:
                        raise ValueError(f'{name} probe incomplete')
                report['pairs'].append(pair)
            report['result']='PASS' if all(pair['candidate']['storage']==0 for pair in report['pairs']) else 'UNVERIFIED'
    except (OSError,ValueError,subprocess.TimeoutExpired,json.JSONDecodeError) as exc:
        report['failure']=type(exc).__name__
    finally:
        report['profiles_removed']=temporary is not None and not Path(temporary).exists()
        (root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
    return int(report['result']!='PASS' or not report['profiles_removed'])


if __name__=='__main__':
    raise SystemExit(main())
