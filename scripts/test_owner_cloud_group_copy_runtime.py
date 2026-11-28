#!/usr/bin/env python3
"""Two-size installed UI acceptance using only synthetic shelf data."""
import argparse,json,subprocess,tempfile
from pathlib import Path

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    payload=dict(books=[dict(bookId='101',title='合成一'),dict(bookId='102',title='合成二')],
        archives=[dict(archiveId=7,name='合成组一',bookIds=['101','missing','MP_WXS_2']),
                  dict(archiveId=8,name='合成空组',bookIds=[])],
        expected=[dict(label='合成组一',members=['101','missing']),dict(label='合成空组',members=[])])
    with tempfile.TemporaryDirectory(prefix='owner-copy-test-',dir='/dev/shm') as temp:
        candidate=Path(temp)/'candidate.zip'
        subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            cmd=['python3',str(REPO/'scripts/run_owner_cloud_group_copy.py'),'--koreader',str(args.koreader),
                 '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi),'--synthetic']
            result=subprocess.run(cmd,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,timeout=360)
            if result.returncode:raise RuntimeError(result.stdout.decode())
            assert json.loads(result.stdout)==dict(result='PASS',profile_removed=True,private_data_in_report=False,
                network_requests=0,groups=2,offline_reopen=True)
            print(json.dumps(dict(result='PASS',width=width,height=height)))


if __name__=='__main__':main()
