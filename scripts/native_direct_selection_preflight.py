"""Bind a fresh-selection trial to the same authorized E-Ink XHTML chapter.

This module has no account-data write operation. Source bytes and the selected
text are returned to the supervising process and must not be logged.
"""
from hashlib import sha256
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards
from native_chapter_package import password,read
from owner_selection_preview import validate_reference
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_translation_preflight import catalog,catalog_body


def bind_native_source(selection,credentials,*,probe=None):
    """Verify entitlement, version, source bytes, and the independently chosen reference."""
    selection.current()
    payload=selection.payload;cfg=payload['selection_preview'];row=cfg['reference']
    book=payload['book_id'];uid=payload['chapter_uid']
    validate_reference(row,book,uid)
    native=probe or ChapterProbe();native.allowed={book}
    info=native.request('book',BASE+'/book/info?'+urlencode({'bookId':book}),credentials=credentials)
    raw_catalog=native.request('catalog',BASE+'/book/chapterInfos',catalog_body(book),credentials=credentials)
    model=catalog(raw_catalog,book,info)
    matches=[chapter for chapter in model['chapters'] if str(chapter['uid'])==uid]
    version=cfg['body']['bookVersion']
    if (model['format']!='epub' or type(version) is not int or model['version']!=version or len(matches)!=1
            or not matches[0].get('free_or_owned') or matches[0].get('wordCount',0)<1):
        raise ValueError('direct_selection_preflight/chapter')
    fields=dict(bookId=book,chapters='0,'+uid,bookType='epub',bookVersion=version,
        pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,
        stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
    native.archive_url=BASE+'/book/chapterdownload?'+urlencode(fields)
    archive,envelope=native.download(native.archive_url,credentials)
    decoded=read(archive,password(envelope,credentials['vid']),uid)
    web=decode_content_shards(*(selection.web.shards[key] for key in ('e_0','e_1','e_3'))).encode()
    if not decoded['html'] or decoded['source']!=web or sha256(web).hexdigest()!=row['source']['raw_sha256']:
        raise ValueError('direct_selection_preflight/source')
    selection.current()
    return {'source_sha256':sha256(web).hexdigest(),'book_version':version,'book_id':book,'uid':uid,'source':web}
