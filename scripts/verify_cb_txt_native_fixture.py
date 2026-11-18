#!/usr/bin/env python3
"""Import one synthetic multi-page TXT and verify the native reader, once.

The short TXT trial and old group trial remain separate immutable scopes.
All real account inputs and reader data pass through memory and Linux tmpfs.
"""
import argparse
import contextlib
import hashlib
import io
import json
import re
import resource
import tempfile
from pathlib import Path

from cloud_group_nonempty_journal import Journal as GroupJournal
from personal_upload_trial import Journal as BaseJournal, check, hash_value, projection, validate
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_progress import cb_id, cb_ids
from verify_cb_reading import BASE, CbReadingProbe
from verify_cb_native_reading import main as native_main
from verify_cb_txt_fixture import (BODY as SINGLE_BODY, MARKER, Journal as PreviousJournal, Receipt as PreviousReceipt,
                                   Receipt, guarded_previous, validate_plan as validate_single_plan)
from verify_eink_login import NativeProbe
from verify_owner_reading import PHASES
from verify_personal_upload_trial import Probe
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import run
from verify_translation_preflight import save_refreshed_web_session

BODY = (MARKER + '\n' + ''.join(
    f'{i:04d} This is an original synthetic paragraph for native reading validation. '
    'The reader should preserve this text while moving across pages and reopening offline.\n'
    for i in range(1, 241))).encode('utf-8')
BODY_HASH = hashlib.sha256(BODY).hexdigest()
SHORT_BODY = (MARKER + '\n' + ''.join(f'{i:04d} x\n' for i in range(1,241))).encode('utf-8')
SHORT_HASH = hashlib.sha256(SHORT_BODY).hexdigest()


def validate_plan(plan):
    validate(plan)
    if plan['body_sha256'] != BODY_HASH: raise ValueError('cb_txt_native/fixture')
    return plan


def prepare_plan(credentials, shelf, name):
    data = projection(shelf); data.pop('present')
    return validate_plan(dict(owner=credentials['vid'], name=name, body_sha256=BODY_HASH,
                              grant_sha256=hash_value(credentials), **data))


def check_plan(plan, credentials, shelf, target=None, expected=False):
    return check(plan, credentials, shelf, target, expected, validator=validate_plan)


class Journal(BaseJournal):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service='org.codex.weread.goal-cb-txt-native-fixture-v1', account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-txt-native-fixture-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend=backend, lock=lock, validator=validate_plan)


def validate_short_plan(plan):
    validate(plan)
    if plan['body_sha256'] != SHORT_HASH: raise ValueError('cb_txt_native/fixture')
    return plan


def prepare_short_plan(credentials, shelf, name):
    data=projection(shelf);data.pop('present')
    return validate_short_plan(dict(owner=credentials['vid'],name=name,body_sha256=SHORT_HASH,
                                    grant_sha256=hash_value(credentials),**data))


def check_short_plan(plan,credentials,shelf,target=None,expected=False):
    return check(plan,credentials,shelf,target,expected,validator=validate_short_plan)


class ShortJournal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-cb-txt-native-short-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-txt-native-short-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_short_plan)


def prepare_single_plan(credentials,shelf,name):
    data=projection(shelf);data.pop('present')
    return validate_single_plan(dict(owner=credentials['vid'],name=name,body_sha256=hashlib.sha256(SINGLE_BODY).hexdigest(),
                                     grant_sha256=hash_value(credentials),**data))


def check_single_plan(plan,credentials,shelf,target=None,expected=False):
    return check(plan,credentials,shelf,target,expected,validator=validate_single_plan)


class SingleJournal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-cb-txt-native-single-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-cb-txt-native-single-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_single_plan)


def previous_txt():
    state, token = PreviousJournal().read(); raw = PreviousReceipt().backend.load()
    value = json.loads(raw) if isinstance(raw, bytes) and len(raw) <= 8192 else None
    if (not state or state['phase'] != 'restored' or not isinstance(value, dict)
            or set(value) != {'schema','owner','attempt','target','plan_sha256'} or value['schema'] != 1
            or value['owner'] != state['plan']['owner'] or value['attempt'] != state['attempt']
            or value['target'] != state['target'] or value['plan_sha256'] != hash_value(state['plan'])
            or not cb_id(state['target'])):
        raise ValueError('cb_txt_native/previous')
    return state, token, raw


