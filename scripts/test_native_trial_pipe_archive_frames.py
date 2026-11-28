"""Large private archive frames require an explicit bounded allowance."""
import json,os,threading,unittest

from native_trial_pipe import Frames,MAX_INPUT


class PrivateFrameTests(unittest.TestCase):
    def receive(self,limit):
        token='a'*32;payload={'archive_base64':'Y'*20000}
        raw=('WEREAD_NATIVE_THOUGHT_'+token+'_STEP='+json.dumps(payload)+'\n').encode()
        read_fd,write_fd=os.pipe()
        def writer():
            try:
                with os.fdopen(write_fd,'wb',buffering=0) as output:output.write(raw)
            except BrokenPipeError:pass
        thread=threading.Thread(target=writer);thread.start()
        try:
            with os.fdopen(read_fd,'rb',buffering=0) as reader:
                frames=Frames(reader,token,timeout=5,**({} if limit is None else {'max_frame':limit}))
                if limit is None:
                    with self.assertRaises(ValueError):frames.next()
                else:self.assertEqual(frames.next(),('STEP',payload))
        finally:thread.join(timeout=5)
        self.assertFalse(thread.is_alive())

    def test_large_frame_only_when_explicitly_enabled(self):
        self.receive(None);self.receive(30000)

    def test_bounds_reject_boolean_or_unbounded_limits(self):
        for limit in (True,0,MAX_INPUT+1):
            with self.subTest(limit=limit),self.assertRaises(ValueError):Frames(None,'a'*32,max_frame=limit)


if __name__=='__main__':unittest.main()
