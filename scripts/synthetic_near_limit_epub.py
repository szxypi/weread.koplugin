"""Stream a deterministic self-authored EPUB close to the 200 MiB limit."""
import zipfile
from synthetic_upload_epub import FILES

PADDING_BYTES=199*1024*1024
CHUNK=b'L'*65536


def _write(output,padding_bytes):
    if type(padding_bytes) is not int or not 1<=padding_bytes<=PADDING_BYTES:raise ValueError('near_epub/size')
    files=dict(FILES)
    files['EPUB/package.opf']=files['EPUB/package.opf'].replace(b'</manifest>',
        b'<item id="padding" href="padding.txt" media-type="text/plain"/></manifest>')
    with zipfile.ZipFile(output,'w',allowZip64=True) as archive:
        for name,body in files.items():
            info=zipfile.ZipInfo(name,date_time=(2020,1,1,0,0,0));info.compress_type=zipfile.ZIP_STORED
            info.create_system=3;info.external_attr=0o100644<<16;archive.writestr(info,body)
        info=zipfile.ZipInfo('EPUB/padding.txt',date_time=(2020,1,1,0,0,0));info.compress_type=zipfile.ZIP_STORED
        info.create_system=3;info.external_attr=0o100644<<16
        with archive.open(info,'w',force_zip64=False) as out:
            remaining=padding_bytes
            while remaining:
                part=CHUNK[:min(len(CHUNK),remaining)];out.write(part);remaining-=len(part)


def write_fixture(output):
    _write(output,PADDING_BYTES)
