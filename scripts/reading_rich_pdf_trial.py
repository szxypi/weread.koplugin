"""Separate, one-shot scope for an independently inspected mixed-layout PDF."""
import hashlib,tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_pdf_trial import BODY_SHA256,check as check_pdf,prepare as prepare_pdf,validate_pdf
from synthetic_upload_rich_pdf import build

BODY_SIZE=1852
BODY_SHA256_RICH='38cb14f58cdc29536405eadd7e0db7bfed22bdeb1540b524a595d019ea987cd3'
SERVICE='org.codex.weread.goal-rich-pdf-conversion-v1'


def validate_rich(plan):
    if not isinstance(plan,dict) or plan.get('body_sha256')!=BODY_SHA256_RICH:raise ValueError('rich_pdf/plan')
    validate_pdf(dict(plan,body_sha256=BODY_SHA256));return plan


def prepare(credentials,source,name):
    body=build()
    if len(body)!=BODY_SIZE or hashlib.sha256(body).hexdigest()!=BODY_SHA256_RICH:raise ValueError('rich_pdf/fixture')
    plan=prepare_pdf(credentials,source,name);plan['body_sha256']=BODY_SHA256_RICH;return validate_rich(plan)


def check(plan,credentials,source,target=None,expected=False):
    validate_rich(plan)
    return check_pdf(dict(plan,body_sha256=BODY_SHA256),credentials,source,target,expected)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-rich-pdf-conversion-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_rich)


class ResourceJournal(BaseJournal):
    """Distinct one-shot scope for alternative image and resource inspection."""
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-rich-pdf-resource-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-rich-pdf-resource-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_rich)
