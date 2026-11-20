"""Distinct native four-slot scope; old style grants cannot authorize it."""
from contextlib import nullcontext
from pathlib import Path
import tempfile
from nonempty_marks_trial import PHASES,validate_plan
from secure_mark_style_trial import MarkStyleTrialStore
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT

SERVICE='org.codex.weread.goal-native-nonempty-marks-trial'


class NonemptyMarksStore(MarkStyleTrialStore):
    phases=PHASES
    confirmed_phases=('created','colored','styled')

    def __init__(self,backend=None,lock=None):
        path=Path(tempfile.gettempdir())/('codex-native-nonempty-marks-'+ACCOUNT+'.lock')
        super().__init__(backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT),
            lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext),native=True)

    def validate_plan(self,value):return validate_plan(value)
