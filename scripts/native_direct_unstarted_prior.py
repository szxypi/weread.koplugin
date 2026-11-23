"""Bind the next time-only sample to completed, immutable earlier trials."""
from native_time_capture_evidence import account_key
from ordinary_unstarted_ui_prior import PreviousSamples


class PriorSamples:
    def __init__(self,old_time,old_position,ui_time,ui_position):
        self.old=PreviousSamples(old_time,old_position)
        self.ui_time_store=ui_time;self.ui_position_store=ui_position
        self.ui_time,self.ui_time_raw=ui_time.read();self.ui_position,self.ui_position_raw=ui_position.read()
        if (not self.ui_time or not self.ui_position or self.ui_time.get('phase')!='verified'
                or self.ui_position.get('phase')!='verified' or not isinstance(self.ui_time_raw,bytes)
                or not isinstance(self.ui_position_raw,bytes)):
            raise ValueError('direct_unstarted/prior')
    def check(self,grant,book=None,selection=None):
        if self.ui_time_store.read()!=(self.ui_time,self.ui_time_raw) or self.ui_position_store.read()!=(self.ui_position,self.ui_position_raw):
            raise ValueError('direct_unstarted/prior_changed')
        try:
            timing=self.ui_time['plan'];position=self.ui_position['plan'];source=timing['record']['source']
            owner=account_key(grant['vid']);old_book=self.old.time['plan']['record']['source']['book_id']
            self.old.check(grant,source,dict(protocol_rows=[timing['selection']]))
            if (timing['record']['owner']!=owner or timing['selection']['duration']!=2
                    or len(timing['body']['books'])!=1 or timing['body']['books'][0]['bookId']!=source['book_id']
                    or timing['body']['books'][0]['readingTime']!=2 or position['record']['account']!=owner
                    or position['selection']['book_id']!=source['book_id']
                    or position['selection']['source_sha256']!=source['source_sha256']
                    or book is not None and book in (old_book,source['book_id'])):
                raise ValueError('direct_unstarted/prior')
            if selection is not None:
                rows=selection['protocol_rows']
                if (not isinstance(rows,list) or not rows or type(self.ui_position['claimed_at']) is not int
                        or any(type(row.get('start_time')) is not int or row['start_time']<self.ui_position['claimed_at'] for row in rows)):
                    raise ValueError('direct_unstarted/interval')
        except (KeyError,TypeError,IndexError,AttributeError):raise ValueError('direct_unstarted/prior') from None
        return True
