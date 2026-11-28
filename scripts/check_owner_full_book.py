"""Inspect a private full-book EPUB in the runner's disposable memory profile."""
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import posixpath
import re
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree as ET
import zipfile


class Node:
    def __init__(self, tag, attrs=(), parent=None, raw=''):
        self.tag,self.attrs,self.parent,self.raw=tag,dict(attrs),parent,raw
        self.children=[]

    def descendants(self):
        for child in self.children:
            if isinstance(child,Node):
                yield child
                yield from child.descendants()

    def text(self):
        if self.tag in ('head','script','style','template'):
            return ''
        return ' '.join(child.text() if isinstance(child,Node) else child for child in self.children)

    def ancestor(self, tag):
        current=self.parent
        while current:
            if current.tag==tag:return current
            current=current.parent


class Images(HTMLParser):
    VOID={'area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root=Node('root');self.stack=[self.root];self.ids={};self.saw_body=False

    def handle_starttag(self, tag, attrs):
        node=Node(tag,attrs,self.stack[-1],self.get_starttag_text());self.stack[-1].children.append(node)
        if node.attrs.get('id'):self.ids.setdefault(node.attrs['id'],[]).append(node)
        if tag=='body':self.saw_body=True
        if tag not in self.VOID:self.stack.append(node)

    def handle_endtag(self, tag):
        for index in range(len(self.stack)-1,0,-1):
            if self.stack[index].tag==tag:
                self.stack=self.stack[:index];break

    def handle_data(self, value):
        self.stack[-1].children.append(value)

    @property
    def image_nodes(self):
        return [node for node in self.root.descendants() if node.tag in ('img','image')
                and not any(node.ancestor(tag) for tag in ('head','script','style','template'))
                and (not self.saw_body or node.ancestor('body'))]

    @property
    def sources(self):
        return [node.attrs.get('src','') if node.tag=='img' else node.attrs.get('href',node.attrs.get('xlink:href',''))
                for node in self.image_nodes]

    @property
    def text_runs(self):
        result=[]
        for node in [self.root,*self.root.descendants()]:
            if node.tag in ('head','script','style','template') or any(node.ancestor(tag) for tag in ('head','script','style','template')):continue
            if self.saw_body and node.tag!='body' and not node.ancestor('body'):continue
            result.extend(normalized_text(item) for item in node.children if isinstance(item,str) and len(normalized_text(item))>=32)
        return result


def normalized_text(value):
    return ' '.join(value.replace('\u200b','').replace('\u200c','').replace('\u200d','').split())


def note_text(node):
    for name in ('alt','title','data-content','data-note'):
        match=re.search(r'\s'+name+r'\s*=\s*([\'\"])(.*?)\1',node.raw,re.I|re.S)
        if match:
            parser=Images();parser.feed(match.group(2))
            value=normalized_text(parser.root.text())
            for prefix in (r'^\[\s*\d+\s*\]\s*',r'^\(\s*\d+\s*\)\s*',r'^（\s*\d+\s*）\s*',r'^\*+\s*',r'^[†‡※]\s*'):
                value=re.sub(prefix,'',value,count=1)
            return value.strip()
    return ''


def verified_note_images(original, rendered, uid):
    """Only a verified native footnote can account for a removed marker image."""
    converted=set();ordinal=0;image_ids={id(node) for node in original.image_nodes}
    def unique(key):
        nodes=rendered.ids.get(key,[])
        return nodes[0] if len(nodes)==1 else None
    def native_reference(ref, target):
        return (ref is not None and target is not None and ref.tag=='a'
                and (not rendered.saw_body or ref.ancestor('body') and target.ancestor('body'))
                and not any(node.ancestor(tag) for node in (ref,target) for tag in ('head','script','style','template'))
                and ref.attrs.get('href')=='#'+target.attrs.get('id','')
                and 'noteref' in ref.attrs.get('epub:type','').split()
                and target.tag=='aside' and 'footnote' in target.attrs.get('epub:type','').split()
                and any(node.tag=='a' and node.attrs.get('href')=='#'+ref.attrs.get('id','') for node in target.descendants()))
    for node in original.image_nodes:
        classes=set(node.attrs.get('class','').lower().split())
        if not (classes & {'qqreader-footnote','footnote-icon','footnote-ref','note-ref'} or classes=={'footnote'}):continue
        text=note_text(node)
        if not text:continue
        ordinal+=1;target_id=f'wrfn-{uid}-{ordinal}';ref_id=f'wrfnref-{uid}-{ordinal}'
        target,ref=unique(target_id),unique(ref_id)
        if (target_id not in original.ids and ref_id not in original.ids and native_reference(ref,target)
                and normalized_text(text) in normalized_text(target.text())):
            converted.add(id(node))
    # Image markers inside explicit note links can become a numbered text link.
    # Require the old reference ID or note-target alias and a live native target.
    used=set()
    for anchor in original.root.descendants():
        if anchor.tag!='a':continue
        classes=anchor.attrs.get('class','').lower()
        explicit=('noteref' in anchor.attrs.get('epub:type','').split()
                  or anchor.attrs.get('role')=='doc-noteref' or 'footnote' in classes or 'noteref' in classes)
        if not explicit:continue
        images=[node for node in anchor.descendants() if id(node) in image_ids and id(node) not in converted]
        if not images:continue
        old_target=original.ids.get(unquote(urlsplit(anchor.attrs.get('href','')).fragment),[])
        if len(old_target)!=1:continue
        expected=normalized_text(old_target[0].text())
        expected=re.sub(r'^(?:\[\s*\d+\s*\]|\(\s*\d+\s*\)|（\s*\d+\s*）|[*†‡※]+)\s*','',expected)
        if not expected:continue
        candidates=[]
        if anchor.attrs.get('id'):
            preserved=unique(anchor.attrs['id'])
            if preserved:candidates=[preserved,*preserved.descendants()]
        else:
            alias=unique(unquote(urlsplit(anchor.attrs.get('href','')).fragment))
            target=alias.ancestor('aside') if alias else None
            if target:
                candidates=[node for node in rendered.root.descendants() if node.tag=='a' and node.attrs.get('href')=='#'+target.attrs.get('id','')]
        for ref in candidates:
            ref_id=ref.attrs.get('id','')
            target=unique(ref.attrs.get('href','').removeprefix('#'))
            if (ref_id.startswith('wrfnref-'+uid+'-') and ref_id not in original.ids and ref_id not in used
                    and native_reference(ref,target) and expected in normalized_text(target.text())):
                converted.update(id(node) for node in images);used.add(ref_id);break
    return len(converted)


class FullBookIncomplete(ValueError):
    def __init__(self, reason, summary):
        super().__init__(reason)
        self.summary=summary


def member_path(parent, href):
    if not isinstance(href, str) or not href or len(href) > 8192 or any(ord(c) < 32 for c in href):
        raise ValueError('full_resource_path')
    parts = urlsplit(href)
    if parts.scheme or parts.netloc or parts.query or not parts.path:
        raise ValueError('full_external_image')
    name = posixpath.normpath(posixpath.join(posixpath.dirname(parent), unquote(parts.path)))
    if name.startswith(('/', '../')) or '\\' in name:
        raise ValueError('full_resource_path')
    return name


def image_bytes(raw):
    if not 1 <= len(raw) <= 64*1024*1024:
        raise ValueError('full_image_size')
    if raw.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff', b'GIF87a', b'GIF89a')):
        return
    if raw.startswith(b'RIFF') and raw[8:12] == b'WEBP':
        return
    # Keep SVG checks structural. Pixel rendering is a separate native check.
    try:
        root = ET.fromstring(raw)
        if root.tag.rsplit('}', 1)[-1] != 'svg':
            raise ValueError('full_image_type')
        for node in root.iter():
            for key, value in node.attrib.items():
                if key.rsplit('}', 1)[-1] == 'href' and not value.startswith('#'):
                    raise ValueError('full_svg_external_resource')
    except ET.ParseError:
        raise ValueError('full_image_type') from None


def inspect_full_book(profile, payload):
    profile = Path(profile).resolve()
    checkpoint = json.loads((profile / 'checkpoint.json').read_text())
    path = Path(checkpoint['file'])
    if path.is_symlink() or not path.resolve().is_relative_to(profile) or not 1 <= path.stat().st_size <= 64*1024*1024:
        raise ValueError('full_private_path')
    expected = payload['full_manifest']
    cb_full=payload.get('cb_full_book') is True
    if cb_full and not re.fullmatch(r'CB_[A-Za-z0-9]{1,64}',payload.get('book_id','')): raise ValueError('full_chapter_scope')
    if not isinstance(expected, list) or not 2 <= len(expected) <= (128 if cb_full else 32):
        raise ValueError('full_chapter_scope')
    book_id = payload['book_id']
    rendered = []
    source_images=body_images=converted_images=unexplained_images=text_runs=missing_text=0
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if (len(names) > 4096 or len(set(names)) != len(names)
                or sum(item.file_size for item in archive.infolist()) > 128*1024*1024
                or archive.testzip() is not None):
            raise ValueError('full_archive_limit')
        identity = archive.read('OEBPS/weread-source.txt')
        if len(identity) > 2048:
            raise ValueError('full_metadata_limit')
        identity_body, source_seal = identity.rsplit(b'source_id=', 1)
        if hashlib.sha256(identity_body).hexdigest().encode()+b'\n' != source_seal:
            raise ValueError('full_metadata_seal')
        origin = dict(line.split('=', 1) for line in identity_body.decode().splitlines())
        if origin.get('schema') != '1' or unquote(origin['book_id']) != book_id or int(origin['chapter_count']) != len(expected):
            raise ValueError('full_metadata_scope')
        for source in expected:
            uid = source['chapter_uid']
            meta = archive.read('OEBPS/weread-position/uid-' + hashlib.sha256(uid.encode()).hexdigest() + '.meta')
            if len(meta) > 4096:
                raise ValueError('full_metadata_limit')
            body, seal = meta.rsplit(b'metadata_sha256=', 1)
            if hashlib.sha256(body).hexdigest().encode() + b'\n' != seal:
                raise ValueError('full_metadata_seal')
            fields = dict(line.split('=', 1) for line in body.decode().splitlines())
            if (fields['book_id'] != book_id or fields['chapter_uid'] != uid or fields['format'] != 'web_xhtml'
                    or fields['file_id'].encode()+b'\n' != source_seal or fields['book_version'] != origin['book_version']):
                raise ValueError('full_metadata_scope')
            raw = archive.read('OEBPS/weread-position/raw-' + fields['raw_sha256'] + '.txt')
            if (len(raw) != source['raw_bytes'] or len(raw) != int(fields['raw_bytes'])
                    or hashlib.sha256(raw).hexdigest() != source['raw_sha256'] or fields['raw_sha256'] != source['raw_sha256']):
                raise ValueError('full_raw_source')
            member = unquote(fields['render_path'])
            if hashlib.sha256(archive.read(member)).hexdigest() != fields['render_sha256']:
                raise ValueError('full_render_source')
            if archive.read('OEBPS/weread-position/path-' + hashlib.sha256(member.encode()).hexdigest() + '.meta') != meta:
                raise ValueError('full_source_alias')
            original=Images();original.feed(raw.decode())
            generated=Images();generated.feed(archive.read(member).decode())
            if len(original.sources)!=source['image_references']:
                raise ValueError('full_source_image_count')
            converted=verified_note_images(original,generated,uid)
            source_images+=len(original.sources);body_images+=len(generated.sources);converted_images+=converted
            unexplained_images+=max(0,len(original.sources)-len(generated.sources)-converted)
            # Footnote text may move, but substantial original text runs must
            # still occur in this chapter's rendered body.
            rendered_text=normalized_text(generated.root.text())
            for run in original.text_runs:
                text_runs+=1
                clean=re.sub(r'^(?:\[\s*\d+\s*\]|\(\s*\d+\s*\)|（\s*\d+\s*）|[*†‡※]+)\s*','',run)
                if run not in rendered_text and clean not in rendered_text:missing_text+=1
            rendered.append(member)
        ns = {'p': 'http://www.idpf.org/2007/opf'}
        opf = ET.fromstring(archive.read('OEBPS/content.opf'))
        manifest, images = {}, set()
        for item in opf.findall('p:manifest/p:item', ns):
            name = member_path('OEBPS/content.opf', item.attrib['href'])
            if item.attrib['id'] in manifest or name not in names:
                raise ValueError('full_manifest_resource')
            manifest[item.attrib['id']] = name
            if item.attrib.get('media-type', '').startswith('image/'):
                image_bytes(archive.read(name)); images.add(name)
        spine = [manifest[item.attrib['idref']] for item in opf.findall('p:spine/p:itemref', ns)]
        body_spine = spine[1:] if spine and spine[0] == 'OEBPS/text/cover.xhtml' else spine
        if body_spine != rendered:
            raise ValueError('full_spine_order')
        references, inline = 0, 0
        for member in spine:
            parser = Images(); parser.feed(archive.read(member).decode())
            for src in parser.sources:
                if src.startswith('data:image/') and ';base64,' in src:
                    image_bytes(base64.b64decode(src.split(';base64,', 1)[1], validate=True)); inline += 1
                elif member_path(member, src) not in images:
                    raise ValueError('full_unresolved_image')
                references += 1
    summary=dict(chapters=len(expected), source_image_references=source_images, local_image_references=references,
                body_image_references=body_images,converted_footnote_images=converted_images,unexplained_image_references=unexplained_images,
                source_text_runs_verified=text_runs-missing_text,unexplained_text_runs=missing_text,
                packaged_images=len(images)+inline, source_hashes_verified=True, image_references_verified=True,
                text_runs_verified=missing_text==0,spine_order_verified=True, zip_crc_verified=True, fresh_offline_package_identical=False)
    if unexplained_images or missing_text:
        summary['image_references_verified']=unexplained_images==0
        raise FullBookIncomplete('full_missing_image_references' if unexplained_images else 'full_source_text_missing',summary)
    return summary,hashlib.sha256(path.read_bytes()).hexdigest()
