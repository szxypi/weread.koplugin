"""Separate native UI upload scopes for fixed PDF, MOBI and AZW3 fixtures."""
import tempfile
from pathlib import Path
from native_personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_pdf_trial import check as check_pdf,prepare as prepare_pdf,validate_pdf
from synthetic_format_trial import check as check_format,prepare as prepare_format,validator


def prepare(extension,credentials,source,name):
    if extension=='pdf':return prepare_pdf(credentials,source,name)
    return prepare_format(extension,credentials,source,name)


def check(extension,plan,credentials,source,target=None,expected=False):
    if extension=='pdf':return check_pdf(plan,credentials,source,target,expected)
    return check_format(extension,plan,credentials,source,target,expected)


class Journal(BaseJournal):
    def __init__(self,extension,backend=None,lock=None):
        if extension not in ('pdf','mobi','azw3'):raise ValueError('native_format_ui/extension')
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-native-'+extension+'-ui-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-'+extension+'-ui-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_pdf if extension=='pdf' else validator(extension))
