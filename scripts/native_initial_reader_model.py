"""Separate native ReaderUI scope; the old Python sender scope is immutable."""
from copy import deepcopy
from native_initial_position import validate_plan as prior_validate,PROTOCOL as PRIOR
from secure_weread_session import StoreError
PROTOCOL='native-reader-first-chapter-raw-30-zero-time-v1'


def validate_plan(value):
    if not isinstance(value,dict) or value.get('protocol')!=PROTOCOL:raise StoreError('initial_reader/protocol')
    selected=deepcopy(value);selected['protocol']=PRIOR
    prior_validate(selected);selected['protocol']=PROTOCOL;return selected
