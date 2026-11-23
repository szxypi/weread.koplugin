import copy
import unittest

from run_native_direct_batch_owner import validate


class ScopeValidation(unittest.TestCase):
    def setUp(self):
        self.payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
            refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
            web_cookies={'wr_vid':'12345678', 'wr_skey':'synthetic-web-access'},
            mock_endpoint='http://127.0.0.1:1234', book_id='42', version=1, total=2,
            sources={'37':dict(sha256='a'*64, token='synthetic')})

    def rejected(self, mutate):
        payload = copy.deepcopy(self.payload)
        mutate(payload)
        with self.assertRaises(ValueError): validate(payload)

    def test_valid_and_endpoint_bound_to_synthetic_credentials(self):
        self.assertIs(validate(self.payload), self.payload)
        self.rejected(lambda value: value.update(mock_endpoint='http://127.0.0.1:70000'))
        self.rejected(lambda value: value.update(mock_endpoint='https://example.com'))
        self.rejected(lambda value: value['credentials'].update(accessToken='real-secret'))

    def test_chapter_scope_and_sources_are_bounded(self):
        self.rejected(lambda value: value.update(book_id='../42'))
        self.rejected(lambda value: value.update(total=0))
        self.rejected(lambda value: value.update(sources={}))
        self.rejected(lambda value: value['sources'].update({'0':dict(sha256='a'*64)}))
        self.rejected(lambda value: value['sources']['37'].update(sha256='invalid'))
        self.rejected(lambda value: value['sources']['37'].update(token='bad\nsecret'))

    def test_shelf_scope_requires_unique_valid_books_and_target(self):
        self.payload.update(full_shelf=True, shelf_books=[dict(bookId='42', title='Book', author='Writer')])
        self.assertIs(validate(self.payload), self.payload)
        self.rejected(lambda value: value['shelf_books'].append(dict(bookId='42', title='Other', author='Writer')))
        self.rejected(lambda value: value['shelf_books'][0].update(bookId='100'))
        self.rejected(lambda value: value['shelf_books'][0].update(title='bad\ntitle'))
        self.rejected(lambda value: value.update(full_shelf=False))


if __name__ == '__main__':
    unittest.main()
