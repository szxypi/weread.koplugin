"""Isolated fixture upload scope and durable target-binding validation."""
import json
from pathlib import Path
import tempfile

from personal_upload_trial import Journal as BaseJournal, hash_value
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain
from synthetic_epub_trial import validate_epub
from verify_cb_progress import cb_id

SERVICE = 'org.codex.weread.goal-group-fixture-epub-v1'


class Journal(BaseJournal):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service=SERVICE, account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-group-fixture-epub-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend=backend, lock=lock, validator=validate_epub)


def binding(journal, receipt_backend, *, phase='imported'):
    """Require independently persisted notification identity and imported state."""
    if phase not in ('imported','cleanup_pending'): raise ValueError('cloud_group_fixture/unbound')
    state, token = journal.read(); raw = receipt_backend.load()
    try:
        if not isinstance(raw, bytes) or not 0 < len(raw) <= 8192: raise ValueError()
        receipt = json.loads(raw)
        if (not isinstance(receipt, dict) or set(receipt) != {'schema', 'owner', 'attempt', 'target', 'plan_sha256'}
                or type(receipt['schema']) is not int or receipt['schema'] != 1 or not state
                or state['phase'] != phase or not cb_id(state['target'])
                or receipt['owner'] != state['plan']['owner'] or receipt['attempt'] != state['attempt']
                or receipt['target'] != state['target'] or receipt['plan_sha256'] != hash_value(state['plan'])):
            raise ValueError()
        return state, token
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise ValueError('cloud_group_fixture/unbound') from None
