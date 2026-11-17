"""Immutable native-statistics window and exact EPUB; no dispatch capability."""
from contextlib import nullcontext
import base64,hashlib,io,json,re,stat,tempfile,zipfile
from urllib.parse import unquote
from pathlib import Path
from annotation_experiment_model import canonical
from readtime_history_capture import next_cst_day
from readtime_upload_model import integer
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from secure_native_session import project_lock
from secure_highlight_trial import Receipt

SERVICE='org.codex.weread.goal-native-statistics-time-capture-v1'
PROTOCOL='native-statistics-epub-historical-window-v1'
MAX_ARCHIVE=32768
FIELDS={'protocol','owner','baseline_sha256','device_sha256','book_id','chapter_uid','chapter_idx','book_version','file_id','raw_sha256',
        'rows','start_time','ended_at','monotonic_elapsed_ms','seconds','not_before','archive_base64','archive_sha256'}
ROW_FIELDS={'id','book_id','start_time','duration','time_zone','book_version','file_id','version_source'}

def hashed(v):return isinstance(v,str) and re.fullmatch('[a-f0-9]{64}',v) is not None

def validate(p):
    if not isinstance(p,dict) or set(p)!=FIELDS or p['protocol']!=PROTOCOL:raise ValueError('native_capture/plan')
    if (any(not isinstance(p[k],str) or not re.fullmatch('[1-9][0-9]{0,19}',p[k]) for k in ('owner','book_id','chapter_uid'))
            or any(not hashed(p[k]) for k in ('baseline_sha256','device_sha256','file_id','raw_sha256','archive_sha256'))
            or not integer(p['book_version'],1,2147483647) or not integer(p['chapter_idx'],0,1000000)
            or not integer(p['start_time'],1,4102358398) or not integer(p['ended_at'],p['start_time']+5,p['start_time']+12)
            or not integer(p['monotonic_elapsed_ms'],5000,12000)
            or abs(p['ended_at']-p['start_time']-p['monotonic_elapsed_ms']/1000)>1.25
            or not integer(p['seconds'],5,12) or p['not_before']!=next_cst_day(p['start_time'])+1
            or next_cst_day(p['ended_at'])!=next_cst_day(p['start_time'])
            or not isinstance(p['rows'],list) or not 1<=len(p['rows'])<=12):raise ValueError('native_capture/plan')
    previous=p['start_time'];seen=set();total=0
    for r in p['rows']:
        if (not isinstance(r,dict) or set(r)!=ROW_FIELDS or not integer(r['id'],1,2**53-1) or r['id'] in seen
                or any(r[k]!=p[k] for k in ('book_id','book_version','file_id')) or r['time_zone']!='+08:00'
                or r['version_source']!='epub_snapshot' or not integer(r['start_time'],previous,p['ended_at']-1)
                or not integer(r['duration'],1,p['ended_at']-r['start_time'])):raise ValueError('native_capture/rows')
        previous=r['start_time']+r['duration'];seen.add(r['id']);total+=r['duration']
    if total!=p['seconds'] or total!=p['ended_at']-p['start_time']:raise ValueError('native_capture/seconds')
    try:
        if not isinstance(p['archive_base64'],str) or len(p['archive_base64'])>4*((MAX_ARCHIVE+2)//3):raise ValueError()
        archive=base64.b64decode(p['archive_base64'],validate=True)
        if not 1<=len(archive)<=MAX_ARCHIVE or hashlib.sha256(archive).hexdigest()!=p['archive_sha256']:raise ValueError()
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            if len(z.infolist())>128 or len({i.filename for i in z.infolist()})!=len(z.infolist()):raise ValueError()
            if (sum(i.file_size for i in z.infolist())>8*1024*1024 or any(i.file_size>2*1024*1024 or i.flag_bits&1
                    or Path(i.filename).is_absolute() or '..' in Path(i.filename).parts or '\\' in i.filename
                    or stat.S_IFMT(i.external_attr>>16) not in (0,stat.S_IFREG,stat.S_IFDIR) for i in z.infolist())):raise ValueError()
            identity=z.read('OEBPS/weread-source.txt').decode()
            lines=dict(line.split('=',1) for line in identity.splitlines())
            if len(identity.splitlines())!=6 or set(lines)!={'schema','book_id','book_version','chapter_count','text_digest','source_id'} or lines['schema']!='1' or lines['chapter_count']!='1' or not hashed(lines['text_digest']):raise ValueError()
            if lines.get('book_id')!=p['book_id'] or lines.get('source_id')!=p['file_id'] or lines.get('book_version')!=str(p['book_version']):raise ValueError()
            if identity!=identity.rsplit('source_id=',1)[0]+'source_id='+p['file_id']+'\n' or hashlib.sha256(identity.rsplit('source_id=',1)[0].encode()).hexdigest()!=p['file_id']:raise ValueError()
            keys=('schema','book_id','chapter_uid','format','raw_bytes','raw_sha256','capture_id','book_version','file_id','render_path','render_sha256')
            encoded=z.read('OEBPS/weread-position/uid-'+hashlib.sha256(p['chapter_uid'].encode()).hexdigest()+'.meta').decode()
            values=dict(line.split('=',1) for line in encoded.splitlines())
            body=''.join(k+'='+values[k]+'\n' for k in keys)
            if encoded!=body+'metadata_sha256='+hashlib.sha256(body.encode()).hexdigest()+'\n':raise ValueError()
            receipt=''.join(k+'='+values[k]+'\n' for k in keys[:6])
            if values['capture_id']!=hashlib.sha256(receipt.encode()).hexdigest() or values['schema']!='1' or values['format']!='web_txt':raise ValueError()
            if any(unquote(values[k])!=str(p[k]) for k in ('book_id','chapter_uid','book_version','file_id','raw_sha256')):raise ValueError()
            raw=z.read('OEBPS/weread-position/raw-'+p['raw_sha256']+'.txt')
            if len(raw)!=int(values['raw_bytes']) or hashlib.sha256(raw).hexdigest()!=p['raw_sha256']:raise ValueError()
            render_path=unquote(values['render_path'])
            if not render_path.startswith('OEBPS/text/') or '..' in Path(render_path).parts:raise ValueError()
            rendered=z.read(render_path)
            if hashlib.sha256(rendered).hexdigest()!=values['render_sha256']:raise ValueError()
    except (Exception,):raise ValueError('native_capture/archive') from None
    return p

class NativeCaptureStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-statistics-time-capture-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=65536:raise ValueError()
            v=json.loads(raw)
            if set(v)!={'schema','scope','phase','plan'} or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT or v['phase']!='captured':raise ValueError()
            validate(v['plan']);return v,raw
        except Exception:raise StoreError('native_capture/invalid') from None
    def read(self):
        with self.lock():
            v,raw=self._load();return v,Receipt(raw) if raw else None
    def capture(self,plan):
        validate(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('native_capture/already_captured')
            raw=canonical(dict(schema=1,scope=ACCOUNT,phase='captured',plan=plan))
            if len(raw)>65536:raise StoreError('native_capture/size')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('native_capture/readback')
            self._load();return Receipt(raw)
