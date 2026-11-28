"""Separate one-shot scope for reading a freshly uploaded synthetic PDF."""
import tempfile
from pathlib import Path
from personal_upload_trial import Journal as BaseJournal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from synthetic_pdf_trial import check,prepare,validate_pdf

SERVICE='org.codex.weread.goal-uploaded-pdf-native-reading-v1'


class Journal(BaseJournal):
    def __init__(self,backend=None,lock=None):
        if backend is None:
            backend=MacKeychain(service=SERVICE,account=ACCOUNT)
            path=Path(tempfile.gettempdir())/('codex-uploaded-pdf-reading-'+ACCOUNT+'.lock')
            lock=lock or (lambda:project_lock(path))
        super().__init__(backend=backend,lock=lock,validator=validate_pdf)
