"""Dedicated immutable imported-book capture, separate from older journals."""
from pathlib import Path
import tempfile

from native_time_capture_bundle import CaptureBundleStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain

SERVICE='org.codex.weread.cb-native-historical-capture-v1'


def store():
    def backend(name):return MacKeychain(service=name,account=ACCOUNT)
    path=Path(tempfile.gettempdir())/('codex-cb-native-historical-capture-'+ACCOUNT+'.lock')
    return CaptureBundleStore(backend(SERVICE),chunks=lambda index:backend(SERVICE+'.part-'+str(index)),
                              lock=lambda:project_lock(path),imported=True)
