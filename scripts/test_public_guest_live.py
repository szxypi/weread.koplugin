import unittest

from run_public_guest_live import valid_stage


class PublicGuestReportTests(unittest.TestCase):
    def test_requires_complete_guarded_guest_flow(self):
        stage=dict(result='PASS',phase='complete',mode='live',requests=3,first=20,second=20,
                   guest=True,native_host=True,detail=True,public_intro=True,manual_refresh=True,metadata_requests=2,forbidden=0)
        self.assertTrue(valid_stage(stage,0,False))
        for changes in ({'guest':False},{'native_host':False},{'detail':False},{'public_intro':False},{'manual_refresh':False},{'metadata_requests':3},
                        {'requests':4},{'forbidden':1},{'first':0},{'second':True},{'result':'UNVERIFIED'},
                        {'extra':'unexpected'}):
            with self.subTest(changes=changes):
                self.assertFalse(valid_stage(dict(stage,**changes),0,False))
        self.assertFalse(valid_stage(stage,1,False))
        self.assertFalse(valid_stage(stage,0,True))
        self.assertFalse(valid_stage(None,0,False))
        offline=dict(stage,mode='reopen',requests=0,metadata_requests=0,first=0,second=0,manual_refresh=False)
        self.assertTrue(valid_stage(offline,0,False,'reopen'))
        self.assertFalse(valid_stage(dict(offline,requests=1),0,False,'reopen'))
        self.assertFalse(valid_stage(dict(offline,metadata_requests=1),0,False,'reopen'))
        self.assertFalse(valid_stage(offline,0,False,'live'))


if __name__=='__main__':
    unittest.main()
