"""Synthetic vectors cross-checked against Tencent's official COS SDK."""
import unittest
from copy import deepcopy
from cos_signature import MAX_BYTES,sign


def fixture():return dict(bucket='synthetic-12345',ObjectName='/prefix/example-book.txt',Response=dict(ExpiredTime=1700000300,
    Credentials=dict(TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token')))


class SignatureTest(unittest.TestCase):
    def test_official_sdk_vector(self):
        result=sign(fixture(),17,1700000000)
        self.assertEqual(result['url'],'https://synthetic-12345.cos.accelerate.myqcloud.com/prefix/example-book.txt')
        self.assertTrue(result['headers']['Authorization'].endswith('q-signature=127e92ff67702f58765c060e886c87f666623ae8'))
        self.assertEqual(result['headers']['x-cos-security-token'],'synthetic-token')
    def test_unicode_path_and_escaped_token(self):
        value=fixture();value['ObjectName']='/示例/书.txt';value['Response']['Credentials']['Token']='synthetic+/=token'
        result=sign(value,17,1700000000)
        self.assertEqual(result['url'],'https://synthetic-12345.cos.accelerate.myqcloud.com/%E7%A4%BA%E4%BE%8B/%E4%B9%A6.txt')
        self.assertTrue(result['headers']['Authorization'].endswith('q-signature=f0cf1aa839d0ac5b8ad4fee57a574c5280bf9239'))
    def test_invalid_host_token_path_size_and_expiration_refused(self):
        for kind in ('host','path','traversal','secret','expiry','large','bool'):
            value=deepcopy(fixture());size=17
            if kind=='host':value['bucket']='foreign.invalid'
            elif kind=='path':value['ObjectName']='//foreign'
            elif kind=='traversal':value['ObjectName']='/a/../b'
            elif kind=='secret':value['Response']['Credentials']['Token']='bad\nvalue'
            elif kind=='expiry':value['Response']['ExpiredTime']=1700000030
            elif kind=='large':size=MAX_BYTES+1
            else:size=True
            with self.subTest(kind=kind),self.assertRaises(ValueError):sign(value,size,1700000000)


if __name__=='__main__':unittest.main()
