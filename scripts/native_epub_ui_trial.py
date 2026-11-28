"""One-shot fixed EPUB native UI upload with independent source/cleanup checks."""
import secrets,tempfile,time
from pathlib import Path
from native_personal_upload_trial import Journal as BaseJournal
from native_personal_upload_ui_trial import launch
from synthetic_epub_trial import check,prepare,validate_epub
from personal_upload_trial import valid_book
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from verify_personal_upload_trial import acknowledged,readback

SERVICE='org.codex.weread.goal-native-epub-ui-trial-v1'


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-epub-ui-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_epub)


def guarded_launch(plan,credentials,verify_fresh,*,fixture='epub'):
    if launch(plan,credentials,armed=False,fixture=fixture)!={'preview':True}:raise ValueError('epub_ui/preview')
    if verify_fresh(plan,credentials) is not True:raise ValueError('epub_ui/changed')
    return launch(plan,credentials,armed=True,fixture=fixture)


def run(probe,journal,credentials,grant_check,read_content,spawn,*,apply=False,sleep=time.sleep,prepare_plan=prepare,check_plan=check,
        fixture_extension='epub',readback_tries=5,notify_receipt=None):
    report=dict(result='UNVERIFIED',phase='preflight',native_dispatched=False,cleanup_posts=0,authentication_posts=0,source_verified=False)
    try:
        if fixture_extension not in ('epub','pdf','mobi','azw3') or type(readback_tries) is not int or not 1<=readback_tries<=9:raise ValueError('epub_ui/extension')
        baseline=probe.shelf(credentials);name='KOReaderSynthetic-'+secrets.token_hex(8)+'.'+fixture_extension
        plan=prepare_plan(credentials,baseline,name);check_plan(plan,credentials,probe.shelf(credentials))
        if not grant_check(credentials):raise ValueError('epub_ui/grant')
        if journal.read()[0] is not None:raise ValueError('epub_ui/already_reserved')
        report['independent_baselines_match']=True
        if not apply:report.update(result='READ_ONLY_PREVIEW',phase='preview');return report
        receipt=journal.reserve(plan);report['phase']='reserved';check_plan(plan,credentials,probe.shelf(credentials))
        if not grant_check(credentials):raise ValueError('epub_ui/grant')
        receipt=journal.advance(receipt,'launched');report.update(phase='launched',native_dispatched=True)
        result=spawn(plan,credentials);target=result['target']
        if not valid_book(target):raise ValueError('epub_ui/target')
        check_plan(plan,credentials,baseline,target,False)
        if notify_receipt is not None:notify_receipt(journal,receipt,plan,target)
        if not readback(probe,credentials,plan,target,True,readback_tries,sleep):raise ValueError('epub_ui/import_unconfirmed')
        receipt=journal.advance(receipt,'imported',target=target);report.update(phase='imported',import_observed=True)
        try:report['source_verified']=read_content(target) is True
        except Exception:report['source_verified']=False
        check_plan(plan,credentials,probe.shelf(credentials),target,True)
        receipt=journal.advance(receipt,'cleanup_pending');report['phase']='cleanup_pending'
        ack=False
        try:ack=acknowledged(probe.cleanup(credentials,receipt))
        except Exception:pass
        finally:report['cleanup_posts']=probe.cleanups
        restored=readback(probe,credentials,plan,target,False,3 if ack else 1,sleep)
        report.update(cleanup_acknowledged=ack,restore_observed=restored)
        if not ack or not restored:raise ValueError('epub_ui/cleanup_unconfirmed')
        check_plan(plan,credentials,probe.shelf(credentials),target,False)
        if not grant_check(credentials):raise ValueError('epub_ui/grant')
        journal.advance(receipt,'restored');report.update(phase='restored',native_counts=result['counts'])
        report['result']='NATIVE_'+fixture_extension.upper()+('_UI_AND_SOURCE_VERIFIED' if report['source_verified'] else '_UI_SOURCE_UNVERIFIED')
    except Exception as error:
        known={'epub_ui/grant','epub_ui/already_reserved','epub_ui/target','epub_ui/preview','epub_ui/changed',
               'epub_ui/import_unconfirmed','epub_ui/cleanup_unconfirmed'}
        report['reason']=str(error) if str(error) in known else 'epub_ui/unavailable'
    return report