def previous_native():
    state,token=Journal().read()
    raw=Receipt(MacKeychain(service='org.codex.weread.goal-cb-txt-native-target-v1',account=ACCOUNT)).backend.load()
    value=json.loads(raw) if isinstance(raw,bytes) and len(raw)<=8192 else None
    if (not state or state['phase']!='restored' or not isinstance(value,dict)
            or set(value)!={'schema','owner','attempt','target','plan_sha256'} or value['schema']!=1
            or value['owner']!=state['plan']['owner'] or value['attempt']!=state['attempt']
            or value['target']!=state['target'] or value['plan_sha256']!=hash_value(state['plan'])
            or not cb_id(state['target'])):raise ValueError('cb_txt_native/previous')
    return state,token,raw


def previous_native_short():
    state,token=ShortJournal().read()
    raw=Receipt(MacKeychain(service='org.codex.weread.goal-cb-txt-native-short-target-v1',account=ACCOUNT)).backend.load()
    value=json.loads(raw) if isinstance(raw,bytes) and len(raw)<=8192 else None
    if (not state or state['phase']!='restored' or not isinstance(value,dict)
            or set(value)!={'schema','owner','attempt','target','plan_sha256'} or value['schema']!=1
            or value['owner']!=state['plan']['owner'] or value['attempt']!=state['attempt']
            or value['target']!=state['target'] or value['plan_sha256']!=hash_value(state['plan'])
            or not cb_id(state['target'])):raise ValueError('cb_txt_native/previous')
    return state,token,raw


def command(candidate, width, height, dpi):
    if (not isinstance(candidate, str) or not re.fullmatch(r'/validation/cb-dry-candidate-[a-f0-9]{64}\.zip',candidate)
            or (width,height,dpi) not in ((600,800,167),(1264,1680,300))):
        raise ValueError('cb_txt_native/command')
    return ['docker','exec','-i','-w','/source','-e','LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs',
            '-e','SDL_VIDEODRIVER=dummy','weread-validation','timeout','--signal=TERM','--kill-after=10','340',
            'python3','scripts/run_owner_reading_probe.py','--koreader','/validation/runtime/lib/koreader',
            '--candidate',candidate,'--width',str(width),'--height',str(height),'--dpi',str(dpi),'--cb-reading']


def verify_native(target, candidate, size, *, store=None, probe_factory=CbReadingProbe, reader=native_main, diagnostics=None,single_page=False):
    if not cb_id(target): raise ValueError('cb_txt_native/target')
    if type(single_page) is not bool:raise ValueError('cb_txt_native/scope')
    store = store or SessionStore(); saved = probe = None
    try:
        saved = store.load(); probe = probe_factory(); probe.vid = saved['vid']
        for key, value in saved['cookies'].items(): probe.set_cookie(key,value)
        probe.verify_account(); ids = cb_ids(probe.request('shelf',BASE+'/web/shelf/sync')); probe.verify_account()
        if target not in ids: raise ValueError('cb_txt_native/target')
        save_refreshed_web_session(store,saved,probe)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cmd=command(candidate,*size)+(['--cb-single-page'] if single_page else [])
            code = reader(['--saved-session','--book-index',str(ids.index(target)+1),'--lua-command',
                           *cmd],expected_book_id=target,expected_source_text=MARKER,**({'single_page':True} if single_page else {}))
        if len(output.getvalue()) > 1024*1024: raise ValueError('cb_txt_native/report')
        report = json.loads(output.getvalue())
        if diagnostics is not None and isinstance(report,dict):
            diagnostics['native_result']=report.get('result') if report.get('result') in ('CB_NATIVE_READING_VERIFIED','CB_NATIVE_SINGLE_PAGE_READING_VERIFIED','UNVERIFIED') else 'invalid'
            diagnostics['source_format']=report.get('source_format') if report.get('source_format') in ('web_txt','web_xhtml') else 'unavailable'
            diagnostics['checks']={key:report.get(key) is True for key in
                ('same_owner_verified','source_text_matched','fresh_offline_process','cloud_position_unchanged')}
            diagnostics['checks'].update(account_data_posts_zero=type(report.get('account_data_posts')) is int and report['account_data_posts']==0,
                authentication_posts_zero=type(report.get('authentication_posts')) is int and report['authentication_posts']==0,
                no_private_disk=report.get('private_data_on_regular_disk') is False,
                screenshots_zero=type(report.get('screenshots')) is int and report['screenshots']==0)
            ui=report.get('ui')
            if isinstance(ui,dict):
                diagnostics['ui_result']=ui.get('result') if ui.get('result') in ('PASS','UNVERIFIED') else 'invalid'
                stages=ui.get('stages') if isinstance(ui.get('stages'),list) else []
                diagnostics['stages']=[dict(phase=row.get('phase') if row.get('phase') in PHASES else 'other',
                    failed_line=row.get('failed_line') if type(row.get('failed_line')) is int and 0<=row['failed_line']<=10000 else 0)
                    for row in stages[:2] if isinstance(row,dict)]
        expected='CB_NATIVE_SINGLE_PAGE_READING_VERIFIED' if single_page else 'CB_NATIVE_READING_VERIFIED'
        if (code != 0 or report.get('result') != expected or report.get('source_format') != 'web_txt'
                or single_page and (report.get('page_turn_tested') is not False or not isinstance(report.get('ui'),dict)
                    or not isinstance(report['ui'].get('stages'),list) or len(report['ui']['stages'])!=2
                    or any(not isinstance(row,dict) or type(row.get('pages')) is not int or row['pages']!=1 for row in report['ui']['stages']))
                or any(report.get(key) is not True for key in ('same_owner_verified','source_text_matched','fresh_offline_process','cloud_position_unchanged'))
                or type(report.get('account_data_posts')) is not int or report['account_data_posts'] != 0
                or type(report.get('authentication_posts')) is not int or report['authentication_posts'] != 0
                or report.get('private_data_on_regular_disk') is not False
                or type(report.get('screenshots')) is not int or report['screenshots'] != 0):
            raise ValueError('cb_txt_native/reader')
        return True
    finally:
        if probe: probe.samples.clear(); probe.close()
        if saved: saved.clear()


