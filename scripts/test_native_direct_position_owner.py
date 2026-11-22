import unittest

from verify_native_direct_position_owner import independent_offset
from verify_source_coordinates import FilteredSource


class NativeDirectPositionOwnerTests(unittest.TestCase):
    def fixture(self):
        raw='<html><body><p>Unique paragraph with 汉字 and emoji 😀 in the original.</p></body></html>'.encode()
        model=FilteredSource(raw.decode())
        visible=[index for index,char in enumerate(model.characters) if not char.isspace()]
        text=''.join(model.characters[index] for index in visible)
        point=text.index('😀')
        return raw,dict(ok=True,text=text,point_offset=point,offset=model.starts[visible[point]])

    def test_independent_visible_unicode_offset(self):
        raw,position=self.fixture()
        self.assertTrue(independent_offset(raw,position))
        position['offset']+=1
        self.assertFalse(independent_offset(raw,position))

    def test_refuses_foreign_text_and_invalid_descriptor(self):
        raw,position=self.fixture()
        position['text']='totallydifferenttext'
        self.assertFalse(independent_offset(raw,position))
        position['text']=''
        self.assertFalse(independent_offset(raw,position))
        position['offset']='1'
        self.assertFalse(independent_offset(raw,position))

    def test_ambiguous_duplicate_source_is_rejected(self):
        raw,position=self.fixture()
        paragraph=raw.decode().split('<body>',1)[1].split('</body>',1)[0]
        duplicate=('<html><body>'+paragraph+paragraph+'</body></html>').encode()
        self.assertFalse(independent_offset(duplicate,position))


if __name__=='__main__':unittest.main()
