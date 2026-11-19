#!/usr/bin/env python3
"""One isolated TXT import and read-only official selection observation.

The observed add-bookmark request is intercepted and aborted offline. The
fixture uses its own durable upload journal and is cleaned up even if the
read-only observation cannot be completed. No annotations are sent.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile
import time

from cb_txt_highlight_trial import BODY, TEXT
from cb_txt_official_selection import observe
from personal_upload_trial import Journal
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_metadata import CbMetadataError
from verify_cb_reading import CbReadingError, CbReadingProbe
from verify_cb_txt_fixture import Receipt
from verify_cb_txt_highlight_trial import check_plan, fixture_authorized, prepare_plan, validate_plan
from verify_personal_upload_trial import Probe
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-official-selection-'+part+'-v1',account=ACCOUNT)
    path=Path(tempfile.gettempdir())/('codex-cb-txt-official-selection-upload-'+ACCOUNT+'.lock')
    return Journal(backend=backend('upload'),lock=lambda:project_lock(path),validator=validate_plan),Receipt(backend=backend('receipt'))


def run(saved,session,native,grant,journal,receipt,*,apply=False,upload_fn=upload_run,probe_factory=Probe,
        source_factory=CbReadingProbe,observe_fn=observe,sleep=time.sleep):
    report=dict(result='UNVERIFIED',annotation_posts=0,authentication_posts=0,existing_book_writes=0,
                fixture_only=True,private_values_in_report=False)
    current={'saved':saved};observation={}
    def same(value):return native.load(current['saved']['vid'])==value
    def read(target):
        for attempt in range(3):
            web=source_factory()
            try:
                web.vid=current['saved']['vid'];web.allowed={target}
                for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
                web.verify_account();sample=web.inspect(target);web.verify_account()
                if (sample.get('book_id')!=target or sample.get('source_format')!='web_txt'
                        or not isinstance(sample.get('source'),str) or sample['source'].count(TEXT)!=1
                        or sample.get('source_raw_sha256')!=hashlib.sha256(sample['source'].encode()).hexdigest()
                        or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                        or not all(web.last_checks.values())):raise ValueError('official_txt/source')
                if save_refreshed_web_session(session,current['saved'],web):
                    old=current['saved'];current['saved']=session.load()
                    if old['vid']!=current['saved']['vid']:raise ValueError('official_txt/owner')
                    old.clear()
                return sample
            except (CbReadingError,CbMetadataError) as error:
                if str(error) not in ('cb_catalog_empty','cb_catalog_invalid') or attempt==2:raise
            finally:
                web.samples.clear();web.close()
            sleep(2*(attempt+1))
        raise ValueError('official_txt/source')
    def read_content(target):
        state,claim=journal.read()
        if (state is None or state.get('target')!=target or not fixture_authorized(journal,claim,target,
                current['saved']['vid'],grant,same,receipt)):raise ValueError('official_txt/ownership')
        first=read(target)
        try:
            checked=observe_fn(first,current['saved']['cookies'])
            if (not isinstance(checked,dict) or checked.get('result')!='PASS'
                    or any(checked.get(key) is not True for key in ('same_book_and_chapter','exact_quote_and_range',
                        'selected_from_fixture','non_bmp_before_selection','attempted_write_blocked'))):
                raise ValueError('official_txt/observation')
            second=read(target)
            if any(first.get(key)!=second.get(key) for key in ('source_raw_sha256','chapter_uid','chapters','baseline')):
                raise ValueError('official_txt/source_changed')
            observation.update(checked,source_and_position_unchanged=True)
            return True
        except Exception as error:
            known={'official_txt/not_visible','official_txt/no_toolbar','official_txt/no_request',
                   'official_txt/scope','official_txt/selection','official_txt/range',
                   'official_txt/observation','official_txt/source_changed'}
            observation.update(result='UNVERIFIED',reason=str(error) if str(error) in known else 'official_txt/unavailable')
            raise
        finally:first.clear()
    try:
        if receipt.backend.load() is not None:raise ValueError('official_txt/consumed')
        probe=probe_factory(journal,same)
        result=upload_fn(probe,journal,grant,same,read_content,apply=apply,fixture_builder=lambda:BODY,
                         prepare_plan=prepare_plan,check_plan=check_plan,fixture_extension='txt',readback_tries=7,
                         notify_receipt=receipt.record)
        report['upload']=result
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='TXT_IMPORT_AND_SOURCE_VERIFIED' and observation:
            report.update(result='OFFICIAL_TXT_SELECTION_VERIFIED',observation=observation,fixture_removed=True)
        else:
            report['phase']=result.get('phase','unknown')
            if observation:report['observation']=observation
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',annotation_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:
        report=dict(result='UNVERIFIED',phase='setup')
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return 0 if report.get('result') in ('READ_ONLY_PREVIEW','OFFICIAL_TXT_SELECTION_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
