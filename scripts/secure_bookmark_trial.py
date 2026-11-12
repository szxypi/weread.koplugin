"""Distinct bookmark protocols and Keychain services, sharing two-slot CAS."""
from pathlib import Path
import tempfile
from bookmark_trial_model import validate_plan
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT

SERVICE='org.codex.weread.goal-bookmark-trial'
NATIVE_SERVICE='org.codex.weread.goal-native-bookmark-trial'


class BookmarkTrialStore(HighlightTrialStore):
    def __init__(self,backend=None,lock=None,*,native=False):
        if type(native) is not bool:raise ValueError('bookmark_trial/intent_kind')
        if backend is None:
            backend=MacKeychain(service=NATIVE_SERVICE if native else SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/(('codex-native-bookmark-' if native else 'codex-bookmark-')+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend,lock,native=native)

    def validate_plan(self,value):return validate_plan(value,native=self.native)
