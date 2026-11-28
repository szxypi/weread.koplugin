"""One-shot plan for the fixed exactly 200 MiB streamed EPUB fixture."""
import tempfile
from pathlib import Path
from native_personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_epub_trial import BODY_SHA256,check as check_epub,prepare as prepare_epub,validate_epub

SERVICE='org.codex.weread.goal-native-exact-limit-epub-ui-v1'
BODY_SIZE=200*1024*1024
BODY_SHA256_EXACT='ded3a507b8d0938e186e3a8e8e96903c7921afd411f47abf414af36a689728a0'


def validate_exact(plan):
    if not isinstance(plan,dict) or plan.get('body_sha256')!=BODY_SHA256_EXACT:raise ValueError('exact_epub/plan')
    validate_epub(dict(plan,body_sha256=BODY_SHA256));return plan


def prepare(credentials,source,name):
    plan=prepare_epub(credentials,source,name);plan['body_sha256']=BODY_SHA256_EXACT;return validate_exact(plan)


def check(plan,credentials,source,target=None,expected=False):
    validate_exact(plan)
    return check_epub(dict(plan,body_sha256=BODY_SHA256),credentials,source,target,expected)


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-exact-limit-epub-ui-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_exact)


class JournalV2(BaseJournal):
    """Fresh scope for the corrected large-file confirmation behavior."""
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-native-exact-limit-epub-ui-v2',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-exact-limit-epub-ui-v2-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_exact)
