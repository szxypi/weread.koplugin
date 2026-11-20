#!/usr/bin/env python3
"""Exercise the native time menu and readback against a synthetic loopback service."""
import argparse,json,os,traceback
from pathlib import Path
from verify_native_time_independent_ui_mock import scenario


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('koreader','source','candidate'):parser.add_argument('--'+name,required=True,type=Path)
    args=parser.parse_args()
    try:
        modes=('dry','malicious_approval','success_readback','source_changed','position_changed',
               'missing_ack','archive_changed','interrupted','host_success')
        for mode in modes:scenario(args,mode,live=True)
        report=dict(result='SYNTHETIC_INDEPENDENT_UI_TRANSFER_VERIFIED',scenarios=len(modes),real_account_posts=0,
                    synthetic_posts=3,native_menu=True,independent_readback_verified=True,full_host_sequence_verified=True,
                    uncertain_claims_not_replayed=True,physical_kindle_tested=False)
    except Exception as error:
        if os.getenv('WEREAD_NATIVE_SYNTHETIC_DEBUG')=='1':traceback.print_exc()
        report=dict(result='UNVERIFIED',failure_type=type(error).__name__)
        if isinstance(error,ValueError) and str(error).startswith('independent_mock/result '):
            report['diagnostic']=json.loads(str(error).removeprefix('independent_mock/result '))
    print(json.dumps(report));return int(report['result']!='SYNTHETIC_INDEPENDENT_UI_TRANSFER_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
