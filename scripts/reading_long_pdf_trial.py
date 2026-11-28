"""Distinct one-shot scope for a text-rich, two-page synthetic PDF."""
import hashlib,tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_pdf_trial import BODY_SHA256,check as check_pdf,prepare as prepare_pdf,validate_pdf
from synthetic_upload_pdf import build_reading

SERVICE='org.codex.weread.goal-long-pdf-native-reading-v1'
BODY_SIZE=8008
BODY_SHA256_LONG='9e5d40eaa504d76a57bbbdd46bd6d0a80cc859c479c29a4cba36d8423e88bf02'


def validate_long(plan):
    if not isinstance(plan,dict) or plan.get('body_sha256')!=BODY_SHA256_LONG:raise ValueError('long_pdf/plan')
    validate_pdf(dict(plan,body_sha256=BODY_SHA256));return plan


def prepare(credentials,source,name):
    body=build_reading()
    if len(body)!=BODY_SIZE or hashlib.sha256(body).hexdigest()!=BODY_SHA256_LONG:raise ValueError('long_pdf/fixture')
    plan=prepare_pdf(credentials,source,name);plan['body_sha256']=BODY_SHA256_LONG;return validate_long(plan)


def check(plan,credentials,source,target=None,expected=False):
    validate_long(plan)
    return check_pdf(dict(plan,body_sha256=BODY_SHA256),credentials,source,target,expected)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-long-pdf-reading-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_long)


class MappingJournal(BaseJournal):
    """A separate one-shot fixture for verifying original page contents."""
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-long-pdf-page-mapping-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-long-pdf-page-mapping-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_long)


class FullTextJournal(BaseJournal):
    """A separate one-shot scope for every line of the synthetic PDF."""
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-long-pdf-full-text-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-long-pdf-full-text-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_long)
