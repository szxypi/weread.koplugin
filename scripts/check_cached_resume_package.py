#!/usr/bin/env python3
"""Independently check the six synthetic HTTP chapters in a full native EPUB."""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import unquote
from xml.etree import ElementTree as ET
import zipfile

from mock_weread import CHAPTERS, chapter_html, chapter_txt


def inspect_package(path, kind):
    if kind not in ('epub','txt') or Path(path).stat().st_size > 32*1024*1024:
        raise ValueError('package_limit')
    with zipfile.ZipFile(path) as archive:
        names=archive.namelist()
        if (len(names)>1024 or len(set(names))!=len(names)
                or sum(item.file_size for item in archive.infolist())>32*1024*1024 or archive.testzip() is not None):
            raise ValueError('package_invalid')
        rendered=[]
        for chapter in CHAPTERS:
            uid=str(chapter['chapterUid'])
            name='OEBPS/weread-position/uid-'+hashlib.sha256(uid.encode()).hexdigest()+'.meta'
            raw_metadata=archive.read(name)
            if len(raw_metadata)>4096:
                raise ValueError('metadata_limit')
            body,seal=raw_metadata.rsplit(b'metadata_sha256=',1)
            if hashlib.sha256(body).hexdigest().encode()+b'\n'!=seal:
                raise ValueError('metadata_seal')
            fields=dict(line.split('=',1) for line in body.decode().splitlines())
            if fields['chapter_uid']!=uid or fields['book_id']!='900001' or fields['format']!='web_'+('txt' if kind=='txt' else 'xhtml'):
                raise ValueError('source_scope')
            raw=archive.read('OEBPS/weread-position/raw-'+fields['raw_sha256']+'.txt')
            expected=(chapter_txt if kind=='txt' else chapter_html)(int(uid)).encode()
            if raw!=expected or len(raw)!=int(fields['raw_bytes']) or hashlib.sha256(raw).hexdigest()!=fields['raw_sha256']:
                raise ValueError('source_mismatch')
            member=unquote(fields['render_path'])
            if hashlib.sha256(archive.read(member)).hexdigest()!=fields['render_sha256']:
                raise ValueError('render_mismatch')
            alias='OEBPS/weread-position/path-'+hashlib.sha256(member.encode()).hexdigest()+'.meta'
            if archive.read(alias)!=raw_metadata:
                raise ValueError('source_alias')
            rendered.append(member)
        ns={'p':'http://www.idpf.org/2007/opf'}
        opf=ET.fromstring(archive.read('OEBPS/content.opf'))
        manifest={item.attrib['id']:'OEBPS/'+item.attrib['href'] for item in opf.findall('p:manifest/p:item',ns)}
        spine=[manifest[item.attrib['idref']] for item in opf.findall('p:spine/p:itemref',ns)]
        cover_pages=int(bool(spine) and spine[0]=='OEBPS/text/cover.xhtml')
        if cover_pages:
            spine=spine[1:]
        if spine!=rendered:
            raise ValueError('chapter_order')
    return dict(result='PASS',synthetic_only=True,content_format=kind,raw_chapters_matched=len(rendered),
                metadata_seals_verified=len(rendered),rendered_members_verified=len(rendered),cover_pages=cover_pages,
                spine_order_verified=True,zip_crc_ok=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path',type=Path)
    parser.add_argument('--format',choices=('epub','txt'),default='epub')
    args=parser.parse_args()
    try:
        report=inspect_package(args.path,args.format)
    except Exception:
        report=dict(result='FAIL',reason='synthetic_package_unverified')
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='PASS' else 1


if __name__=='__main__':
    raise SystemExit(main())
