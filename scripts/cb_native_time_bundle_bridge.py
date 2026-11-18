"""Ordered private RPC messages for the CB supervisor; no network transport.

Remote mode relies on a trusted isolated relay to read the actual private file
and recheck it before forwarding approval. It does not authenticate the caller.
"""
import base64,binascii
from cb_native_time_bundle_supervisor import Supervisor
from readtime_upload_model import confirmed


class Bridge:
    def __init__(self,supervisor,source_path,*,armed=False,remote=False):
        if type(armed) is not bool or type(remote) is not bool or not isinstance(supervisor,Supervisor):raise ValueError('cb_bridge/mode')
        self.supervisor,self.source_path,self.armed,self.remote=supervisor,str(source_path),armed,remote;self.phase='initial'
    def handle(self,event):
        try:
            if not isinstance(event,dict) or not isinstance(event.get('kind'),str):raise ValueError('cb_bridge/event')
            kind=event['kind']
            if self.phase=='initial' and kind=='selection' and set(event)=={'kind','selection'}:
                self.supervisor.select(event['selection']);self.phase='selected';return True
            fields={'kind','body','selection','record'}|({'archive_base64'} if self.remote else set())
            if self.phase=='selected' and kind=='claim' and set(event)==fields:
                archive=None
                if self.remote:
                    encoded=event['archive_base64']
                    if not isinstance(encoded,str) or not 1<=len(encoded)<=2796204:raise ValueError('cb_bridge/archive')
                    try:archive=base64.b64decode(encoded,validate=True)
                    except (ValueError,binascii.Error):raise ValueError('cb_bridge/archive') from None
                    if not 1<=len(archive)<=2*1024*1024:raise ValueError('cb_bridge/archive')
                args=(event['body'],event['selection'],event['record'],self.source_path)
                if self.armed:self.supervisor.claim(*args,archive=archive);self.phase='claimed';return True
                self.supervisor.preview(*args,archive=archive);self.phase='preview_blocked';return False
            if self.phase=='claimed' and kind=='ack' and set(event)=={'kind','status','response'}:
                if type(event['status']) is not int or event['status']!=200 or not confirmed(event['response']):raise ValueError('cb_bridge/receipt')
                self.supervisor.acknowledge(event['response']);self.phase='acknowledged';return True
            raise ValueError('cb_bridge/order')
        except BaseException:
            self.phase='stopped';raise
