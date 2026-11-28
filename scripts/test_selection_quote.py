import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
from selection_quote import Selection


class SelectionTests(unittest.TestCase):
    def select(self,raw,quote):
        model=Selection(raw);at=model.flat.index(''.join(quote.split()))
        first=model.filtered.starts[model.visible[at]];last=model.filtered.ends[model.visible[at+len(''.join(quote.split()))-1]]
        return model,first,last,model.project(first,last,quote)

    def test_entities_unicode_and_raw_rune_ranges(self):
        raw='\ufeff<html><head><title>Hidden title</title></head><body><p>前言&amp;😀选中的文字&#x1F642;结尾</p></body></html>'
        model,first,last,result=self.select(raw,'&😀选中的文字🙂')
        source=raw.removeprefix('\ufeff');self.assertEqual(result['range'],f"{source.index('&amp;')}-{source.index('结尾')}")
        self.assertEqual(result['abstract'],'&😀选中的文字🙂')
        self.assertNotEqual(first,int(result['range'].split('-')[0]))
        with self.assertRaisesRegex(ValueError,'boundary'):model.project(first,last-1,'&😀选中的文字🙂')

    def test_cross_elements_and_native_layout_whitespace(self):
        raw='<body><p>选中<b>跨标签</b>文字</p><p>\n另一个段落。</p></body>'
        _,_,_,result=self.select(raw,'选中跨标签文字\n另一个段落。')
        self.assertEqual(result['abstract'],'选中跨标签文字\n另一个段落。')

    def test_repeated_text_uses_positions(self):
        raw='<body><p>相同的引用文字</p><p>相同的引用文字</p></body>';model=Selection(raw)
        n=7;first=model.filtered.starts[model.visible[n]];last=model.filtered.ends[model.visible[-1]]
        result=model.project(first,last,'相同的引用文字');self.assertGreater(int(result['range'].split('-')[0]),raw.index('</p>'))

    def test_selection_mismatch_and_invalid_boundaries(self):
        model,first,last,_=self.select('<body><p>文字&amp;实体测试</p></body>','文字&实体测试')
        for start,end,text in ((True,last,'文字&实体测试'),(first,first,'文字&实体测试'),(first,last,'其他文字'),(first,last,''),(first,last,'x'*4097)):
            with self.assertRaises(ValueError):model.project(start,end,text)
        entity=model.filtered.starts[model.visible[2]]
        with self.assertRaisesRegex(ValueError,'boundary'):model.project(entity+1,last,'&实体测试')

    def test_server_range_roundtrip_with_edge_whitespace(self):
        raw='<body><p>\n 测试引用的正文内容。 \n</p></body>'
        row=dict(range=f"{raw.index(chr(10))}-{raw.index('</p>')}",markText='测试引用的正文内容。')
        _,result=Selection(raw).from_mark(row);self.assertEqual(result['abstract'],row['markText'])

    def test_nonvisible_and_malformed_sources(self):
        for raw in ('','plain text','<body>missing close','<body>abc\x00</body>'):
            with self.assertRaises(ValueError):Selection(raw)


class VerifierTests(unittest.TestCase):
    def test_offline_does_not_touch_stores_or_network(self):
        import verify_selection_quote as verifier
        with patch.object(verifier.target,'main') as remote,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(verifier.main([]),0)
        remote.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def verify(self,*,index=3,lua=None):
        import verify_selection_quote as verifier
        raw='<body><p>Unique selected text and following content.</p></body>'
        start=raw.index('Unique');row=dict(type=1,chapterUid=2,chapterIdx=index,range=f'{start}-{start+20}',markText='Unique selected text')
        def preflight(_args):
            verifier.target.inspect(None)
            verifier.target.project(raw,'41','2',row)
            print(json.dumps(dict(result='MY_MARK_TARGET_PROTOTYPE_VERIFIED')));return 0
        with patch.object(verifier.target,'main',side_effect=preflight),patch.object(verifier.target,'inspect',return_value=(dict(chapter_uid='2',chapter_idx=3),{})),\
                patch.object(verifier,'subprocess') as subprocess,redirect_stdout(io.StringIO()) as out:
            original=verifier.target.inspect
            subprocess.run.return_value=lua
            code=verifier.main(['--saved-session']+(['--lua-command','synthetic'] if lua else []))
            self.assertIs(verifier.target.inspect,original)
        return code,json.loads(out.getvalue()),out.getvalue()

    def test_real_shape_roundtrip_and_index_proof(self):
        code,report,_=self.verify();self.assertEqual(code,0);self.assertEqual(report['selections'],1)
        self.assertEqual(report['native_and_web_chapter_indices_compared'],1);self.assertFalse(report['data_write_permission'])

    def test_disagreeing_index_stops(self):
        code,report,_=self.verify(index=4);self.assertEqual(code,1);self.assertEqual(report['result'],'UNVERIFIED')

    def test_child_failure_never_echoes_private_output(self):
        code,report,text=self.verify(lua=SimpleNamespace(returncode=1,stdout=b'private-quotation'))
        self.assertEqual(code,1);self.assertEqual(report['result'],'UNVERIFIED');self.assertNotIn('private-quotation',text)


if __name__=='__main__':unittest.main()
