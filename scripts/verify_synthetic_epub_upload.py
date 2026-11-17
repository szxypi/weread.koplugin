#!/usr/bin/env python3
"""One fixed EPUB upload, bounded read-only source check, and exact cleanup."""
import argparse,json,resource,secrets,time
from synthetic_epub_trial import Journal,check,prepare
from synthetic_upload_epub import TEXT,build
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_cb_reading import CbReadingError,CbReadingProbe
from verify_cb_metadata import CbMetadataError
from verify_cb_progress import cb_id
from verify_personal_upload_trial import Probe,acknowledged,readback
from personal_upload_trial import hash_value,valid_book
from cos_signature import sign


def read_source(saved,target,*,sleep=time.sleep):
    """All permitted Web POSTs are bounded chapter/catalog queries for target."""
    if not cb_id(target):raise ValueError('synthetic_epub/target')
    for attempt in range(3):
        web=CbReadingProbe()
        try:
            web.vid=saved['vid'];web.allowed={target}
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();sample=web.inspect(target);web.verify_account()
            checks=web.last_checks
            return (sample['book_id']==target and sample['source_format']=='web_xhtml' and TEXT in sample['source']
                and set(checks)=={'catalog_unchanged','versions_unchanged','position_unchanged'} and all(v is True for v in checks.values()))
        except (CbReadingError,CbMetadataError) as error:
            if str(error) not in ('cb_catalog_empty','cb_catalog_invalid') or attempt==2:raise
        finally:web.samples.clear();web.close()
        sleep(2*(attempt+1))
    return False


def run(probe,journal,credentials,grant_check,read_content,*,apply=False,sleep=time.sleep,now=time.time,
        fixture_builder=build,prepare_plan=prepare,check_plan=check,fixture_extension='epub'):
    report=dict(result='UNVERIFIED',phase='preflight',credential_requests=0,cos_put_attempts=0,notify_posts=0,cleanup_posts=0,
                authentication_posts=0,source_verified=False)
    try:
        if fixture_extension not in ('epub','pdf'):raise ValueError('synthetic_epub/extension')
        baseline=probe.shelf(credentials);name='KOReaderSynthetic-'+secrets.token_hex(8)+'.'+fixture_extension;body=fixture_builder()
        plan=prepare_plan(credentials,baseline,name);check_plan(plan,credentials,probe.shelf(credentials))
        if not grant_check(credentials):raise ValueError('synthetic_epub/grant')
        if journal.read()[0] is not None:raise ValueError('synthetic_epub/already_reserved')
        report['independent_baselines_match']=True
        if not apply:report.update(result='READ_ONLY_PREVIEW',phase='preview');return report
        receipt=journal.reserve(plan);report['phase']='prepared';check_plan(plan,credentials,probe.shelf(credentials))
        receipt=journal.advance(receipt,'credential_pending');report['phase']='credential_pending'
        try:temporary=probe.credential(credentials,receipt)
        finally:report['credential_requests']=probe.attempts['credential']
        sign(temporary,len(body),int(now()))
        obj=hash_value({'bucket':temporary.get('bucket'),'ObjectName':temporary.get('ObjectName')})
        receipt=journal.advance(receipt,'credential_ready',object_sha256=obj);report['phase']='credential_ready'
        check_plan(plan,credentials,probe.shelf(credentials));receipt=journal.advance(receipt,'upload_pending');report['phase']='upload_pending'
        uploaded=False
        try:uploaded=probe.put(credentials,receipt,temporary,body,int(now())) is True
        except Exception:pass
        finally:report['cos_put_attempts']=probe.attempts['put']
        if not uploaded:raise ValueError('synthetic_epub/put_unconfirmed')
        receipt=journal.advance(receipt,'uploaded');report['phase']='uploaded'
        check_plan(plan,credentials,probe.shelf(credentials));receipt=journal.advance(receipt,'notify_pending');report['phase']='notify_pending'
        notified=None
        try:notified=probe.notify(credentials,receipt,temporary)
        except Exception:pass
        finally:report['notify_posts']=probe.attempts['notify']
        target=notified.get('bookId') if isinstance(notified,dict) else None
        if (not isinstance(notified,dict) or type(notified.get('status')) is not int or notified['status']!=1 or not valid_book(target)
                or any(k in notified and (type(notified[k]) is not int or notified[k]!=0) for k in ('errcode','errCode'))):
            raise ValueError('synthetic_epub/notify_unconfirmed')
        check_plan(plan,credentials,baseline,target,False)
        if not readback(probe,credentials,plan,target,True,5,sleep):raise ValueError('synthetic_epub/import_unconfirmed')
        receipt=journal.advance(receipt,'imported',target=target);report.update(phase='imported',import_observed=True)
        # A failed read-only content check is not a reason to leave a proven
        # synthetic item behind. Cleanup still requires a fresh exact snapshot.
        try:report['source_verified']=read_content(target) is True
        except Exception:report['source_verified']=False
        check_plan(plan,credentials,probe.shelf(credentials),target,True)
        receipt=journal.advance(receipt,'cleanup_pending');report['phase']='cleanup_pending'
        ack=False
        try:ack=acknowledged(probe.cleanup(credentials,receipt))
        except Exception:pass
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,credentials,plan,target,False,3 if ack else 1,sleep)
        report.update(cleanup_acknowledged=ack,restore_observed=restored)
        if not ack or not restored:raise ValueError('synthetic_epub/cleanup_unconfirmed')
        check_plan(plan,credentials,probe.shelf(credentials),target,False)
        if not grant_check(credentials):raise ValueError('synthetic_epub/grant')
        journal.advance(receipt,'restored');report['phase']='restored'
        report['result']=fixture_extension.upper()+('_IMPORT_AND_SOURCE_VERIFIED' if report['source_verified'] else '_IMPORTED_SOURCE_UNVERIFIED')
    except Exception as error:
        known={'synthetic_epub/grant','synthetic_epub/already_reserved','synthetic_epub/put_unconfirmed','synthetic_epub/notify_unconfirmed',
               'synthetic_epub/import_unconfirmed','synthetic_epub/cleanup_unconfirmed'}
        report['reason']=str(error) if str(error) in known else 'synthetic_epub/unavailable'
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY')));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=web=None
    try:
        saved=SessionStore().load();native=NativeSessionStore();grant=native.load(saved['vid']);journal=Journal()
        def same(value):return native.load(saved['vid'])==value
        # Check Web ownership before a write; later content reads remain scoped
        # to the just-created identity and never alter positions or annotations.
        web=CbReadingProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.close();web=None
        probe=Probe(journal,same);report=run(probe,journal,grant,same,lambda target:read_source(saved,target),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',reason='synthetic_epub/unavailable')
    finally:
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,indent=2));return 0 if report['result'] in ('READ_ONLY_PREVIEW','EPUB_IMPORT_AND_SOURCE_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
