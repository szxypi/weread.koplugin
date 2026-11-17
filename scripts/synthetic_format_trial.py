"""Fixed self-authored MOBI/AZW3 fixtures and separate one-shot scopes."""
import hashlib,json,re,tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal,check as base_check,hash_value,projection,validate
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from secure_shelf_experiment import canonical
from verify_cb_progress import cb_id

FORMATS={'mobi':(13272,'f3a6e2fb8d65ee053672dc420eefe1f7494e37fa91ddf66713a1c4d0104f54e6'),
         'azw3':(14657,'d49af83424ec29d2068559c6692ca6e2ae8e71118b0d2b622660e0b30a341d57')}
FIXTURES=Path(__file__).resolve().parent.parent/'spec/fixtures'


def build(extension):
    if extension not in FORMATS:raise ValueError('synthetic_format/extension')
    body=(FIXTURES/('synthetic-upload.'+extension)).read_bytes();size,digest=FORMATS[extension]
    if len(body)!=size or hashlib.sha256(body).hexdigest()!=digest:raise ValueError('synthetic_format/fixture')
    return body


def validator(extension):
    if extension not in FORMATS:raise ValueError('synthetic_format/extension')
    def check_plan(plan):
        if (not isinstance(plan,dict) or not isinstance(plan.get('name'),str)
                or re.fullmatch(r'KOReaderSynthetic-[a-f0-9]{16}\.'+extension,plan['name']) is None
                or plan.get('body_sha256')!=FORMATS[extension][1]):raise ValueError('synthetic_format/plan')
        validate(dict(plan,name=plan['name'][:-(len(extension)+1)]+'.txt'));return plan
    return check_plan


def prepare(extension,credentials,source,name):
    build(extension);data=projection(source);data.pop('present')
    return validator(extension)(dict(owner=credentials['vid'],name=name,body_sha256=FORMATS[extension][1],grant_sha256=hash_value(credentials),**data))


def check(extension,plan,credentials,source,target=None,expected=False):
    return base_check(plan,credentials,source,target,expected,validator=validator(extension))


class Journal(BaseJournal):
    def __init__(self,extension,backend=None,lock=None):
        if extension not in FORMATS:raise ValueError('synthetic_format/extension')
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-synthetic-'+extension+'-reading-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-synthetic-'+extension+'-reading-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validator(extension))


class TargetReceipt:
    """Persist the exact acknowledged identity before waiting for shelf visibility."""
    def __init__(self,extension,backend=None,scope='reading'):
        if scope not in ('reading','native-ui','long-pdf'):raise ValueError('synthetic_format/scope')
        if extension not in FORMATS and not (extension=='pdf' and scope in ('native-ui','long-pdf')) or scope=='long-pdf' and extension!='pdf':raise ValueError('synthetic_format/extension')
        self.phase='launched' if scope=='native-ui' else 'notify_pending'
        suffix='-target-v1' if scope=='reading' else '-native-ui-target-v1' if scope=='native-ui' else '-long-reading-target-v1'
        self.backend=backend if backend is not None else MacKeychain(service='org.codex.weread.goal-synthetic-'+extension+suffix,account=ACCOUNT)

    def record(self,journal,receipt,plan,target):
        state,current=journal.read()
        if (not state or state['phase']!=self.phase or current!=receipt or state['plan']!=plan
                or not cb_id(target) or self.backend.load() is not None):raise ValueError('synthetic_format/receipt')
        raw=canonical(dict(schema=1,owner=plan['owner'],attempt=state['attempt'],target=target,plan_sha256=hash_value(plan)))
        self.backend.save(raw)
        if self.backend.load()!=raw:raise ValueError('synthetic_format/receipt')
        if json.loads(raw).get('target')!=target:raise ValueError('synthetic_format/receipt')
