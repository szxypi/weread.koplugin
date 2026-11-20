"""An immutable ordinary-book capture, isolated from all earlier trials."""
from pathlib import Path
import tempfile

from native_time_capture_bundle import CaptureBundleStore
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain

SERVICE = 'org.codex.weread.goal-native-time-capture-fresh-v1'


def store():
    def backend(name):
        return MacKeychain(service=name, account=ACCOUNT)

    path = Path(tempfile.gettempdir()) / ('codex-native-time-capture-fresh-' + ACCOUNT + '.lock')
    return CaptureBundleStore(backend(SERVICE), chunks=lambda index: backend(SERVICE + '.part-' + str(index)),
                              lock=lambda: project_lock(path))
