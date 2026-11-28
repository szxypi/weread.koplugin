import unittest

from verify_native_direct_position_owner import independent_offset,independent_selection
from verify_source_coordinates import FilteredSource
from run_native_direct_position_owner import synthetic_endpoint_allowed


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

    def test_selection_quote_is_checked_against_independent_raw_range(self):
        raw=b'<html><body><p>Exact synthetic selection.</p></body></html>'
        first=raw.decode().index('synthetic');last=first+len('synthetic')
        selection=dict(ok=True,selection='synthetic',quote='synthetic',range=f'{first}-{last}')
        self.assertTrue(independent_selection(raw,selection))
        selection['range']=f'{first+1}-{last}';self.assertFalse(independent_selection(raw,selection))
        selection['range']=f'{first}-{last}';selection['selection']='different';self.assertFalse(independent_selection(raw,selection))
        selection['selection']='synthetic';selection['extra']=True;self.assertFalse(independent_selection(raw,selection))

    def test_mock_endpoint_cannot_receive_real_credentials(self):
        payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
            deviceId='eink334691225'+'0'*19),web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'})
        self.assertTrue(synthetic_endpoint_allowed(payload,None))
        self.assertTrue(synthetic_endpoint_allowed(payload,'http://127.0.0.1:1234'))
        self.assertFalse(synthetic_endpoint_allowed(payload,'https://example.com:1234'))
        self.assertFalse(synthetic_endpoint_allowed(payload,'http://127.0.0.1:65536'))
        payload['credentials']['accessToken']='different'
        self.assertFalse(synthetic_endpoint_allowed(payload,'http://127.0.0.1:1234'))


if __name__=='__main__':unittest.main()
