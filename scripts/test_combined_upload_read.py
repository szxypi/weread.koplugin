"""The continuous profile gate only opens for a bounded, matching target."""
from copy import deepcopy
import unittest
from run_combined_upload_read import validate_gate
from test_owner_reading import stage
from verify_owner_reading import validate_stage

TARGET='CB_SyntheticResume'


def gate():
    return dict(seq=1,ok=True,payload=dict(book_id=TARGET,chapter_uid='1',source_format='web_xhtml',
        source_text='Synthetic source text long enough for native matching.',source_raw_sha256='a'*64,source_sample_offset=0,
        shelf_ids=['900001',TARGET],shelf_books=2,cb_reading=True,vid='900000',
        cookies=dict(wr_vid='900000',wr_skey='mock_key'),combined_upload_read=True,cb_mock_port=123))


class CombinedGateTest(unittest.TestCase):
    def test_gate_rejects_wrong_identity_owner_or_unbounded_input(self):
        self.assertEqual(validate_gate(gate(),TARGET,'900000',123)['book_id'],TARGET)
        changes=(('book_id','CB_other'),('vid','900001'),('chapter_uid','0'),('source_text','short'),
                 ('source_raw_sha256','invalid'),('source_sample_offset',True),('shelf_books',3),('combined_upload_read',False),
                 ('shelf_ids',[TARGET,TARGET]),('cb_mock_port',124))
        for key,value in changes:
            bad=gate();bad['payload'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate_gate(bad,TARGET,'900000',123)
        for value in (dict(gate(),seq=True),dict(gate(),ok=False),dict(gate(),extra=True)):
            with self.assertRaises(ValueError):validate_gate(value,TARGET,'900000',123)

    def test_cached_shelf_mode_does_not_weaken_reader_or_offline_checks(self):
        value=stage();value['source_match_reason']='none';value['requests'][0]=0
        self.assertEqual(validate_stage(value,'live',cb_reading=True,combined_profile=True),value)
        with self.assertRaises(ValueError):validate_stage(value,'live',cb_reading=True)
        with self.assertRaises(ValueError):validate_stage(value,'live',combined_profile=True)
        for field in ('source_receipt_verified','native_reader','page_turn','source_text_visible'):
            bad=deepcopy(value);bad[field]=False
            with self.subTest(field=field),self.assertRaises(ValueError):validate_stage(bad,'live',cb_reading=True,combined_profile=True)


if __name__=='__main__':unittest.main()
