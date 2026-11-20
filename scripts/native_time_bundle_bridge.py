"""Strict private messages between a native worker and its one-shot guard.

No network I/O is performed here. A caller must provide an authenticated,
bounded private channel and a separately scoped native HTTP transport.
"""
import base64,binascii
from readtime_upload_model import confirmed
from native_time_bundle_supervisor import NativeBoundSupervisor


class NativeTimeBridge:
    def __init__(self,guard,source_path,*,armed=False,remote=False):
        if type(armed) is not bool or type(remote) is not bool or not isinstance(guard,NativeBoundSupervisor):raise ValueError('native_bridge/mode')
        self.guard,self.source_path,self.armed,self.remote=guard,str(source_path),armed,remote
        self.phase='initial'

    def handle(self,event):
        """Return permission only after the corresponding durable guard step."""
        try:
            if not isinstance(event,dict) or not isinstance(event.get('kind'),str):raise ValueError('native_bridge/event')
            kind=event['kind']
            if self.phase=='initial' and kind=='selection' and set(event)=={'kind','selection'}:
                self.guard.select(event['selection']);self.phase='selected';return True
            fields={'kind','body','selection','record'}|({'archive_base64'} if self.remote else set())
            if self.phase=='selected' and kind=='claim' and set(event)==fields:
                archive=None
                if self.remote:
                    encoded=event['archive_base64']
                    if not isinstance(encoded,str) or not 1<=len(encoded)<=2796204:raise ValueError('native_bridge/archive')
                    try:archive=base64.b64decode(encoded,validate=True)
                    except (ValueError,binascii.Error):raise ValueError('native_bridge/archive') from None
                    if not 1<=len(archive)<=2*1024*1024:raise ValueError('native_bridge/archive')
                args=(event['body'],event['selection'],event['record'],self.source_path)
                if self.armed:
                    self.guard.claim(*args,archive=archive);self.phase='claimed';return True
                self.guard.preview(*args,archive=archive);self.phase='preview_blocked';return False
            if self.phase=='claimed' and kind=='ack' and set(event)=={'kind','status','response'}:
                if type(event['status']) is not int or event['status']!=200 or not confirmed(event['response']):
                    raise ValueError('native_bridge/receipt')
                self.guard.acknowledge(event['response']);self.phase='acknowledged';return True
            raise ValueError('native_bridge/order')
        except BaseException:
            self.phase='stopped'
            raise
