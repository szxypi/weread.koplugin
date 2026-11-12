"""Distinct two-slot raw-summary trial, with original recovery only in Keychain."""
from secure_native_txt_roundtrip import NativeTxtRoundtripStore,validate_binding,POINT_FIELDS
from secure_weread_session import StoreError


PROTOCOL='native-txt-literal-raw-30-zero-time-v1'


def validate_plan(plan):
    validate_binding(plan,PROTOCOL)
    before,target=plan['baseline'],plan['target']
    if (any(before[k]!=target[k] for k in POINT_FIELDS-{'chapter_offset','summary'})
            or target['chapter_offset']!=before['chapter_offset']+1 or len(target['summary'])!=30):
        raise StoreError('raw_txt_excerpt/plan')


class RawTxtExcerptStore(NativeTxtRoundtripStore):
    service='org.codex.weread.goal-native-txt-raw-excerpt-v1'
    protocol=PROTOCOL

    def __init__(self,backend=None,lock=None):
        super().__init__(backend,lock)

    def validate_plan(self,plan):
        validate_plan(plan)
