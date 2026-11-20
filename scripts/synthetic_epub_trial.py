"""Separate, fixed-content EPUB upload intent and account-shelf checks."""
import hashlib,re,tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal,check as base_check,hash_value,projection,validate
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_upload_epub import build

SERVICE='org.codex.weread.goal-synthetic-epub-upload-v1'
BODY_SHA256='0c58af1f071704f101504f58b51866b2d479ca08cd75c2a4211ece763ae6b684'


def validate_epub(plan):
    if (not isinstance(plan,dict) or not isinstance(plan.get('name'),str)
            or re.fullmatch(r'KOReaderSynthetic-[a-f0-9]{16}\.epub',plan['name']) is None
            or plan.get('body_sha256')!=BODY_SHA256):raise ValueError('synthetic_epub/plan')
    txt=dict(plan,name=plan['name'][:-5]+'.txt');validate(txt)
    return plan


def prepare(credentials,source,name):
    body=build()
    if hashlib.sha256(body).hexdigest()!=BODY_SHA256:raise ValueError('synthetic_epub/fixture')
    data=projection(source);data.pop('present')
    return validate_epub(dict(owner=credentials['vid'],name=name,body_sha256=BODY_SHA256,grant_sha256=hash_value(credentials),**data))


def check(plan,credentials,source,target=None,expected=False):
    return base_check(plan,credentials,source,target,expected,validator=validate_epub)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-synthetic-epub-upload-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_epub)
