"""One-shot plan for a fixed multipage, self-authored EPUB reading trial."""
import hashlib,tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_epub_trial import BODY_SHA256,check as check_epub,prepare as prepare_epub,validate_epub
from synthetic_upload_epub import build_reading

SERVICE='org.codex.weread.goal-uploaded-epub-native-reading-v1'
BODY_SHA256_READING='d3688feb3e04e785a7fe7afa2e95b9771790467c99b6cda624dd54a13a145840'
BODY_SIZE=13601


def validate_reading(plan):
    if not isinstance(plan,dict) or plan.get('body_sha256')!=BODY_SHA256_READING:raise ValueError('reading_epub/plan')
    validate_epub(dict(plan,body_sha256=BODY_SHA256));return plan


def prepare(credentials,source,name):
    body=build_reading()
    if len(body)!=BODY_SIZE or hashlib.sha256(body).hexdigest()!=BODY_SHA256_READING:raise ValueError('reading_epub/fixture')
    plan=prepare_epub(credentials,source,name);plan['body_sha256']=BODY_SHA256_READING;return validate_reading(plan)


def check(plan,credentials,source,target=None,expected=False):
    validate_reading(plan)
    return check_epub(dict(plan,body_sha256=BODY_SHA256),credentials,source,target,expected)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-uploaded-epub-reading-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_reading)
