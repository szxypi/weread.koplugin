#!/usr/bin/env python3
"""Exercise the installed UI search probe on a synthetic shelf, both sizes."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from test_owner_shelf_search_ui import source
from verify_owner_shelf_search_ui import prepare

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    payload=prepare(source())
    with tempfile.TemporaryDirectory(prefix='owner-search-test-',dir='/dev/shm') as temp:
        candidate=Path(temp)/'candidate.zip'
        subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            cmd=['python3',str(REPO/'scripts/run_owner_shelf_search_ui.py'),'--koreader',str(args.koreader),
                 '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi),'--synthetic']
            result=subprocess.run(cmd,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,timeout=360)
            if result.returncode:raise RuntimeError(result.stdout.decode())
            assert json.loads(result.stdout)==dict(result='PASS',profile_removed=True,private_data_in_report=False,
                network_requests=0,books=3,group_books=2,queries=4,offline_reopen=True,installed_bytes_match=True)
            print(json.dumps(dict(result='PASS',width=width,height=height)))


if __name__=='__main__':main()