def execute(probe,journal,receipt,credentials,current,read_content,old_guard,previous,*,apply=False,sleep=None,now=None):
    prior=previous()
    if (not prior[0] or prior[0]['plan']['owner'] != credentials['vid'] or receipt.backend.load() is not None
            or old_guard() is not True): raise ValueError('cb_txt_native/guard')
    def record(j,r,p,target):
        if previous()!=prior or target==prior[0]['target']: raise ValueError('cb_txt_native/previous')
        receipt.record(j,r,p,target)
    def cleanup_gate(_j,_r,_p,target):
        group=GroupJournal(); before=group.read()
        if (not before[0] or target in (prior[0]['target'],before[0]['target']) or previous()!=prior
                or old_guard() is not True): return False
        return group.read()==before and previous()==prior
    kwargs={}
    if sleep is not None: kwargs['sleep']=sleep
    if now is not None: kwargs['now']=now
    return run(probe,journal,credentials,current,read_content,apply=apply,fixture_builder=lambda:BODY,
               prepare_plan=prepare_plan,check_plan=check_plan,fixture_extension='txt',readback_tries=7,
               notify_receipt=record,cleanup_gate=cleanup_gate,**kwargs)


def execute_short(probe,journal,receipt,credentials,current,read_content,old_guard,previous,previous_long,
                  *,apply=False,sleep=None,now=None):
    prior,prior_long=previous(),previous_long()
    if (not prior[0] or not prior_long[0] or prior[0]['plan']['owner']!=credentials['vid']
            or prior_long[0]['plan']['owner']!=credentials['vid'] or receipt.backend.load() is not None
            or old_guard() is not True):raise ValueError('cb_txt_native/guard')
    def unchanged():return previous()==prior and previous_long()==prior_long
    def record(j,r,p,target):
        if not unchanged() or target in (prior[0]['target'],prior_long[0]['target']):raise ValueError('cb_txt_native/previous')
        receipt.record(j,r,p,target)
    def cleanup_gate(_j,_r,_p,target):
        group=GroupJournal();before=group.read()
        if (not before[0] or target in (prior[0]['target'],prior_long[0]['target'],before[0]['target'])
                or not unchanged() or old_guard() is not True):return False
        return group.read()==before and unchanged()
    kwargs={}
    if sleep is not None:kwargs['sleep']=sleep
    if now is not None:kwargs['now']=now
    return run(probe,journal,credentials,current,read_content,apply=apply,fixture_builder=lambda:SHORT_BODY,
               prepare_plan=prepare_short_plan,check_plan=check_short_plan,fixture_extension='txt',readback_tries=7,
               notify_receipt=record,cleanup_gate=cleanup_gate,**kwargs)


