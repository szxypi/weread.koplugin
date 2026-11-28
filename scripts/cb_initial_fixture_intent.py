"""Separate, durable two-request budget for a fresh synthetic CB fixture."""
from contextlib import nullcontext
from pathlib import Path
import tempfile

from cb_existing_position_intent import Intent as BaseIntent
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError

SERVICE = 'org.codex.weread.cb-first-fixture-position-v1'


class Intent(BaseIntent):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service=SERVICE, account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-first-fixture-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend=backend, lock=lock or nullcontext)

    def claim(self, value, stage):
        if stage not in ('write_enter', 'write_same') or value.get('claimed', 2) >= 2:
            raise StoreError('cb_first/claim_scope')
        return super().claim(value, stage)
