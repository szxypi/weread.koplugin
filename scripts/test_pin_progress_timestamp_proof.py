import copy
import unittest
from pin_progress_timestamp_proof import matches_except_update_time
from verify_pin_preflight import progress_fingerprint


class TimestampProofTests(unittest.TestCase):
    def setUp(self):
        self.old={'bookId':'synthetic','book':{'chapterUid':0,'chapterOffset':0,'updateTime':100,'extra':'keep'},'timestamp':1}
        self.current=copy.deepcopy(self.old);self.current['book']['updateTime']=110;self.current['timestamp']=2
        self.digest=progress_fingerprint(self.old)
    def test_recovers_only_update_time_within_bounded_range(self):
        self.assertTrue(matches_except_update_time(self.current,self.digest,newest=110,window=10))
        self.assertFalse(matches_except_update_time(self.current,self.digest,newest=110,window=9))
    def test_change_in_other_field_cannot_match(self):
        self.current['book']['chapterOffset']=1
        self.assertFalse(matches_except_update_time(self.current,self.digest,newest=110,window=10))
    def test_extra_or_missing_field_cannot_match(self):
        self.current['future']='unknown'
        self.assertFalse(matches_except_update_time(self.current,self.digest,newest=110,window=10))
    def test_bad_input_fails_closed(self):
        for value in (True,-1,None,'100'):
            self.current['book']['updateTime']=value
            with self.subTest(value=value),self.assertRaises(ValueError):
                matches_except_update_time(self.current,self.digest,newest=110,window=10)
        self.current['book']['updateTime']=110
        with self.assertRaises(ValueError):matches_except_update_time(self.current,'x',newest=110,window=10)


if __name__=='__main__':unittest.main()
