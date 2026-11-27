"""One durable account-scoped, two-slot native ReaderUI trial."""
from native_direct_ui_trial_broker import PROTOCOL,TXT_PROTOCOL,validate_plan
from secure_native_txt_roundtrip import NativeTxtRoundtripStore


class NativeDirectUITrialStore(NativeTxtRoundtripStore):
    service='org.codex.weread.goal-native-direct-ui-position-v1'
    protocol=PROTOCOL
    mode='manual'

    def __init__(self,backend=None,*,txt=False):
        if txt:
            self.service='org.codex.weread.goal-native-direct-txt-'+self.mode+'-position-v1'
            self.protocol=TXT_PROTOCOL
        super().__init__(backend)

    def validate_plan(self,plan):validate_plan(plan,self.protocol)


class NativeDirectIntervalTrialStore(NativeDirectUITrialStore):
    """Independent one-shot recovery intent for the timed reader trial."""
    service='org.codex.weread.goal-native-direct-interval-position-v1'
    mode='timed'


class NativeDirectCloseTrialStore(NativeDirectUITrialStore):
    """Independent one-shot recovery intent for the detached close trial."""
    service='org.codex.weread.goal-native-direct-close-position-v1'
    mode='closed'


def store_for(*,txt,timed,closed,backend=None):
    factory=NativeDirectCloseTrialStore if closed else NativeDirectIntervalTrialStore if timed else NativeDirectUITrialStore
    return factory(backend,txt=txt)
