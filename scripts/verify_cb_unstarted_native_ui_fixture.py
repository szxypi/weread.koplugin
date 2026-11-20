#!/usr/bin/env python3
"""Verify native first-sync UI after time-only reporting on a fresh TXT fixture.

Offline by default. The actual UI is first run with writes blocked; an exact
one-shot fixture claim then permits at most one position request. Uncertain
outcomes keep the fixture and are never replayed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from cb_txt_initial_fixture_plan import plan as position_plan
from cb_unstarted_position_fixture_flow import _baseline, _kind
from secure_native_session import NativeSessionStore, project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_initial_fixture_ui_trial import run_ui, ui_command
from verify_cb_reading import CbReadingProbe
from verify_cb_txt_fixture import Journal, MARKER, Receipt
from verify_cb_unstarted_time_fixture import run as time_fixture


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-unstarted-native-ui-' + name + '-v1',account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-unstarted-native-ui-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload')),Receipt(backend=backend('receipt')),
            Intent(backend=backend('time'),lock=lock('time')),Evidence(backend=backend('time-baseline'),lock=lock('time-baseline')),
            Intent(backend=backend('position'),lock=lock('position')),
            Evidence(backend=backend('position-baseline'),lock=lock('position-baseline')))


def ui_trial(context,report,grant,intent,evidence,command,*,runner=run_ui,attest=ui_command,fixture='txt'):
    if fixture=='epub':
        from cb_fixture_position import plan as planner
        from synthetic_upload_epub import TEXT as marker
        from verify_cb_initial_fixture_ui_trial import xhtml_summary as summarize
        source_format='web_xhtml';version=context.get('version')
        if type(version) is not int or version<=0:raise ValueError('unstarted_native/version')
    elif fixture=='txt':
        planner=position_plan;marker=MARKER;source_format='web_txt';version=0
        summarize=lambda sample,plan:PlainSource(sample['source']).excerpt(plan['first'])['text']
    else:raise ValueError('unstarted_native/format')
    if intent.backend.load() is not None or evidence.backend.load() is not None:
        raise ValueError('unstarted_native/consumed')
    owner,target_id=context['owner'],context['target']
    def source():
        if not context['authority']() or not context['shelf_current']():raise ValueError('unstarted_native/owner')
        web=context['connect'](CbReadingProbe,target_id)
        try:
            sample=web.inspect(target_id);web.verify_account()
            if (sample.get('book_id')!=target_id or sample.get('source_format')!=source_format
                    or sample.get('source_raw_sha256')!=context['source_hash'] or marker not in sample.get('source','')
                    or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                    or not all(web.last_checks.values())):raise ValueError('unstarted_native/source')
            context['persist'](web);return sample
        finally:web.samples.clear();web.close()
    sample=source();plan=planner(target_id,sample)
    summary=summarize(sample,plan)
    expected=dict(book=target_id,chapter=plan['chapter'],index=plan['index'],offset=plan['first'],percent=None,summary=summary)
    def pair():return context['pair'](sample['chapters'])
    before=_baseline(pair());stats=context['stats']()
    if _baseline(pair())!=before or context['stats']()!=stats:raise ValueError('unstarted_native/unstable')
    chapters=[]
    for row in sample['chapters']:
        item=dict(row)
        if type(item.get('wordCount')) not in (int,float) or item['wordCount']<=0:item['wordCount']=1000
        chapters.append(item)
    payload=dict(book=target_id,chapter=plan['chapter'],chapter_idx=plan['index'],offset=plan['first'],expected_summary=summary,
                 source=sample['source'],source_format=source_format,chapters=chapters,book_version=version,
                 owner=owner,cookies=context['cookies'](),native=grant,armed=False)
    if attest()!=command or not runner(command,payload):raise ValueError('unstarted_native/preview')
    report['native_dry_run_verified']=True
    if (_baseline(pair())!=before or context['stats']()!=stats or not context['authority']()
            or not context['shelf_current']() or attest()!=command):raise ValueError('unstarted_native/changed')
    again=source();current_plan=planner(target_id,again)
    if any(current_plan[k]!=plan[k] for k in ('book','chapter','index','first')):raise ValueError('unstarted_native/source_changed')
    snapshot=dict(source=context['source_hash'],position=before['web']['projection'],updated_at=context['latest']['updated'],
                  counters={k:before['native']['counters'][k]['value'] for k in ('readingTime','recordReadingTime','ttsTime')},
                  stats=stats,body=dict(kind='native_first_position',elapsed_seconds=0))
    evidence.save(dict(schema=1,owner_sha256=hashlib.sha256(owner.encode()).hexdigest(),
        book_sha256=hashlib.sha256(target_id.encode()).hexdigest(),attempt=context['attempt'],baseline=snapshot))
    reservation=intent.reserve(owner,target_id,context['attempt'],hashlib.sha256(canonical(snapshot)).hexdigest())
    permit=intent.claim(reservation)
    if (not intent.verify(reservation,permit) or not context['authority']() or not context['shelf_current']()
            or _baseline(pair())!=before or context['stats']()!=stats or attest()!=command):raise ValueError('unstarted_native/changed')
    payload.update(cookies=context['cookies'](),armed=True)
    report['position_posts']=None;report['position_write_uncertain']=True
    if not runner(command,payload):raise ValueError('unstarted_native/ui')
    report['position_posts']=1
    previous=None
    for _ in range(2):
        found=pair()
        # UI-derived percentage is authoritative, and must agree in both channels.
        native_state,web_state=found['native']['state'],found['web']['state']
        percent=native_state.get('raw_percent') if isinstance(native_state,dict) else None
        if type(percent) not in (int,float) or percent%1 or not 0<=percent<=100 or web_state.get('raw_percent')!=percent:
            raise ValueError('unstarted_native/percent')
        expected['percent']=percent
        if _kind(found,before,expected)!='target' or context['stats']()!=stats:
            raise ValueError('unstarted_native/readback')
        if previous is not None and previous!=found:raise ValueError('unstarted_native/readback')
        previous=found
    final=source()
    if final['chapters']!=sample['chapters'] or not intent.verify(reservation,permit):
        raise ValueError('unstarted_native/source_changed')
    report['position_write_uncertain']=False
    return dict(result='PASS',attempted=1,write_uncertain=False,cleanup_allowed=True,
                target_verified=True,counters_preserved=True,statistics_preserved=True,offline_reopen=True)


def execute(saved,session,native,grant,journal,receipt,time_intent,time_evidence,position_intent,position_evidence,command,*,apply=False,**kwargs):
    if position_intent.backend.load() is not None or position_evidence.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,position_write_uncertain=False)
    def after(context,report):return ui_trial(context,report,grant,position_intent,position_evidence,command,fixture=kwargs.get('fixture','txt'))
    result=time_fixture(saved,session,native,grant,journal,receipt,time_intent,time_evidence,apply=apply,after_time=after,**kwargs)
    if (result.get('result')=='UNSTARTED_TIME_FIXTURE_VERIFIED' and result.get('position_probe',{}).get('result')=='PASS'):
        result['result']='UNSTARTED_TIME_NATIVE_UI_VERIFIED'
    elif result.get('result')=='UNSTARTED_TIME_FIXTURE_VERIFIED':result['result']='UNVERIFIED'
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        command=ui_command();session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),command,apply=args.apply)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,position_write_uncertain=args.apply,
                    authentication_posts=0,fixture_only=True,private_data_in_report=False)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result));return int(result['result'] not in ('READ_ONLY_PREVIEW','UNSTARTED_TIME_NATIVE_UI_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
