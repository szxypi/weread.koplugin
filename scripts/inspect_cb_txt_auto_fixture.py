#!/usr/bin/env python3
"""Read-only recovery diagnosis for the interrupted TXT auto-sync fixture."""
import argparse
import hashlib
import json
import resource
import subprocess
from urllib.parse import urlencode

from cb_cloud_position import observed, state
from cb_existing_position_intent import digest
from cb_txt_initial_fixture_plan import plan
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical
from secure_weread_session import SessionStore
from verify_cb_initial_fixture_trial import NativeRead, SourceRead
from verify_cb_initial_fixture_ui_trial import ui_command
from verify_cb_fixture_highlight_trial import ScopedNative as NotesProbe
from verify_cb_txt_auto_fixture_ui_trial import stores
from verify_cb_txt_fixture import MARKER, check_plan
from verify_cb_txt_initial_fixture_ui_trial import summary
from verify_eink_login import BASE
from verify_personal_upload_trial import Probe as UploadProbe


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=None;phase='session'
    try:
        session=SessionStore();saved=session.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
        phase='binding';journal,receipt,intent,timer,close=stores();upload,token=journal.read()
        if not upload or upload['phase']!='imported' or upload['plan']['owner']!=owner:raise ValueError('scope')
        target=upload['target'];expected=canonical(dict(schema=1,owner=owner,attempt=upload['attempt'],target=target,
                                                       plan_sha256=hash_value(upload['plan'])))
        if receipt.backend.load()!=expected or timer.backend.load() is not None or close.backend.load() is not None:raise ValueError('scope')
        reservation=json.loads(intent.backend.load())
        if (set(reservation)!={'schema','scope','owner','book','attempt','baseline','claimed'}
                or reservation['schema']!=1 or reservation['owner']!=digest(owner) or reservation['book']!=digest(target)
                or reservation['attempt']!=upload['attempt'] or reservation['claimed']!=0):raise ValueError('scope')
        def current():return native_store.load(owner)==grant and journal.read()==(upload,token)
        phase='shelf';native=UploadProbe(journal,lambda value:current() and value==grant)
        shelf=native.shelf(grant);check_plan(upload['plan'],grant,shelf,target,True)
        if any(str(item)==target for group in shelf.get('archive',[]) for item in group.get('bookIds',[])):raise ValueError('scope')
        phase='source';web=SourceRead();web.vid=owner;web.book_id=target;web.allowed={target}
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();sample=web.inspect(target);web.verify_account()
        if sample['source_format']!='web_txt' or MARKER not in sample['source']:raise ValueError('source')
        candidate=plan(target,sample);fingerprint=hashlib.sha256((sample['source_raw_sha256']+':'+str(candidate['first'])).encode()).hexdigest()
        if reservation['baseline']!=fingerprint:raise ValueError('source')
        phase='position';raw=NativeRead(grant,target).request('first_progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=target)),credentials=grant)
        point=state(raw,target,sample['chapters'],'native')
        counts=observed(raw,target,sample['chapters'],'native')['counters']
        if (point.get('kind')!='no_chapter' or any(not counts[k]['present'] or type(counts[k]['value']) is not int
                or counts[k]['value']!=0 for k in ('readingTime','recordReadingTime','ttsTime'))):raise ValueError('position')
        phase='notes';notes=NotesProbe(target,grant,current,None).observe(grant)
        if notes['marks']['updated']!={} or notes['marks']['chapters']!={} or notes['thoughts']!={}:raise ValueError('notes')
        chapters=[]
        for row in sample['chapters']:
            item=dict(row)
            if type(item.get('wordCount')) not in (int,float) or item['wordCount']<=0:item['wordCount']=1000
            chapters.append(item)
        payload=dict(book=target,chapter=candidate['chapter'],chapter_idx=candidate['index'],offset=candidate['first'],
            expected_summary=summary(sample,candidate),source=sample['source'],source_format='web_txt',chapters=chapters,
            book_version=0,owner=owner,cookies=saved['cookies'],native=grant,armed=False)
        if not current():raise ValueError('stale')
        phase='dry';child=subprocess.run(ui_command(),input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL,timeout=780)
        value=json.loads(child.stdout) if len(child.stdout)<=65536 else {}
        report.update(result='DIAGNOSED',fixture_bound=True,position_unstarted=True,notes_empty=True,claimed=0,
                      dry_result=value.get('result') if value.get('result') in ('DRY_RUN','UNVERIFIED') else 'UNKNOWN',
                      profile_removed=value.get('profile_removed') is True)
        if value.get('failure_phase') in ('decode','prepare','choice','upload','reopen'):report['failure_phase']=value['failure_phase']
        if type(value.get('failure_line')) is int:report['failure_line']=value['failure_line']
        for key in ('dry_notice_unconfirmed','dry_zero_writes','dry_one_denied','dry_not_verified',
                    'dry_pending_position','dry_pending_dispatch'):
            if type(value.get(key)) is bool:report[key]=value[key]
        for key in ('dry_denied_count','dry_denied_writes','dry_denied_other','dry_denied_bookmarks'):
            if type(value.get(key)) is int and 0<=value[key]<=10:report[key]=value[key]
    except Exception:
        report.update(result='UNVERIFIED',phase=phase)
    finally:
        if web:web.samples.clear();web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return 0 if report['result']=='DIAGNOSED' else 1


if __name__=='__main__':raise SystemExit(main())
