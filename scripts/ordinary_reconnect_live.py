"""Coordinate a previously prepared one-shot ordinary reconnect experiment.

The caller must provide trusted local runner command, scoped account clients,
and a currentness check covering credentials and all other pending trials.
This module never creates or resets a durable intent and never retries a POST.
"""
from copy import deepcopy
import hashlib
import secrets

from ordinary_reconnect_body_guard import validate_body
from ordinary_reconnect_broker import execute as reader_execute, preview
from ordinary_reconnect_coordinator import Coordinator
from ordinary_reconnect_observe import capture_shelves,check as observe
from ordinary_reconnect_restore import RestoreProbe, restore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore, entered_point, validate_plan
from secure_weread_session import COOKIE_NAMES
from txt_full_summary import digest
from verify_position_roundtrip import same_position
from verify_reader_context import project as reader_context
from verify_reader_progress import project as reader_progress


def context_binding(html, plan):
    identity=plan['baseline']['book_id'];value=reader_context(dict(book_id=identity),html)
    embedded=reader_progress(dict(book=value['progress']),identity)
    if (not same_position(embedded,plan['baseline']) or 'summary' in value['progress']
            and value['progress']['summary']!=plan['baseline']['summary']):
        raise ValueError('ordinary_trial/context')
    fixed=value.get('pclts')
    if fixed is None or type(fixed) is str and fixed in ('','0') or type(fixed) is int and fixed==0:fixed=None
    return dict(context=value,pclts=fixed)


def validate_input(plan,payload):
    validate_plan(plan);baseline,target=plan['baseline'],plan['target']
    if (not isinstance(payload,dict) or payload.get('ordinary') is not True or payload.get('reconnect') is not True
            or payload.get('source_format')!='web_xhtml' or payload.get('book')!=baseline['book_id']
            or payload.get('chapter')!=baseline['chapter_uid'] or payload.get('chapter_idx')!=baseline['chapter_idx']
            or payload.get('first_offset')!=baseline['chapter_offset'] or payload.get('next_offset')!=target['chapter_offset']
            or payload.get('expected_summary')!=target['summary'] or not isinstance(payload.get('source'),str)
            or hashlib.sha256(payload['source'].encode()).hexdigest()!=plan['source_sha256']
            or payload.get('book_version')!=plan['version'] or not isinstance(payload.get('cookies'),dict)
            or payload['cookies'].get('wr_vid')!=payload.get('owner') or digest(payload.get('owner'))!=plan['owner_sha256']
            or payload.get('reconnect_discover') is not None):
        raise ValueError('ordinary_trial/input')


def execute(store, plan, payload, command, web, native, grant, restore_probe, current, report):
    validate_input(plan,payload)
    if (not isinstance(store,OrdinaryReconnectStore) or not isinstance(restore_probe,RestoreProbe)
            or not isinstance(command,(tuple,list)) or not command or '--dry' in command or not callable(current)):
        raise ValueError('ordinary_trial/scope')
    cookies={cookie.name:cookie.value for cookie in web.cookies
             if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
    restore_cookies={cookie.name:cookie.value for cookie in restore_probe.cookies
                     if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
    if (not web.authenticated or web.vid!=payload['owner'] or web.book_id!=plan['baseline']['book_id']
            or cookies!=payload['cookies'] or digest(grant)!=plan['grant_sha256']
            or not restore_probe.authenticated or restore_probe.vid!=web.vid or restore_probe.book_id!=web.book_id
            or restore_cookies!=cookies or restore_probe._used):
        raise ValueError('ordinary_trial/scope')
    state,_=store.read()
    if not state or state['phase']!='prepared' or state['plan']!=plan or current() is not True:
        raise ValueError('ordinary_trial/intent')
    report.update(result='UNVERIFIED',dry_verified=False,claimed_posts=0,acknowledged_posts=0,
                  independently_verified=0,restore_claimed=False,restore_acknowledged=False,restoration_verified=False)
    scope={};dry_report={};reader_report={};restore_report={};shelf_baselines=None
    def scoped_current():
        def active_cookies(client):
            return {cookie.name:cookie.value for cookie in client.cookies
                    if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        return (current() is True and web.authenticated and web.vid==payload['owner'] and web.book_id==plan['baseline']['book_id']
                and restore_probe.authenticated and restore_probe.vid==web.vid and restore_probe.book_id==web.book_id
                and active_cookies(web)==payload['cookies'] and active_cookies(restore_probe)==payload['cookies'])
    def stable(expected):
        if observe(web,native,grant,plan,expected,scoped_current,shelf_baselines=shelf_baselines) is not True:raise ValueError('ordinary_trial/readback')
        return True
    def read_context(html):
        binding=context_binding(html,plan);scope.update(binding)
        return binding
    def dry_context(html):read_context(html);return True
    def dry_body(body):
        if not scope:return False
        return validate_body(plan,scope['context'],scope['pclts'],'enter',body)
    try:
        stable(plan['baseline'])
        shelf_baselines=capture_shelves(web,native,grant,plan,scoped_current)
        dry=deepcopy(payload);dry.update(armed=False,ordinary_trial=dict(rpc_token=secrets.token_hex(16)))
        preview([*command,'--dry'],dry,dry_body,dry_report,check_context=dry_context)
        if dry_report.get('result')!='READER_POSITION_DRY_VERIFIED' or not scope:raise ValueError('ordinary_trial/dry')
        stable(plan['baseline']);report['dry_verified']=True
        def before(stage,selected):
            expected=selected['baseline'] if stage=='enter' else entered_point(selected) if stage=='position' else selected['target']
            return observe(web,native,grant,selected,expected,scoped_current,shelf_baselines=shelf_baselines)
        def after(stage,selected):
            expected=selected['baseline'] if stage=='restore' else entered_point(selected) if stage=='enter' else selected['target']
            return (observe(web,native,grant,selected,expected,scoped_current,shelf_baselines=shelf_baselines)
                    and observe(web,native,grant,selected,expected,scoped_current,shelf_baselines=shelf_baselines))
        gate=Coordinator(store,plan,scope['context'],scope['pclts'],before,after,armed=True)
        live=deepcopy(payload);live.update(armed=True,ordinary_trial=dict(rpc_token=secrets.token_hex(16)))
        reader_execute(command,live,gate,reader_report,check_context=read_context)
        if reader_report.get('result')!='READER_POSITION_VERIFIED_RESTORE_PENDING':raise ValueError('ordinary_trial/reader')
        stable(plan['target'])
        restore(restore_probe,gate,scoped_current,restore_report)
        if restore_report.get('result')!='ORDINARY_RESTORATION_VERIFIED':raise ValueError('ordinary_trial/restore')
        state,_=store.read()
        if not state or state['phase']!='retired' or state['plan']!=plan:raise ValueError('ordinary_trial/intent')
        stable(plan['baseline']);stable(plan['baseline'])
        report.update(result='ORDINARY_RECONNECT_TRIAL_VERIFIED',restoration_verified=True)
    finally:
        for key in ('claimed_posts','acknowledged_posts','independently_verified','claim_interrupted'):
            if key in reader_report:report[key]=reader_report[key]
        for key in ('restore_claimed','restore_claim_interrupted','restore_acknowledged'):
            if key in restore_report:report[key]=restore_report[key]
