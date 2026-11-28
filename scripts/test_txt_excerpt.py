"""Exact TXT slicing boundaries; never contacts an account or enables sync."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from txt_coordinates import PlainSource, CoordinateError
import verify_txt_excerpt as task


class ExcerptTests(unittest.TestCase):
    def test_literal_markup_bom_and_line_endings_are_not_normalized(self):
        raw='\ufeffA\r\n　 <tag>&amp;😀e\u0301末尾'
        model=PlainSource(raw)
        self.assertEqual(model.excerpt(0)['text'],raw)
        self.assertEqual(model.excerpt(2,4)['text'],'\r\n　 ')
        self.assertEqual(model.excerpt(6,11)['text'],'<tag>&amp;😀')
        self.assertEqual(model.excerpt(6,11)['end_co'],18)

    def test_nonbmp_counts_as_one_scalar_but_two_source_units(self):
        value=PlainSource('A😀中').excerpt(1,1)
        self.assertEqual((value['text'],value['co'],value['end_co'],value['scalars']),('😀',1,3,1))
        self.assertFalse(value['upload_verified'])
        with self.assertRaises(CoordinateError):PlainSource('A😀中').excerpt(2)

    def test_tail_is_bounded_and_empty_end_is_rejected(self):
        self.assertEqual(PlainSource('abc').excerpt(2)['text'],'c')
        with self.assertRaises(CoordinateError):PlainSource('abc').excerpt(3)

    def test_invalid_offsets_and_limits_are_rejected(self):
        for co in (-1,True,1.5,'1',float('nan'),100):
            with self.subTest(co=co),self.assertRaises(CoordinateError):PlainSource('abc').excerpt(co)
        for limit in (0,513,True,1.5,'1',None):
            with self.subTest(limit=limit),self.assertRaises(CoordinateError):PlainSource('abc').excerpt(0,limit)

    def test_maximum_scalar_limit_does_not_split_multibyte_text(self):
        result=PlainSource('😀'*600).excerpt(0,512)
        self.assertEqual(len(result['text'].encode()),2048)
        self.assertEqual(result['end_co'],1024)

    def test_invalid_source_fails_before_projection(self):
        for raw in ('','A\x00B','A\ud800B','x'*(2*1024*1024+1)):
            with self.subTest(length=len(raw)),self.assertRaises(CoordinateError):PlainSource(raw)

    def test_private_comparison_validates_complete_reply(self):
        model=PlainSource('literal <tag>&amp;😀\r\n尾');selected=task.queries(model)
        def run(command,**kwargs):
            self.assertEqual(command,['synthetic-lua']);self.assertEqual(kwargs['timeout'],60)
            self.assertEqual(json.loads(kwargs['input'])['raw'],model.raw)
            return SimpleNamespace(returncode=0,stdout=json.dumps(dict(result='PASS',excerpts=[model.excerpt(q['co'],q['limit']) for q in selected])).encode())
        task.compare(model,selected,['synthetic-lua'],run)
        self.assertLessEqual(len(selected),64)

    def test_bad_reply_or_child_failure_cannot_verify(self):
        for raw,code in ((b'private diagnostic',0),(b'{}',0),(b'x'*262145,0),(b'{}',1)):
            with self.subTest(code=code),self.assertRaises(ValueError):
                task.compare(PlainSource('abc'),[dict(co=0,limit=30)],['synthetic-lua'],lambda *a,**kw:SimpleNamespace(returncode=code,stdout=raw))

    def test_default_does_not_load_session_and_private_errors_are_hidden(self):
        with patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        with patch.object(task,'SessionStore',side_effect=ValueError('private credential')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--lua-command','synthetic-lua']),1)
        self.assertNotIn('private credential',out.getvalue())


if __name__=='__main__':unittest.main()
