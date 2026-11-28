"""Independent owner-copy input projection; offline and synthetic."""
from contextlib import redirect_stdout
import io,json,unittest
from unittest.mock import patch
from verify_owner_cloud_group_copy import main,prepare


class OwnerCopyTests(unittest.TestCase):
    def shelf(self):
        return dict(books=[dict(bookId='101',title='One',author='A'),dict(bookId='102',title='Two',author='B')],
            archive=[dict(archiveId=7,name='Group',bookIds=['101','missing','MP_WXS_1','101']),
                     dict(archiveId=8,name='Empty',bookIds=[]),dict(archiveId=9,name='MP',bookIds=['MP_WXS_2'])])
    def test_preserves_missing_and_deduplicates_only_ordinary_members(self):
        # The independent shelf validator rejects duplicate raw membership;
        # this case uses a valid response instead.
        shelf=self.shelf();shelf['archive'][0]['bookIds'].remove('101')
        payload=prepare(shelf)
        self.assertEqual(payload['expected'],[dict(label='Group',members=['missing','101']),dict(label='Empty',members=[])])
        self.assertNotIn('author',payload['books'][0])
    def test_ambiguous_labels_and_invalid_ids_fail(self):
        shelf=self.shelf();shelf['archive'][0]['bookIds']=['101'];shelf['archive'][1]['name']='Group'
        with self.assertRaises(ValueError):prepare(shelf)
        shelf=self.shelf();shelf['archive'][0]['bookIds']=['101','101']
        with self.assertRaises(ValueError):prepare(shelf)
    def test_imported_and_missing_members_are_preserved(self):
        shelf=self.shelf();shelf['books'].append(dict(bookId='CB_Synthetic',title='Imported'))
        shelf['archive'][0]['bookIds']=['101','CB_Synthetic','CB_Missing','MP_WXS_1']
        payload=prepare(shelf)
        self.assertEqual(payload['expected'][0]['members'],['101','CB_Synthetic','CB_Missing'])
    def test_offline_default_reads_no_credentials_or_network(self):
        output=io.StringIO()
        with patch('verify_owner_cloud_group_copy.SessionStore') as store,redirect_stdout(output):self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
