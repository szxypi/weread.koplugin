"""Distinct one-request TXT zero-time trial; v1 enter cannot be replayed."""
from secure_txt_full_summary import TxtFullSummaryStore


class TxtZeroTimeStore(TxtFullSummaryStore):
    service='org.codex.weread.goal-txt-zero-time-v1'
    protocol='txt-full-summary-zero-time-v1'
    phases={'prepared':0,'same_pending':1,'retired':1,'closed_same_unverified':1,'aborted':0}
    transitions={('prepared','same_pending'),('same_pending','retired'),('same_pending','closed_same_unverified'),('prepared','aborted')}
