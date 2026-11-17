"""Strict private messages between a native worker and its one-shot guard.

No network I/O is performed here. A caller must provide an authenticated,
bounded private channel and a separately scoped native HTTP transport.
"""
from readtime_upload_model import confirmed
from native_time_bundle_supervisor import NativeBoundSupervisor


class NativeTimeBridge:
    def __init__(self,guard,source_path,*,armed=False):
        if type(armed) is not bool or not isinstance(guard,NativeBoundSupervisor):raise ValueError('native_bridge/mode')
        self.guard,self.source_path,self.armed=guard,str(source_path),armed
        self.phase='initial'

    def handle(self,event):
        """Return permission only after the corresponding durable guard step."""
        try:
            if not isinstance(event,dict) or not isinstance(event.get('kind'),str):raise ValueError('native_bridge/event')
            kind=event['kind']
            if self.phase=='initial' and kind=='selection' and set(event)=={'kind','selection'}:
                self.guard.select(event['selection']);self.phase='selected';return True
            if self.phase=='selected' and kind=='claim' and set(event)=={'kind','body','selection','record'}:
                args=(event['body'],event['selection'],event['record'],self.source_path)
                if self.armed:
                    self.guard.claim(*args);self.phase='claimed';return True
                self.guard.preview(*args);self.phase='preview_blocked';return False
            if self.phase=='claimed' and kind=='ack' and set(event)=={'kind','status','response'}:
                if type(event['status']) is not int or event['status']!=200 or not confirmed(event['response']):
                    raise ValueError('native_bridge/receipt')
                self.guard.acknowledge(event['response']);self.phase='acknowledged';return True
            raise ValueError('native_bridge/order')
        except BaseException:
            self.phase='stopped'
            raise
