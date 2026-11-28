"""Independent two-dispatch scope; reuse the checked highlight CAS lifecycle."""
from contextlib import nullcontext
from pathlib import Path
import tempfile
from initial_mark_style_model import validate_plan
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT

SERVICE='org.codex.weread.goal-initial-mark-style-trial'


class InitialMarkStyleStore(HighlightTrialStore):
    def __init__(self,backend=None,lock=None):
        path=Path(tempfile.gettempdir())/('codex-initial-mark-style-'+ACCOUNT+'.lock')
        guard=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
        super().__init__(backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT),lock=guard)

    def validate_plan(self,value):return validate_plan(value)
