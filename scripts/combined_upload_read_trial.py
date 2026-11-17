"""Distinct one-shot scope for upload and reading in the same profile."""
import tempfile
from pathlib import Path
from native_personal_upload_trial import Journal as BaseJournal
from reading_epub_trial import check,prepare,validate_reading
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain

SERVICE='org.codex.weread.goal-native-combined-upload-read-v1'


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-combined-upload-read-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_reading)


class SameSessionJournal(BaseJournal):
    """Independent, one-shot target for the continuous live reader session."""
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service='org.codex.weread.goal-native-same-session-read-v1',account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-native-same-session-read-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_reading)
