#!/usr/bin/env python3
"""Synthetic-only native queue selection parity; default has no side effects."""
import argparse,json,subprocess
from native_time_bundle_selection import expected,validate_selection
from test_native_time_capture_evidence import bundle,make_fixture


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv);report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0}
    try:
        if args.lua_command:
            p,l,c=make_fixture();value={'plan':p,'evidence':bundle(l,c)};l.close();c.close()
            selection=expected(value)
            payload={'owner':p['owner'],'book_id':p['book_id'],'rows':selection['rows'],'parts':selection['parts'],'now':p['not_before']+1}
            child=subprocess.run(args.lua_command,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
            if child.returncode or len(child.stdout)>65536:raise ValueError('bundle_selection/lua')
            native=json.loads(child.stdout)
            if not isinstance(native,dict) or set(native)!={'result','selection'} or native['result']!='PASS':raise ValueError('bundle_selection/lua')
            validate_selection(value,native['selection'])
            report.update(result='SYNTHETIC_NATIVE_SELECTION_VERIFIED',source_and_intervals_exact=True,native_hashes_match=True,synthetic_only=True)
    except Exception:report['result']='UNVERIFIED'
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
