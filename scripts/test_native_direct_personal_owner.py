import unittest

from verify_native_direct_personal_owner import verify_rows


class PersonalOwnerComparisonTests(unittest.TestCase):
    def setUp(self):
        self.raw=b'<html><body><p>Unique owner comparison quote.</p></body></html>'
        first=self.raw.index(b'Unique');self.marker=f'{first}-{first+len(b"Unique owner comparison quote.")}'
        self.base={'marks':{'updated':{'one':{'type':1,'chapterUid':2,'range':self.marker,'markText':'Unique owner comparison quote.'}}}}
        self.row={'id':'one','range':self.marker,'text':'Unique owner comparison quote.'}
    def test_actual_text_must_match_independent_source_and_saved_mark(self):
        self.assertTrue(verify_rows(self.raw,self.base,'2',[self.row]))
        self.assertFalse(verify_rows(self.raw,self.base,'2',[dict(self.row,text='Other content')]))
        self.assertFalse(verify_rows(self.raw,self.base,'3',[self.row]))
        self.assertFalse(verify_rows(self.raw.replace(b'Unique',b'Other!'),self.base,'2',[self.row]))
        self.assertFalse(verify_rows(self.raw,self.base,'2',[self.row,self.row]))
        self.assertFalse(verify_rows(self.raw,self.base,'2',[dict(self.row,id='other')]))
        self.assertFalse(verify_rows(self.raw,self.base,'2',[]))


if __name__=='__main__':unittest.main()
