package.path='./?.lua;' .. package.path
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end,dbg=function() end} end
local Worker=require('weread.lib.chapter_link_worker')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local chapters={{chapterUid=191,files={'Text/body.xhtml'}},{chapterUid=192,files={'Text/notes.xhtml'}}}
local body='<p>正文<a id="ref" epub:type="noteref" href="notes.xhtml#note">[1]</a>'
    .. '<a href="../Text/notes.xhtml#note">另一链接</a></p>'
local function package_for(uid,html,version,id)
    local book={bookId=id or '990191',bookVersion=version or 7}
    local raw=Identity.encode(book,{{chapterUid=uid}},Identity.capture(book),Crypto.sha256_hex(html))
    return {[Identity.PATH]=raw,['OEBPS/content.opf']='<package><dc:identifier id="bookid">weread-'
        .. book.bookId .. '-' .. uid .. '</dc:identifier></package>',[Worker.RENDER_PATH]=html}
end
local function setup(source_html,target_html)
    local archives={['/source.epub']=package_for('191',source_html or body),
        ['/target.epub']=package_for('192',target_html or '<aside id="note">图注<img src="note.svg"/></aside>')}
    local input={book_id='990191',chapter_uid='191',file='/source.epub',
        file_id=Identity.decode(archives['/source.epub'][Identity.PATH]).file_id,
        native_uri='OEBPS/text/notes.xhtml#note',chapters=chapters,
        cached_chapters={['191']='/source.epub',['192']='/target.epub'}}
    local reads={}
    local function read(path,wanted)
        expect(wanted[Identity.PATH]==Identity.MAX_BYTES and wanted[Worker.RENDER_PATH]>0,'reads are bounded and request source identity')
        reads[#reads+1]=path
        return archives[path]
    end
    return input,archives,read,reads
end
local function fresh(...)
    local values={setup(...)}
    return values[1],values[3],values[4]
end
local input,archives,read,reads=setup()
local result=Worker.prepare(input,read)
expect(result.kind=='ready' and result.target_uid=='192' and result.target_path=='/target.epub','cached target prepared')
expect(result.anchor=='note' and result.anchor_verified==true,'actual target anchor verified')
expect(result.source_file_id==input.file_id and result.source_sha256==Crypto.sha256_hex(body),'source identity and member digest retained')
expect(#reads==2 and result.target_file_id==Identity.decode(archives['/target.epub'][Identity.PATH]).file_id,'independent target identity checked')
expect(result.html==nil and result.upload_verified~=true,'no body or cloud upload grant returned')
local Links=require('weread.lib.book_link_paths')
local unknown_index=Links.build({['191']={chapter=chapters[1],anchors={ref=true}},
    ['192']={chapter=chapters[2],anchors={},anchors_unknown=true}},chapters,{['192']='chapter-002.xhtml'})
expect(Links.plan(unknown_index,'191','notes.xhtml#note').anchor_verified==false,'catalog planning retains unknown anchor status')
expect(Links.resolve(unknown_index,'191','notes.xhtml#note')==nil,'unknown catalog anchor cannot authorize an existing-package link')
input.native_uri='OEBPS/Text/notes.xhtml#note'
expect(Worker.prepare(input,read).kind=='ready','native normalized relative URI matched to original href')
input,read,reads=fresh();input.cached_chapters['192']=nil
result=Worker.prepare(input,read)
expect(result.kind=='needs_download' and result.target_uid=='192' and result.anchor_verified==false and #reads==1,
    'uncached catalog plan is not anchor proof')
input,archives,read=setup();archives['/target.epub']=nil
expect(Worker.prepare(input,read).kind=='needs_download','missing cached file requests a fresh download plan')
input,read=fresh();input.file_id=string.rep('b',64)
expect(Worker.prepare(input,read).reason=='file_changed','source replacement rejected')
input,archives,read=setup();archives['/source.epub']=package_for('192',body)
input.file_id=Identity.decode(archives['/source.epub'][Identity.PATH]).file_id
expect(Worker.prepare(input,read).reason=='chapter_mismatch','source OPF chapter must match cached UID')
input,archives,read=setup();archives['/target.epub']=package_for('191','<p id="note">错误章节</p>')
expect(Worker.prepare(input,read).reason=='chapter_mismatch','wrong target chapter is never marked ready')
input,archives,read=setup()
archives['/target.epub']['OEBPS/content.opf']='<package><!-- <dc:identifier>weread-990191-192</dc:identifier> --></package>'
expect(Worker.prepare(input,read).reason=='chapter_mismatch','comment text cannot prove the target chapter identity')
input,archives,read=setup()
archives['/target.epub']['OEBPS/content.opf']='<package><!-- <dc:identifier>wrong</dc:identifier> -->'
    .. '<metadata><dc:identifier id="bookid">weread-990191-192</dc:identifier></metadata></package>'
expect(Worker.prepare(input,read).kind=='ready','real identifier is found without treating comment markup as an ID')
input,archives,read=setup();archives['/target.epub']=package_for('192','<p id="note">其他账号书籍</p>',7,'different-book')
expect(Worker.prepare(input,read).kind=='needs_download','foreign archive identity not accepted')
input,archives,read=setup();archives['/target.epub']=package_for('192','<p id="note">新版</p>',8)
expect(Worker.prepare(input,read).reason=='version_mismatch','conflicting observed book versions rejected')
input,archives,read=setup();archives['/target.epub']=package_for('192','<p id="note">旧缓存</p>',0)
expect(Worker.prepare(input,read).kind=='ready','unknown version remains local reading only')
input,read=fresh(nil,'<p id="another">没有目标</p>')
expect(Worker.prepare(input,read).reason=='anchor_missing','missing actual target rejected')
input,read=fresh(nil,'<p id="note">甲</p><p id="note">乙</p>')
expect(Worker.prepare(input,read).reason=='anchor_ambiguous','duplicate actual target rejected')
input,read=fresh();input.native_uri='OEBPS/text/forged.xhtml#note'
expect(Worker.prepare(input,read).reason=='link_unavailable','URI must occur in the actual source chapter')
input,read=fresh();input.native_uri='https://example.org/notes.xhtml#note'
expect(Worker.prepare(input,read).reason=='link_unsupported','external links not claimed')
input,read=fresh();input.cached_chapters['191']='/different.epub'
expect(Worker.prepare(input,read).reason=='source_unavailable','source cache mapping must still match')
input,read=fresh();input.chapters={chapters[1],chapters[1],chapters[2]}
expect(Worker.prepare(input,read).reason=='catalog_ambiguous','duplicate catalog UIDs rejected')
input,read=fresh();input.chapters={chapters[1],chapters[2],[4]={chapterUid=193,files={'Text/notes.xhtml'}}}
expect(Worker.prepare(input,read).reason=='catalog_invalid','sparse catalog cannot hide a conflicting file owner')
input,read=fresh();input.chapters={chapters[1],{chapterUid=192,files='not a list'}}
expect(Worker.prepare(input,read).reason=='catalog_invalid','malformed file metadata rejected')
input,read=fresh('<p><a href="notes.xhtml">注释章</a></p>','<p>章首，无锚点</p>');input.native_uri='OEBPS/text/notes.xhtml'
result=Worker.prepare(input,read)
expect(result.kind=='ready' and result.anchor==nil,'file-only citation prepared for chapter top')
input,read=fresh('<a href="notes.xhtml#%E4%B8%AD">资料</a>','<p id="&#x4E2D;">中文</p>')
input.native_uri='OEBPS/text/notes.xhtml#中'
result=Worker.prepare(input,read)
expect(result.kind=='ready' and result.anchor=='中','URI and XML numeric entity resolve to actual Unicode ID')
input,read=fresh('<a href="notes.xhtml#literal%252A">原文</a>','<p id="literal%2A">百分号锚点</p>')
input.native_uri='OEBPS/text/notes.xhtml#literal%2A'
expect(Worker.prepare(input,read).kind=='ready','native external fragment is not URI-decoded a second time')
input,read=fresh('<a href="#note">跨片段</a>','<p id="note">相同原文件另一片段</p>')
input.chapters={{chapterUid=191,files={'Text/shared.xhtml'}},{chapterUid=192,files={'Text/shared.xhtml'}}}
input.native_uri='#_doc_fragment_0_ note'
expect(Worker.prepare(input,read).kind=='ready','same original XHTML split into two independent EPUBs')
input,read=fresh('<a href="notes.xhtml#note">甲</a><a href="/OEBPS/text/notes.xhtml#note">乙</a>')
input.chapters={chapters[1],chapters[2],{chapterUid=193,files={'OEBPS/text/notes.xhtml'}}}
expect(Worker.prepare(input,read).reason=='link_ambiguous','colliding native URIs cannot choose an arbitrary original href')
input,read=fresh('<!-- <a href="forged.xhtml#note">伪链接</a> --><p>正文</p>');input.native_uri='OEBPS/text/forged.xhtml#note'
expect(Worker.prepare(input,read).reason=='link_unavailable','comment text cannot authorize a link')
input,read=fresh('<div id="large">' .. string.rep('长正文',3000) .. '<a href="notes.xhtml#note">注释</a></div>')
package.loaded.logger.warn=function() error('source-derived logging forbidden') end
expect(Worker.prepare(input,read).kind=='ready','link-only inspection never cleans/logs oversized private note prose')
expect(Worker.prepare({}).reason=='input_invalid','invalid worker envelope rejected')
print('chapter_link_worker_spec: ' .. checks .. ' checks passed')
