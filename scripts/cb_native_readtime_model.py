"""CB_ time-only native batch payload; no network or dispatch authority."""
from readtime_upload_model import batch as numeric_batch,sign,validate_rows
from verify_cb_progress import cb_id


def batch(credentials,book_id,rows,guest,config_token,now,random,outer_timestamp,outer_random,*,current_zone,summary=None):
    if not cb_id(book_id):raise ValueError('cb_native_time/identity')
    validate_rows(rows,'1',now)
    value=numeric_batch(credentials,'1',rows,guest,config_token,now,random,outer_timestamp,outer_random,current_zone=current_zone)
    book=value['books'][0];book['bookId']=book_id
    parts=[credentials['vid'],book['deviceId'],'',book_id,'0',book['recordCreateTimeZone'],str(book['readingTime']),'0']
    parts.extend('_'.join(str(hour[key]) for key in ('startOfHour','timeZone','readingTime','ttsTime')) for hour in book['hours'])
    book['signature']=sign([guest,str(random),str(now),'_'.join(parts)])
    if summary is not None:
        if (not isinstance(summary,str) or not 1<=len(summary)<=512 or len(summary.encode('utf-8'))>2048
                or any(ord(char)<32 and char not in '\t\n\r' for char in summary)):
            raise ValueError('cb_native_time/summary')
        book['summary']=summary
    return value