def execute_single(probe,journal,receipt,credentials,current,read_content,old_guard,previouses,
                   *,apply=False,sleep=None,now=None):
    priors=tuple(getter() for getter in previouses)
    if (len(priors)!=3 or any(not row[0] or row[0]['plan']['owner']!=credentials['vid'] for row in priors)
            or receipt.backend.load() is not None or old_guard() is not True):raise ValueError('cb_txt_native/guard')
    def unchanged():return tuple(getter() for getter in previouses)==priors
    def record(j,r,p,target):
        if not unchanged() or target in {row[0]['target'] for row in priors}:raise ValueError('cb_txt_native/previous')
        receipt.record(j,r,p,target)
    def cleanup_gate(_j,_r,_p,target):
        group=GroupJournal();before=group.read()
        if (not before[0] or target in {row[0]['target'] for row in priors} or target==before[0]['target']
                or not unchanged() or old_guard() is not True):return False
        return group.read()==before and unchanged()
    kwargs={}
    if sleep is not None:kwargs['sleep']=sleep
    if now is not None:kwargs['now']=now
    return run(probe,journal,credentials,current,read_content,apply=apply,fixture_builder=lambda:SINGLE_BODY,
               prepare_plan=prepare_single_plan,check_plan=check_single_plan,fixture_extension='txt',readback_tries=7,
               notify_receipt=record,cleanup_gate=cleanup_gate,**kwargs)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--candidate')
    variants=parser.add_mutually_exclusive_group()
    variants.add_argument('--short-fixture',action='store_true');variants.add_argument('--single-fixture',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    if args.saved_session and not args.candidate:parser.error('saved session requires packaged candidate')
    if args.candidate:command(args.candidate,600,800,167)
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0)
    saved=grant=None;results=[]
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:
        if args.saved_session:
            session=SessionStore();saved=session.load();owner=saved['vid'];native_store=NativeSessionStore();grant=native_store.load(owner)
            def current(value=None):
                latest=session.load()
                return latest['vid']==owner and native_store.load(owner)==grant and (value is None or value==grant)
            def old_guard():
                snapshot=session.load()
                if snapshot['vid']!=owner:return False
                web=WebFlagsProbe();web.vid=owner
                for key,value in snapshot['cookies'].items():web.set_cookie(key,value)
                try:
                    return guarded_previous(grant,lambda:session.load()==snapshot and native_store.load(owner)==grant,NativeProbe(),web)
                finally:web.close();snapshot.clear()
            journal=SingleJournal() if args.single_fixture else ShortJournal() if args.short_fixture else Journal()
            receipt=Receipt(MacKeychain(service=('org.codex.weread.goal-cb-txt-native-single-target-v1' if args.single_fixture
                                                  else 'org.codex.weread.goal-cb-txt-native-short-target-v1' if args.short_fixture
                                                  else 'org.codex.weread.goal-cb-txt-native-target-v1'),account=ACCOUNT))
            def read_content(target):
                for size in ((600,800,167),(1264,1680,300)):
                    result=dict(width=size[0],height=size[1],dpi=size[2],result='UNVERIFIED');results.append(result)
                    try:
                        if not verify_native(target,args.candidate,size,diagnostics=result,single_page=args.single_fixture):return False
                    except Exception:return False
                    result['result']='PASS'
                return True
            if args.single_fixture:
                report=execute_single(Probe(journal,current),journal,receipt,grant,current,read_content,old_guard,
                                      (previous_txt,previous_native,previous_native_short),apply=args.apply)
            elif args.short_fixture:
                report=execute_short(Probe(journal,current),journal,receipt,grant,current,read_content,old_guard,
                                     previous_txt,previous_native,apply=args.apply)
            else:
                report=execute(Probe(journal,current),journal,receipt,grant,current,read_content,old_guard,previous_txt,apply=args.apply)
            report.update(native_sizes=results,old_group_guard_passed_after=old_guard(),previous_txt_unchanged=bool(previous_txt()))
            if args.short_fixture:report['previous_native_unchanged']=bool(previous_native())
            if args.single_fixture:report.update(previous_native_unchanged=bool(previous_native()),previous_short_unchanged=bool(previous_native_short()))
            report['account_data_writes']=report['notify_posts']+report['cleanup_posts']
    except Exception:
        report.update(result='UNVERIFIED',reason='cb_txt_native/guard_or_execution',authentication_posts=0,native_sizes=results)
        if args.apply:
            a,b=report.get('notify_posts'),report.get('cleanup_posts')
            report['account_data_writes']=a+b if type(a) is int and type(b) is int else None
    finally:
        if grant:grant.clear()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','READ_ONLY_PREVIEW','TXT_IMPORT_AND_SOURCE_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
