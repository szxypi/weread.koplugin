"""One-shot upload plan for the fixed streamed near-limit EPUB fixture."""
import tempfile
from pathlib import Path
from native_personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_epub_trial import BODY_SHA256,check as check_epub,prepare as prepare_epub,validate_epub

SERVICE='org.codex.weread.goal-native-near-limit-epub-ui-v1'
BODY_SIZE=208668972
BODY_SHA256_NEAR='3ccb192b4c9cb842ed43b5b87f45e94bd03de59c4a7d96b86f0f063dfa774a52'


def validate_near(plan):
    if not isinstance(plan,dict) or plan.get('body_sha256')!=BODY_SHA256_NEAR:raise ValueError('near_epub/plan')
    validate_epub(dict(plan,body_sha256=BODY_SHA256));return plan


def prepare(credentials,source,name):
    plan=prepare_epub(credentials,source,name);plan['body_sha256']=BODY_SHA256_NEAR;return validate_near(plan)


def check(plan,credentials,source,target=None,expected=False):
    validate_near(plan)
    return check_epub(dict(plan,body_sha256=BODY_SHA256),credentials,source,target,expected)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-near-limit-epub-ui-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_near)
