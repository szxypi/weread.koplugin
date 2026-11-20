"""A distinct one-shot scope for the fixed synthetic PDF fixture."""
import hashlib,re,tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal,check as base_check,hash_value,projection,validate
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_upload_pdf import build

SERVICE='org.codex.weread.goal-synthetic-pdf-upload-v1'
BODY_SHA256='bb52baf0dfb75cf83e6ae4e5e70d093d047fbc4c58f46e49c9f7ece8efbb3dcd'
BODY_SIZE=965


def validate_pdf(plan):
    if (not isinstance(plan,dict) or not isinstance(plan.get('name'),str)
            or re.fullmatch(r'KOReaderSynthetic-[a-f0-9]{16}\.pdf',plan['name']) is None
            or plan.get('body_sha256')!=BODY_SHA256):raise ValueError('synthetic_pdf/plan')
    validate(dict(plan,name=plan['name'][:-4]+'.txt'))
    return plan


def prepare(credentials,source,name):
    body=build()
    if len(body)!=BODY_SIZE or hashlib.sha256(body).hexdigest()!=BODY_SHA256:raise ValueError('synthetic_pdf/fixture')
    data=projection(source);data.pop('present')
    return validate_pdf(dict(owner=credentials['vid'],name=name,body_sha256=BODY_SHA256,grant_sha256=hash_value(credentials),**data))


def check(plan,credentials,source,target=None,expected=False):
    return base_check(plan,credentials,source,target,expected,validator=validate_pdf)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-synthetic-pdf-upload-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_pdf)
