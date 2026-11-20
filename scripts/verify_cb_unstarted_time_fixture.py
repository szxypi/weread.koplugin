#!/usr/bin/env python3
"""One isolated time-only probe before a self-authored TXT's first position.

Offline by default. A fresh imported fixture, exact owner/receipt binding,
private baseline and permanent single-use claim are required. An uncertain
send never replays or authorizes automatic fixture cleanup.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import resource
import secrets
import tempfile
import time
from urllib.parse import urlencode

from cb_cloud_position import observed
from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from cb_unstarted_time_fixture_flow import run as time_flow
from cloud_group_contract import project
from cloud_group_nonempty_workflow import strip_fixture
from personal_upload_trial import hash_value
from readtime_upload_model import guest_token, local_zone
from secure_native_session import NativeSessionStore, project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_fixture_position_trial import owned
from verify_cb_reading import CbReadingProbe
from verify_cb_txt_fixture import BODY, MARKER, Journal, Receipt, check_plan, prepare_plan
from verify_cb_txt_version_fixture import inspect_fixture
from verify_cb_txt_zero_native_batch import ZeroBatchProbe, zero_batch
from verify_eink_login import BASE as NATIVE
from verify_native_statistics import period
from verify_personal_upload_trial import Probe as UploadProbe
from verify_reader_progress import find_node
from verify_readtime_upload import expected_statistics
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB, WebSourceProbe


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-unstarted-time-' + name + '-v1', account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-unstarted-time-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')), Receipt(backend=backend('receipt')),
            Intent(backend=backend('time'), lock=lock('time')), Evidence(backend=backend('baseline'), lock=lock('baseline')))


def run(saved, session, native_store, grant, journal, receipt, intent, evidence, *, apply=False,
        upload_factory=UploadProbe, uploader=upload_run, api_factory=ZeroBatchProbe,
        inspector=inspect_fixture, clock=time.time, monotonic=time.monotonic, sleep=time.sleep, random=secrets.randbelow,
        after_time=None):
    report = dict(result='UNVERIFIED', phase='preflight', account_data_writes_known=0,
                  authentication_posts=0, existing_book_writes=0, fixture_only=True,
                  private_data_in_report=False, time_posts=0, time_write_uncertain=False)
    current = dict(saved=saved, sample=None, source_hash=None, before_shelf=None, flow=None)

    def same_grant(value): return native_store.load(current['saved']['vid']) == value

    def persist(web):
        if web.authenticated and save_refreshed_web_session(session, current['saved'], web):
            old = current['saved']; current['saved'] = session.load()
            if old['vid'] != current['saved']['vid']: raise ValueError('unstarted_fixture/owner')
            old.clear()

    def connect(cls, target=None):
        web = cls(); web.vid = current['saved']['vid']
        if target:
            web.book_id = target
            if hasattr(web, 'allowed'): web.allowed = {target}
        for key, value in current['saved']['cookies'].items(): web.set_cookie(key, value)
        web.verify_account(); return web

    def shelf(target=None):
        web = connect(WebSourceProbe)
        try:
            raw = web.request('shelf', WEB + '/web/shelf/sync')
            result = project(raw) if target is None else strip_fixture(raw, target)
            web.verify_account(); persist(web); return result
        finally: web.close()

    def source(target):
        web = connect(CbReadingProbe, target)
        try:
            sample = web.inspect(target); web.verify_account()
            ok = (sample.get('book_id') == target and sample.get('source_format') == 'web_txt'
                  and MARKER in sample.get('source', '') and sample.get('baseline') == dict(chapter='0', offset=0, percent=0)
                  and set(web.last_checks) == {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                  and all(value is True for value in web.last_checks.values()))
            if ok: current.update(sample=sample, source_hash=sample['source_raw_sha256'])
            persist(web); return ok
        finally: web.samples.clear(); web.close()

    def gate(upload, upload_receipt, _plan, target):
        sample = current['sample']
        if not sample: return True  # No time request has been prepared or sent.
        owner = current['saved']['vid']; state, returned = upload.read()
        if (not state or returned != upload_receipt or state.get('phase') != 'imported' or state.get('target') != target
                or state['plan'].get('owner') != owner): return False
        attempt = state['attempt']
        expected_receipt = canonical(dict(schema=1, owner=owner, attempt=attempt, target=target,
                                          plan_sha256=hash_value(state['plan'])))
        def authority():
            return (owned(upload, upload_receipt, target, owner, grant, same_grant)
                    and receipt.backend.load() == expected_receipt)
        if not authority() or shelf(target) != current['before_shelf']: return False
        api = api_factory(grant, target, authority)
        latest = {}

        def pair(chapters=None):
            if not authority(): raise ValueError('unstarted_fixture/owner')
            web = connect(WebSourceProbe, target)
            try:
                native = api.progress()
                remote = web.request('progress_after', WEB + '/web/book/getProgress?' + urlencode({'bookId': target}))
                node = find_node(remote, target); updated = node.get('updateTime')
                if type(updated) is not int or updated < 0: raise ValueError('unstarted_fixture/updated')
                latest['updated'] = updated
                web.verify_account(); persist(web)
                return {channel: observed(raw, target, chapters if chapters is not None else sample['chapters'], channel)
                        for channel, raw in (('native', native), ('web', remote))}
            finally: web.close()

        def version_check():
            result = {}
            session_view = dict(vid=owner, cookies=current['saved']['cookies'])
            if (not inspector(session_view, grant, target, lambda value: authority() and value == grant,
                              result, expected_source=current['source_hash'])
                    or result.get('native_version_category') != 'zero'
                    or any(result.get(key) != 'absent' for key in ('catalog_root_version_category', 'catalog_book_version_category'))):
                raise ValueError('unstarted_fixture/version')
            return result

        def prepare(before, stats):
            if not authority() or shelf(target) != current['before_shelf']: raise ValueError('unstarted_fixture/shelf')
            version = version_check(); config = api.capability('config'); guest, _ = guest_token(api.capability('feature'))
            zone = local_zone(); wall = clock(); mono = monotonic(); start = math.ceil(wall)
            if zone != '+08:00' or int(wall + 60 + 28800) // 86400 != int(wall + 28800) // 86400:
                raise ValueError('unstarted_fixture/clock')
            sleep(max(0, start + 2 - wall) + .01)
            if not 2 <= monotonic() - mono <= 4 or not 0 <= clock() - (start + 2) < 2:
                raise ValueError('unstarted_fixture/clock')
            if not authority() or version_check() != version or shelf(target) != current['before_shelf']:
                raise ValueError('unstarted_fixture/changed')
            now = int(clock())
            if (now < start + 2 or now > start + 30 or (start + 28800) // 86400 != (now + 28800) // 86400
                    or period('monthly', start)[0] != period('monthly', now)[0]):
                raise ValueError('unstarted_fixture/clock')
            payload = zero_batch(grant, target, start, now, guest, config.get('token'), None, random(1000), random(1000), zone)
            targets = []
            for delta in (0, 1):
                value = expected_statistics(stats, start, 2, time_zone=zone); value['readDays'] = stats['readDays'] + delta
                targets.append(value)
            return payload, targets

        def reserve(before, stats, payload):
            if not authority(): raise ValueError('unstarted_fixture/owner')
            snapshot = dict(source=current['source_hash'], position=before['web']['projection'], updated_at=latest['updated'],
                            counters={k:before['native']['counters'][k]['value'] for k in ('readingTime','recordReadingTime','ttsTime')},
                            stats=stats, body=payload)
            evidence.save(dict(schema=1, owner_sha256=hashlib.sha256(owner.encode()).hexdigest(),
                book_sha256=hashlib.sha256(target.encode()).hexdigest(), attempt=attempt, baseline=snapshot))
            return intent.reserve(owner, target, attempt, hashlib.sha256(canonical(snapshot)).hexdigest())

        reservation = {}
        def claim(value):
            reservation['value'] = value
            return intent.claim(value)
        def allowed(permit):
            return authority() and shelf(target) == current['before_shelf'] and (permit is None or (
                'value' in reservation and intent.verify(reservation['value'], permit)))
        def send(payload, permit):
            return api.send_once(payload, lambda: allowed(permit))
        result = time_flow(pair, api.stats, prepare, reserve, lambda value: api.bind(value, ''),
                           claim, allowed, send, sleep=sleep)
        current['flow'] = result
        report.update(time_posts=api.sent, time_write_uncertain=result['write_uncertain'], time_probe=result)
        if after_time is not None and result['result'] == 'PASS':
            context = dict(owner=owner, target=target, attempt=attempt, sample=sample, source_hash=current['source_hash'],
                pair=pair, stats=api.stats, authority=authority, shelf_current=lambda: shelf(target)==current['before_shelf'],
                connect=connect, persist=persist, cookies=lambda: current['saved']['cookies'], latest=latest)
            try:
                followup = after_time(context, report)
                if (not isinstance(followup, dict) or type(followup.get('attempted')) is not int
                        or followup['attempted'] not in (0,1) or type(followup.get('cleanup_allowed')) is not bool
                        or type(followup.get('write_uncertain')) is not bool):
                    raise ValueError('unstarted_fixture/followup')
                report['position_probe'] = followup
                report['position_posts'] = followup['attempted']
                report['position_write_uncertain'] = followup.get('write_uncertain') is True
                if not followup.get('cleanup_allowed') and followup['attempted'] != 0: return False
            except Exception:
                report['position_write_uncertain'] = True
                return False
        # If no time send was attempted, an unchanged, proven fixture can still
        # be removed by the upload routine. Unknown sends leave it intact.
        return bool(authority() and shelf(target) == current['before_shelf']
                    and (result['cleanup_allowed'] or result['attempted'] == 0))

    try:
        if any(item.backend.load() is not None for item in (receipt, intent, evidence)) or journal.read()[0] is not None:
            raise ValueError('unstarted_fixture/consumed')
        first = shelf(); second = shelf()
        if first != second: raise ValueError('unstarted_fixture/shelf')
        current['before_shelf'] = first
        probe = upload_factory(journal, same_grant)
        report['phase'] = 'upload_active'
        upload = uploader(probe, journal, grant, same_grant, source, apply=apply, cleanup_gate=gate,
                          fixture_builder=lambda: BODY, prepare_plan=prepare_plan, check_plan=check_plan,
                          fixture_extension='txt', readback_tries=7, notify_receipt=receipt.record)
        report['upload'] = upload; report['phase'] = upload.get('phase', 'unknown')
        position_posts=report.get('position_posts',0)
        report['account_data_writes_known'] = ((upload.get('cos_put_attempts', 0) + upload.get('notify_posts', 0)
                                               + upload.get('cleanup_posts', 0) + report['time_posts'] + position_posts)
                                              if type(position_posts) is int else None)
        if upload.get('result') == 'READ_ONLY_PREVIEW': report['result'] = 'READ_ONLY_PREVIEW'
        elif (upload.get('result') == 'TXT_IMPORT_AND_SOURCE_VERIFIED' and current['flow']
              and current['flow']['result'] == 'PASS' and shelf() == first):
            report.update(result='UNSTARTED_TIME_FIXTURE_VERIFIED', shelf_restored=True)
    except Exception:
        report['result'] = 'UNVERIFIED'
        if apply and report['phase'] == 'upload_active':
            report['account_data_writes_known'] = None
    finally:
        current['sample'] = None
        if current['saved'] is not saved and saved: saved.clear()
        if current['saved']: current['saved'].clear()
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_data_writes_known=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, *stores(), apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', phase='unknown' if args.apply else 'preflight',
                      account_data_writes_known=None if args.apply else 0, authentication_posts=0,
                      existing_book_writes=0, fixture_only=True, private_data_in_report=False)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report))
    return int(report['result'] not in ('READ_ONLY_PREVIEW', 'UNSTARTED_TIME_FIXTURE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
