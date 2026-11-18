"""Pure synthetic-only safeguards for an isolated CB position experiment."""
import copy
import unittest
from cb_fixture_position import LONG_SUMMARY,STAGES,body,plan,validate
from synthetic_upload_epub import TEXT


def fixture():
    book='CB_SyntheticPosition';chapter='9'
    source='<html><body><p>'+TEXT+'</p></body></html>'
    sample=dict(book_id=book,chapter_uid=chapter,source_format='web_xhtml',source=source,
        baseline=dict(chapter='0',offset=0,percent=0),chapters=[dict(chapterUid=chapter,chapterIdx=1)],
        context=dict(book_id=book,psvts='synthetic',pclts='synthetic',token='synthetic',
                     progress=dict(book=dict(bookId=book,chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0))))
    return book,sample


class TestFixturePosition(unittest.TestCase):
    def test_fixture_plan_binds_original_and_one_character(self):
        book,sample=fixture();value=plan(book,sample)
        self.assertEqual(value['following'],value['first']+1)
        for stage in STAGES:
            request=body(value,stage);self.assertTrue(validate(value,stage,request))
            self.assertEqual(request['sm'],LONG_SUMMARY);self.assertGreater(len(request['sm']),20)
            self.assertEqual(request['co'],value['following'] if stage=='probe' else value['first'])
            if stage!='enter':self.assertEqual(request['rt'],0)

    def test_source_account_chapter_and_unstarted_gates(self):
        book,sample=fixture()
        mutations=[dict(book_id='CB_Other'),dict(source='not the fixture'),dict(source_format='web_txt'),
                   dict(chapters=[]),dict(baseline=dict(chapter='3',offset=2,percent=1))]
        for update in mutations:
            with self.subTest(update=update),self.assertRaises((ValueError,TypeError)):
                plan(book,dict(sample,**update))
        bad=copy.deepcopy(sample);bad['context']['book_id']='CB_Other'
        with self.assertRaises(ValueError):plan(book,bad)
        bad=copy.deepcopy(sample);bad['context']['progress']['book']['chapterOffset']=1
        with self.assertRaises(ValueError):plan(book,bad)
        bad=copy.deepcopy(sample);bad['chapters'][0].pop('chapterIdx')
        with self.assertRaises(ValueError):plan(book,bad)

    def test_tampering_or_other_target_is_refused(self):
        book,sample=fixture();value=plan(book,sample)
        for stage in STAGES:
            initial=body(value,stage)
            for key,bad in (('b','foreign'),('c','foreign'),('co',999),('sm','other'),('pr',3),('s','other')):
                changed=dict(initial);changed[key]=bad
                with self.subTest(stage=stage,key=key),self.assertRaises(ValueError):validate(value,stage,changed)


if __name__=='__main__':unittest.main()
