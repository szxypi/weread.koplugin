"""One-shot, exact-fixture progress transport; never retries a write."""
from cb_fixture_position import STAGES,LONG_SUMMARY,body,canonical,validate
from verify_position_roundtrip import WRITE_URL,acknowledged
from verify_reader_progress import project
from verify_web_source_progress import BASE,WebSourceProbe


class Probe(WebSourceProbe):
    def __init__(self,plan,owner,authority):
        super().__init__();self.plan=plan;self.vid=owner;self.book_id=plan['book'];self.chapter=plan['chapter']
        self.owner=owner;self.authority=authority;self.attempted=0;self.pending=None

    def guard(self,stage,url,request):
        if stage in STAGES:
            if (not self.authenticated or self.vid!=self.owner or self.book_id!=self.plan['book']
                    or not self.authority() or not any(c.name=='wr_vid' and c.value==self.owner for c in self.cookies)
                    or url!=WRITE_URL or self.pending!=(stage,canonical(request)) or not 1<=self.attempted<=4
                    or STAGES[self.attempted-1]!=stage):raise ValueError('fixture_position/scope')
            validate(self.plan,stage,request);return
        return super().guard(stage,url,request)

    def send(self,stage):
        if self.attempted>=len(STAGES) or STAGES[self.attempted]!=stage:raise ValueError('fixture_position/order')
        value=body(self.plan,stage);self.pending=(stage,canonical(value));self.attempted+=1
        try:return self.request(stage,WRITE_URL,value)
        finally:self.pending=None

    def position(self):
        return project(self.request('progress_after',BASE+'/web/book/getProgress?bookId='+self.plan['book']),self.plan['book'])

    def execute(self,baseline):
        result=dict(result='UNVERIFIED',writes=0,source_position_verified=False,restored=False,
                    long_summary_retained_at_same=False,long_summary_retained_at_probe=False,long_summary_retained_at_restore=False)
        try:
            before=self.position()
            if (str(before.get('chapter_uid'))!=str(baseline.get('chapter_uid')) or before['chapter_offset']!=baseline['chapter_offset']
                    or before['raw_percent']!=baseline['raw_percent']):raise ValueError('fixture_position/baseline_changed')
            if not acknowledged(self.send('enter')):raise ValueError('fixture_position/unconfirmed')
            entered=self.position()
            entered_uid=str(entered.get('chapter_uid'))
            if not (entered_uid=='0' and entered['chapter_offset']==0 and entered['raw_percent']==0
                    or entered_uid==self.plan['chapter'] and entered['chapter_offset']==self.plan['first']):
                raise ValueError('fixture_position/unexpected')
            if not acknowledged(self.send('same')):raise ValueError('fixture_position/unconfirmed')
            same=self.position()
            if str(same.get('chapter_uid'))!=self.plan['chapter'] or same['chapter_offset']!=self.plan['first']:
                raise ValueError('fixture_position/position')
            result['long_summary_retained_at_same']=same['summary']==LONG_SUMMARY
            if not acknowledged(self.send('probe')):raise ValueError('fixture_position/unconfirmed')
            probe=self.position()
            if str(probe.get('chapter_uid'))!=self.plan['chapter'] or probe['chapter_offset']!=self.plan['following']:
                raise ValueError('fixture_position/position')
            result.update(source_position_verified=True,long_summary_retained_at_probe=probe['summary']==LONG_SUMMARY)
            if not acknowledged(self.send('restore')):raise ValueError('fixture_position/unconfirmed')
            restored=self.position()
            if str(restored.get('chapter_uid'))!=self.plan['chapter'] or restored['chapter_offset']!=self.plan['first']:
                raise ValueError('fixture_position/position')
            result.update(result='PASS',restored=True,long_summary_retained_at_restore=restored['summary']==LONG_SUMMARY)
        except Exception:
            pass
        result['writes']=self.attempted
        return result
