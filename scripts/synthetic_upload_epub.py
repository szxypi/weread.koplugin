"""A deterministic, self-authored EPUB fixture for bounded upload validation."""
import io,zipfile

TEXT=('This synthetic chapter verifies that an uploaded book can be opened in the native reader. '
      'Every sentence in this fixture was written for this test and contains no private information.')
FILES={
    'mimetype':b'application/epub+zip',
    'META-INF/container.xml':b'''<?xml version="1.0" encoding="utf-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
    'EPUB/package.opf':b'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:84fb7e4e-063a-4c0b-8ef5-91fb5089c2fb</dc:identifier><dc:title>Synthetic Upload Verification</dc:title><dc:language>en</dc:language><dc:creator>KOReader Test</dc:creator><meta property="dcterms:modified">2020-01-01T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>''',
    'EPUB/nav.xhtml':b'''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en"><head><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol><li><a href="chapter.xhtml">Synthetic chapter</a></li></ol></nav></body></html>''',
    'EPUB/chapter.xhtml':('''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>Synthetic chapter</title></head><body><h1>Synthetic chapter</h1><p>'''+TEXT+'''</p></body></html>''').encode(),
}


def _archive(files):
    output=io.BytesIO()
    with zipfile.ZipFile(output,'w') as archive:
        for path,body in files.items():
            info=zipfile.ZipInfo(path,date_time=(2020,1,1,0,0,0));info.compress_type=zipfile.ZIP_STORED
            info.create_system=3;info.external_attr=0o100644<<16;archive.writestr(info,body)
    return output.getvalue()


def build():return _archive(FILES)


def build_large():
    files=dict(FILES)
    files['EPUB/package.opf']=files['EPUB/package.opf'].replace(b'</manifest>',
        b'<item id="padding" href="padding.txt" media-type="text/plain"/></manifest>')
    files['EPUB/padding.txt']=b'L'*(9*1024*1024)
    return _archive(files)
