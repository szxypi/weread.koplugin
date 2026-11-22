"""One durable account-scoped, two-slot native ReaderUI trial."""
from native_direct_ui_trial_broker import PROTOCOL,validate_plan
from secure_native_txt_roundtrip import NativeTxtRoundtripStore


class NativeDirectUITrialStore(NativeTxtRoundtripStore):
    service='org.codex.weread.goal-native-direct-ui-position-v1'
    protocol=PROTOCOL

    def validate_plan(self,plan):validate_plan(plan)


class NativeDirectIntervalTrialStore(NativeDirectUITrialStore):
    """Independent one-shot recovery intent for the timed reader trial."""
    service='org.codex.weread.goal-native-direct-interval-position-v1'


class NativeDirectCloseTrialStore(NativeDirectUITrialStore):
    """Independent one-shot recovery intent for the detached close trial."""
    service='org.codex.weread.goal-native-direct-close-position-v1'
