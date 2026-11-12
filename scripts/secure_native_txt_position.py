"""A distinct one-request native position test, not a time-ledger grant."""
from secure_txt_zero_time import TxtZeroTimeStore


class NativeTxtPositionStore(TxtZeroTimeStore):
    service='org.codex.weread.goal-native-txt-position-v1'
    protocol='native-txt-same-point-zero-time-v1'
