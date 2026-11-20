"""Distinct ReaderUI two-slot trial; original recovery data stays in Keychain."""
from secure_native_txt_roundtrip import NativeTxtRoundtripStore,validate_binding,POINT_FIELDS
from secure_weread_session import StoreError

PROTOCOL='native-reader-literal-raw-30-zero-time-v1'


def validate_plan(plan):
    validate_binding(plan,PROTOCOL);before,target=plan['baseline'],plan['target']
    if (any(before[k]!=target[k] for k in POINT_FIELDS-{'chapter_offset','summary','raw_percent'})
            or target['chapter_offset']!=before['chapter_offset']+1 or len(target['summary'])!=30
            or type(target['raw_percent']) is not int or plan['chapter_progress'] is not None):
        raise StoreError('reader_trial/plan')


class NativeReaderTrialStore(NativeTxtRoundtripStore):
    service='org.codex.weread.goal-native-reader-position-v1'
    protocol=PROTOCOL

    def validate_plan(self,plan):validate_plan(plan)
