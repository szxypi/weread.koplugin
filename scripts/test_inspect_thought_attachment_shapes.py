import unittest

from inspect_thought_attachment_shapes import classify_url,shape,summarize


class AttachmentShapeTests(unittest.TestCase):
    def test_shape_counts_never_include_private_values(self):
        rows=[{'review':{'content':'private body','htmlContent':'<p>x</p><img src="secret">',
            'pictures':[{'url':'https://weread-picture-1258476243.file.myqcloud.com/private','width':123},'https://outside.test/secret'],
            'pencilNote':{'imageUrl':'https://weread-picture-1258476243.file.myqcloud.com/private',
                'drawingUrl':'','imageWidth':123}}}]
        counts,pictures,pencil,urls=summarize(rows)
        self.assertEqual(counts['rows'],1);self.assertEqual(counts['html_with_image'],1)
        self.assertEqual(pictures['url_string'],1);self.assertEqual(pencil['imageUrl_string'],1)
        self.assertEqual(urls['weread_picture_bucket'],2);self.assertEqual(urls['other'],1)
        self.assertNotIn('private',repr((counts,pictures,pencil,urls)))
    def test_unknown_types_are_not_interpreted(self):
        self.assertEqual(shape(True),'boolean');self.assertEqual(classify_url('https://bad.test@evil.test/a'),'other')
        self.assertEqual(summarize([{'review':{'pictures':{},'pencilNote':[]}}])[0]['pictures_empty_object'],1)
        with self.assertRaises(ValueError):summarize([{'review':{'pictures':[None]*101}}])


if __name__=='__main__':unittest.main()
