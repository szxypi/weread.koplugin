import unittest
from verify_translation_baseline_lua import position_presence


class TranslationBaselinePresenceTests(unittest.TestCase):
    def test_recorded_and_unrecorded_are_distinct(self):
        self.assertTrue(position_presence({'native':{'point':{}},'web':{'point':{}},'counts':{}}))
        value={'kind':'explicit-unrecorded-translation-baseline-v1',
            'native':{'position_present':False},'web':{'position_present':False}}
        self.assertFalse(position_presence(value))
        value['web']['position_present']=True
        with self.assertRaises(ValueError):position_presence(value)

    def test_unknown_or_incomplete_is_not_a_recorded_position(self):
        for value in ({},{'native':{},'web':{}}, {'kind':'unknown','native':{'point':{}},'web':{'point':{}},'counts':{}},
            {'native':{'point':{}},'web':{'point':{}}}):
            with self.assertRaises(ValueError):position_presence(value)


if __name__=='__main__':unittest.main()
