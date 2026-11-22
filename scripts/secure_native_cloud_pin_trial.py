"""Independent two-slot native pin intent, retained after successful completion."""
from native_cloud_pin_trial import validate_plan
from secure_native_shelf_flag_trial import NativeFlagTrialStore


class NativeCloudPinTrialStore(NativeFlagTrialStore):
    service='org.codex.weread.goal-native-cloud-pin-v1'
    lock_prefix='codex-native-cloud-pin-'
    validator=staticmethod(validate_plan)
