#!/usr/bin/env python3
"""Check synthetic native MP export artifacts, without opening account stores."""
import argparse
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zipfile
import zlib

NS={'opf':'http://www.idpf.org/2007/opf','dc':'http://purl.org/dc/elements/1.1/',
    'html':'http://www.w3.org/1999/xhtml','container':'urn:oasis:names:tc:opendocument:xmlns:container'}


def bitmap(data):
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    at=8;compressed=[];kinds=[]
    while at<len(data):
        size=struct.unpack_from('>I',data,at)[0]
        kind=data[at+4:at+8];body=data[at+8:at+8+size]
        crc=struct.unpack_from('>I',data,at+8+size)[0]
        assert zlib.crc32(kind+body)&0xffffffff==crc, 'invalid PNG chunk CRC'
        kinds.append(kind)
        if kind==b'IHDR': assert struct.unpack('>IIBBBBB',body)==(64,32,8,2,0,0,0)
        if kind==b'IDAT': compressed.append(body)
        at+=size+12
    assert at==len(data) and kinds[0]==b'IHDR' and kinds[-1]==b'IEND'
    assert len(zlib.decompress(b''.join(compressed)))==32*(64*3+1)


def check(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'invalid ZIP CRC'
        entries=archive.infolist()
        assert entries[0].filename=='mimetype' and entries[0].compress_type==zipfile.ZIP_STORED and not entries[0].extra
        assert archive.read('mimetype')==b'application/epub+zip'
        with path.open('rb') as file: header=file.read(30)
        assert struct.unpack_from('<H',header,28)[0]==0, 'mimetype local extra field is forbidden'
        assert len({entry.filename for entry in entries})==len(entries), 'duplicate ZIP member'
        assert all(not name.startswith('/') and '..' not in name.split('/') for name in archive.namelist())
        container=ET.fromstring(archive.read('META-INF/container.xml'))
        rootfile=container.find('container:rootfiles/container:rootfile',NS)
        assert rootfile is not None and rootfile.attrib['full-path']=='EPUB/package.opf'
        package=ET.fromstring(archive.read('EPUB/package.opf'))
        assert package.attrib['version']=='3.0'
        assert package.find('opf:metadata/dc:identifier',NS).text.startswith('urn:sha256:')
        assert package.find('opf:metadata/dc:title',NS).text=='合成文章：离线导出'
        assert package.find('opf:metadata/dc:creator',NS).text=='合成公众号'
        manifest=package.find('opf:manifest',NS)
        items={item.attrib['id']:item.attrib for item in manifest}
        spine=package.find('opf:spine',NS)
        assert [row.attrib['idref'] for row in spine]==['article']
        assert items['nav']['properties']=='nav'
        for item in items.values():
            assert 'EPUB/'+item['href'] in archive.namelist()
        nav=ET.fromstring(archive.read('EPUB/nav.xhtml'))
        assert nav.find('.//html:a',NS).attrib['href']=='article.xhtml'
        article=ET.fromstring(archive.read('EPUB/article.xhtml'))
        assert '导出的合成正文 & 保留文字。' in ''.join(article.itertext())
        assert '图片暂不可用' in ''.join(article.itertext())
        assert article.find('.//html:strong',NS).text=='粗体测试'
        images=article.findall('.//html:img',NS)
        assert len(images)==3 and len({image.attrib['src'] for image in images})==2
        for image in images:
            href=image.attrib['src']
            assert href.startswith('images/') and archive.read('EPUB/'+href).startswith(b'\x89PNG\r\n\x1a\n')
            bitmap(archive.read('EPUB/'+href))
        for element in article.iter():
            assert element.tag.rsplit('}',1)[-1] not in ('script','iframe','svg','object')
            assert not any(key.startswith('on') for key in element.attrib)
        return {'crc_verified':True,'mimetype_first_stored_no_extra':True,'xml_well_formed':True,
            'container_manifest_spine_resolve':True,'unicode_metadata_and_text':True,
            'duplicate_images_share_member':True,'images_inside_archive':True,'missing_image_placeholders':True,
            'png_crc_and_pixels_verified':True,
            'passive_article_markup':True,'members':len(entries)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir',type=Path)
    args=parser.parse_args()
    files=sorted((args.run_dir/'profile/weread-mock/exports/articles').glob('*.epub'))
    assert len(files)==2, 'expected successful conversion and byte-preserving legacy copy'
    reports=[check(path) for path in files]
    assert files[0].read_bytes()==files[1].read_bytes(), 'legacy copy changed bytes'
    print(json.dumps(dict(result='PASS',synthetic_only=True,exported_files=len(files),legacy_copy_identical=True,checks=reports),indent=2))


if __name__=='__main__': main()
