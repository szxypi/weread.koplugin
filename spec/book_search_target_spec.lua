package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(value)
    return value:gsub('&amp;','&'):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"')
end} end
local Target=require('weread.lib.book_search_target')
local checks=0
local function expect(value,label) checks=checks+1;if not value then error(label) end end
local raw='<html><body><p>before needle</p><p>after</p></body></html>'
local start=assert(raw:find('needle',1,true))-1
local hit={chapter_uid='2',start=start,finish=start+6,text='needle',source_verified=false}
local row=assert(Target.row('41',hit))
expect(row.type==1 and row.bookId=='41' and row.chapterUid==2 and row.markText=='needle',
    'search hit was not bound to the requested book and chapter')
local value=assert(Target.project(raw,'41',hit))
expect(value.chapter_offset==start and value.basis=='filtered_xhtml_utf16' and value.upload_verified==false,
    'source verification did not return a local-only target')
local marked='<html><body><p>before <b>needle</b> after</p></body></html>'
local first=assert(marked:find('needle',1,true))-1
local marked_hit={chapter_uid='2',start=first,finish=first+6+#'</b>',text='needle',source_verified=false}
expect(Target.project(marked,'41',marked_hit)~=nil,'source check rejected an exact quote spanning closing markup')
local altered={chapter_uid='2',start=start,finish=start+6,text='wrong',source_verified=false}
expect(not Target.project(raw,'41',altered),'source check accepted a changed search quote')
local imported=assert(Target.project(raw,'CB_Synthetic',hit))
expect(imported.book_id=='CB_Synthetic' and imported.chapter_offset==start and imported.upload_verified==false,
    'imported search result was not locally source verified')
local marks=require('weread.lib.my_mark_target')
local imported_row=assert(Target.row('CB_Synthetic',hit))
local imported_mark=assert(marks.project(raw,'CB_Synthetic','2',imported_row))
expect(imported_mark.chapter_offset==imported.chapter_offset and imported_mark.upload_verified==false,
    'imported highlight and search did not use the same read-only source boundary')
expect(not Target.row('41',{chapter_uid='2',start=0,finish=1,text='x',source_verified=true})
    and not Target.row('41',{chapter_uid='2',start=0,finish=2147483648,text='x',source_verified=false})
    and not Target.row('CB_bad/path',hit) and not Target.row('MP_WXS_1',hit),'unverified range limits or book scope were bypassed')
local Source=require('weread.lib.position_source')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local book={book_id='CB_Synthetic',bookVersion=7}
for _i,uid in ipairs({'2147483648','9007199254740992','9007199254740993','18446744073709551615'}) do
    local chapter={chapterUid=uid}
    local source=assert(Source.capture(book,chapter,raw,'web_xhtml'))
    local root=Identity.encode(book,{chapter},Identity.capture(book),Crypto.sha256_hex(raw))
    local identity=assert(Identity.decode(root));local path='OEBPS/text/chapter.xhtml'
    local metadata=assert(Source.bind(source,identity,path,Crypto.sha256_hex(raw)))
    local members={[Identity.PATH]=root,[Source.meta_path(uid)]=metadata,[Source.path_meta_path(path)]=metadata,
        [Source.raw_path(Crypto.sha256_hex(raw))]=raw,[path]=raw}
    local function archive(_file,wanted)
        local result={};for key,limit in pairs(wanted) do if not members[key] or #members[key]>limit then return nil end;result[key]=members[key] end
        return result
    end
    local candidate={chapter_uid=uid,start=start,finish=start+6,text='needle',source_verified=false}
    local search_row=assert(Target.row(book.book_id,candidate))
    expect(search_row.chapterUid==uid and Target.can_locate(search_row),'large chapter was not kept as a string')
    expect(not marks.can_locate(search_row),'search-only extension changed cloud mark eligibility')
    local bound=Target.resolve({book_id=book.book_id,cached_chapters={[uid]='/bound.epub'}},nil,search_row,7,archive)
    expect(bound.position and bound.position.chapter_uid==uid and bound.position.upload_verified==false,
        'large search target did not bind to its exact source')
    search_row.chapterUid=uid=='9007199254740992' and '9007199254740993' or '9007199254740992'
    expect(not Target.bind_file('/bound.epub',book.book_id,search_row,7,archive).position,
        'different chapter identity was accepted for the same source')
end
expect(not Target.can_locate({type=1,chapterUid=9007199254740992,markText='x',range='1-2'}),
    'large numeric search row could be rounded to a different chapter')
print(('book_search_target_spec: %d checks'):format(checks))
