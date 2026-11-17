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
expect(not marks.project(raw,'CB_Synthetic','2',imported_row),'search support widened cloud mark scope')
expect(not Target.row('41',{chapter_uid='2',start=0,finish=1,text='x',source_verified=true})
    and not Target.row('41',{chapter_uid='2',start=0,finish=2147483648,text='x',source_verified=false})
    and not Target.row('CB_bad/path',hit) and not Target.row('MP_WXS_1',hit),'unverified range limits or book scope were bypassed')
print(('book_search_target_spec: %d checks'):format(checks))
