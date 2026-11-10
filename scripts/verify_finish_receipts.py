#!/usr/bin/env python3
"""Revised finishReading receipt hypothesis; offline unless --saved-session.

Read-only preview never writes. A newly authorized --apply --expected-plan may
attempt the same bounded mark/read/restore/read protocol as the legacy probe.
The receipt must contain the requested integer finishReading flag, with no
contradictory known error/success/identity fields; independent full shelf and
source-position checks remain mandatory. This is not yet real-write verified.

Schema reference (not proof of success semantics): weread-omni, MIT,
88bd2e095d7d7ee423eaadf8f40653e72c5be6d4, src/api/types.ts and
src/api/resources/shelf.ts. Only request/response field names are referenced.
"""
from verify_eink_renewal import book_id
from verify_finish_roundtrip import FinishProbe,digest,main as run_main


POLICY='finish-reading-integer-v1'
FIELDS=('succ','success','errcode','errCode','status','finishReading','bookId','book_id')


def receipt_matches(value,desired,identity):
    """A candidate flag receipt, never sufficient without independent GETs.

    status has no verified success meaning and is not used as an ACK. In
    particular status=1 and a generic succ=1 cannot replace finishReading.
    """
    if (not isinstance(value,dict) or type(desired) is not bool
            or not isinstance(identity,str) or book_id(identity)!=identity):return False
    if type(value.get('finishReading')) is not int or value['finishReading']!=int(desired):return False
    if any(key in value and not (value[key] is None or type(value[key]) is int and value[key]==0)
           for key in ('errcode','errCode')):return False
    if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1):return False
    if 'success' in value and value['success'] is not True:return False
    return all(key not in value or book_id(value[key])==identity for key in ('bookId','book_id'))


def flag_enum(value):
    return str(value) if type(value) is int and value in (0,1) else 'invalid'


class FinishReadingProbe(FinishProbe):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        self.report['receipt_policy']=POLICY

    def plan_fingerprint(self):
        # An earlier preview or a different policy cannot authorize this plan.
        return digest(dict(receipt_policy=POLICY,plan=self.plan.bound))

    def receipt_shape(self,response,desired):
        shape=dict(known_fields=[key for key in FIELDS if key in response],
                   other_fields_count=len(set(response)-set(FIELDS)),
                   finish_reading_enum=flag_enum(response['finishReading']) if 'finishReading' in response else 'absent',
                   finish_reading_matches_requested=type(response.get('finishReading')) is int
                       and response['finishReading']==int(desired),
                   returned_book_id=any(key in response for key in ('bookId','book_id')))
        if shape['returned_book_id']:
            shape['returned_book_id_matches']=all(key not in response or book_id(response[key])==self.plan.bound['book_id']
                                                  for key in ('bookId','book_id'))
        # Bounded diagnostic enum only. Never retain other status values,
        # unknown fields, titles, IDs, timestamps or raw response text.
        shape['status_enum']=('absent' if 'status' not in response else str(response['status'])
                              if type(response['status']) is int and 0<=response['status']<=15 else 'invalid')
        return shape

    def accept_receipt(self,response,desired):
        return receipt_matches(response,desired,self.plan.bound['book_id'])


def main(argv=None):
    return run_main(argv,probe_factory=FinishReadingProbe,description=__doc__)


if __name__=='__main__':raise SystemExit(main())
