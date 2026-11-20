"""Exact-scope, no-replay Web position trial for one existing imported book."""
from copy import deepcopy
from cb_cloud_position import observed
from cb_existing_position_intent import STAGES
from fetch_weread_epub import sorted_query,weread_sign
from verify_position_roundtrip import RoundTripProbe,WRITE_URL,acknowledged,canonical,payload,validate_payload
from verify_web_source_progress import BASE


def signed_body(plan,stage):
    value=payload(plan,stage)
    point=plan['target'] if stage=='write_probe' else plan['baseline']
    value['sm']=point['summary']
    value['s']=weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'}))
    validate_payload(plan,stage,value)
    return value


def target_observation(original,offset):
    value=deepcopy(original)
    value['state']['chapter_offset']=offset
    value['projection']['chapter_offset']=offset
    return value


class Probe(RoundTripProbe):
    def __init__(self,plan,owner,chapters,intent,reservation):
        super().__init__();self.plan=plan;self.vid=owner;self.scope_vid=owner
        self.book_id=plan['book_id'];self.chapter=str(plan['baseline']['chapter_uid'])
        self.chapters=chapters;self.intent=intent;self.reservation=reservation;self.mode='probe';self.receipt=None

    def guard(self,stage,url,body):
        if stage in STAGES:
            if not self.intent.verify(self.reservation,self.receipt):raise ValueError('cb_existing/authority')
        return super().guard(stage,url,body)

    def send(self,stage):
        if self.writes>=len(STAGES) or STAGES[self.writes]!=stage:raise ValueError('cb_existing/order')
        value=signed_body(self.plan,stage)
        self.receipt=self.intent.claim(self.reservation,stage)
        self.pending=(stage,canonical(value));self.writes+=1
        try:
            self.guard(stage,WRITE_URL,value)
            return self.request(stage,WRITE_URL,value)
        finally:self.pending=None

    def position_observation(self):
        raw=self.request('progress_after',BASE+'/web/book/getProgress?bookId='+self.book_id)
        return observed(raw,self.book_id,self.chapters,'web')

    def execute(self,baseline):
        result=dict(result='UNVERIFIED',writes=0,entered=False,same=False,advanced=False,restored=False)
        try:
            if self.position_observation()!=baseline:raise ValueError('cb_existing/baseline')
            target=target_observation(baseline,self.plan['target']['chapter_offset'])
            current=baseline
            for stage,key,expected in (('write_enter','entered',baseline),('write_same','same',baseline),
                                       ('write_probe','advanced',target),('write_restore','restored',baseline)):
                if self.position_observation()!=current:raise ValueError('cb_existing/concurrent')
                if not acknowledged(self.send(stage)):raise ValueError('cb_existing/ack')
                if self.position_observation()!=expected:raise ValueError('cb_existing/observation')
                current=expected;result[key]=True
            result['result']='PASS'
        except Exception:
            pass
        result['writes']=self.writes
        return result
