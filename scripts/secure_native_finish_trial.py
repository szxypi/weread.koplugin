"""A distinct native finished-mark intent with two reserved slots, no replay."""
from native_finish_trial import validate_plan
from secure_native_shelf_trial import NativeShelfTrialStore


class NativeFinishTrialStore(NativeShelfTrialStore):
    service='org.codex.weread.goal-native-finish-trial'
    lock_prefix='codex-native-finish-'
    validator=staticmethod(validate_plan)
