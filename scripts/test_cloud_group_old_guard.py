"""The old sealed empty-group attempt remains read-only and isolated."""
from copy import deepcopy
import unittest

from cloud_group_contract import digest, project
from cloud_group_journal import Journal
from cloud_group_old_guard import Guard
from test_cloud_group_journal import Memory
from test_secure_native_session import credentials


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.shelf={'books':[{'bookId':'42','title':'Synthetic'}],
            'archive':[{'archiveId':2,'name':'Existing','bookIds':['42'],'albumIds':[]}],'albums':[]}
        projected=project(self.shelf);self.name='KOReader-Test-'+'a'*24;self.journal=Journal(backend=Memory())
        token=self.journal.begin(self.grant['vid'],digest(self.grant),self.name,digest(projected),digest(projected))
        token=self.journal.advance(token,'create_claimed')
        self.journal.close_unchanged(token,[(projected,projected),(projected,projected)])
        self.pair=lambda:{'native':deepcopy(self.shelf),'web':deepcopy(self.shelf)}
        self.guard=Guard(self.journal,None,self.grant,lambda:True,self.pair)

    def test_allow_fixture_only_when_baseline_not_required(self):
        self.assertEqual(len(self.guard.check(True)),2)
        self.shelf['books'].append({'bookId':'CB_Synthetic','title':'Fixture'})
        self.assertEqual(len(self.guard.check(False)),2)
        with self.assertRaises(ValueError):self.guard.check(True)

    def test_delayed_group_and_unstable_reads_refuse(self):
        self.shelf['archive'].append({'archiveId':43,'name':self.name,'bookIds':[],'albumIds':[]})
        with self.assertRaises(ValueError):self.guard.check(False)
        self.shelf['archive'].pop(); count=[0]
        def unstable():
            value=self.pair();count[0]+=1
            if count[0]==2:value['web']['books'][0]['finishReading']=1
            return value
        self.guard.read_pair=unstable
        with self.assertRaises(ValueError):self.guard.check(False)


if __name__=='__main__':unittest.main()
