#!/usr/bin/env python3
"""Actual TXT bookReader -> parent-owned background excerpt -> offline reopen.

No apply/renewal mode or native account grant. Source and credentials stay in
captured pipes, with book/profile files confined to the Linux runner's tmpfs.
"""
import argparse
from datetime import datetime,timezone
import json
import resource
import subprocess
from secure_weread_session import SessionStore
from verify_owner_reading import TxtReadingPreflight,reading_position
from verify_web_source_progress import BASE
from verify_translation_preflight import save_refreshed_web_session
from owner_native_excerpt_contract import decode,compare
from verify_cb_progress import cb_id


class Preflight(TxtReadingPreflight):
    """Include independently observed CB_ shelf display GETs in the UI scope."""
    def __init__(self):
        super().__init__();self.display_ids=[]

    def request(self,stage,url,body=None,**options):
        value=super().request(stage,url,body,**options)
        if stage=='shelf':
            rows=value.get('books') if isinstance(value,dict) else None
            if not isinstance(rows,list) or len(rows)>5000:raise ValueError('native_excerpt/shelf')
            self.display_ids=list(dict.fromkeys(row['bookId'] for row in rows if isinstance(row,dict) and cb_id(row.get('bookId'))))
        return value

    def prepare(self):
        value=super().prepare()
        value['shelf_ids']=list(dict.fromkeys(value['shelf_ids']+self.display_ids))
        return value


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.saved_session!=bool(a.lua_command):p.error('pair saved session and private native command')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,screenshots=0,private_data_on_regular_disk=False,production_upload_enabled=False)
    saved=web=payload=envelope=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            store=SessionStore();saved=store.load();web=Preflight();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();payload=web.prepare();raw=web.sample['plain']
            web.verify_account();save_refreshed_web_session(store,saved,web);saved=store.load()
            payload.update(vid=web.vid,cookies=saved['cookies'],native_source_excerpt=True)
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:raise ValueError('native_excerpt/input')
            child=subprocess.run(a.lua_command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=420)
            envelope=decode(child.stdout,web.vid);report['ui']=envelope['report']
            web.cookies.clear()
            for key,value in envelope['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id),web.book_id,allow_unstarted=True)
            report['cloud_position_unchanged']=after==web.baseline
            save_refreshed_web_session(store,saved,web)
            if child.returncode or report['ui']['result']!='PASS' or not report['cloud_position_unchanged']:raise ValueError('native_excerpt/ui')
            compare(envelope['candidate_private'],raw,payload)
            report.update(result='OWNER_NATIVE_TXT_EXCERPTS_VERIFIED',excerpts_compared=6,independent_python_source_match=True,
                          fresh_offline_process=True,official_summary_rule_verified=False)
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        if web:
            report['stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.shards.clear();web.close()
        for value in (saved,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
