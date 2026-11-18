"""Ordered private RPC messages for the CB supervisor; no network transport."""
from cb_native_time_bundle_supervisor import Supervisor
from readtime_upload_model import confirmed


class Bridge:
    def __init__(self,supervisor,source_path,*,armed=False):
        if type(armed) is not bool or not isinstance(supervisor,Supervisor):raise ValueError('cb_bridge/mode')
        self.supervisor,self.source_path,self.armed=supervisor,str(source_path),armed;self.phase='initial'
    def handle(self,event):
        try:
            if not isinstance(event,dict) or not isinstance(event.get('kind'),str):raise ValueError('cb_bridge/event')
            kind=event['kind']
            if self.phase=='initial' and kind=='selection' and set(event)=={'kind','selection'}:
                self.supervisor.select(event['selection']);self.phase='selected';return True
            if self.phase=='selected' and kind=='claim' and set(event)=={'kind','body','selection','record'}:
                args=(event['body'],event['selection'],event['record'],self.source_path)
                if self.armed:self.supervisor.claim(*args);self.phase='claimed';return True
                self.supervisor.preview(*args);self.phase='preview_blocked';return False
            if self.phase=='claimed' and kind=='ack' and set(event)=={'kind','status','response'}:
                if type(event['status']) is not int or event['status']!=200 or not confirmed(event['response']):raise ValueError('cb_bridge/receipt')
                self.supervisor.acknowledge(event['response']);self.phase='acknowledged';return True
            raise ValueError('cb_bridge/order')
        except BaseException:
            self.phase='stopped';raise
