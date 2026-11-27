package.path='./?.lua;'..package.path
local scope={vid='7',epoch=1}
local source={book_id='41',chapter_uid='2',book_version=3,file_id=string.rep('a',64),key='s',copy=0,
    source_sha256='source',catalog_sha256='catalog',catalog_order=1,catalog_count=2,catalog_next='3'}
local target={book_id='41',chapter_uid='3',book_version=3,file_id=string.rep('b',64),key='t',copy=0,
    source_sha256='target',catalog_sha256='catalog',catalog_order=2,catalog_count=2,catalog_prev='2'}
local row={bookmarkId='b',type=1,chapterUid=3,range='1-5',markText='text'}
local state
local cache={}
function cache.valid_entry(entry,book,vid) return type(entry)=='table' and entry.book_id==book and vid=='7' end
function cache.identify(_,_,path,current)
    if not current() then return nil end
    if path=='/native/source' then return state.source end
    if path=='/native/target' then state.target_identifications=state.target_identifications+1;return state.target end
end
function cache.list(_,owner,book,current,uid)
    assert(owner==scope.vid and book==source.book_id and uid==target.chapter_uid and current())
    return state.rows
end
function cache.open(_,_,_,entry,current,with_entry)
    assert(with_entry)
    if current() and not state.damaged and entry==state.target then return {path='/native/target'},state.target end
end
package.loaded['weread.lib.native_direct_cache']=cache
package.loaded['weread.lib.native_direct_path']={contains=function(_,path) return path=='/native/target' end}
package.loaded['weread.lib.mark_edit_contract']={row_hash=function(r) return r.bookmarkId..':'..r.range end}
package.loaded['weread.lib.personal_mark_task']={prepare_direct=function(_,_,_,path,entry,metadata,rows,online)
    assert(path=='/native/target' and entry==state.target and online==state.online)
    state.prepared=state.prepared+1
    if state.bad_quote then return {metadata=metadata,rows={}} end
    return {metadata=metadata,rows={{bookmarkId=rows[1].bookmarkId,reference_hash=rows[1].bookmarkId..':'..rows[1].range}}}
end}
package.loaded['weread.lib.native_read_access']={capture=function() return state.access end,
    matches=function(_,access) return state.valid and access==state.access end}
package.loaded['weread.lib.native_authorization']={new=function() return {cancel=function() state.cancelled=true end} end}
package.loaded['weread.lib.native_book_catalog']={read=function() if state.http_error then error(state.http_error,0) end;return {} end}
package.loaded['weread.ui.native_direct_reading']={project=function() return state.catalog end}
package.loaded['weread.lib.native_direct_reader']={build=function(_,_,_,chapter,expected,options)
    assert(chapter.chapterUid=='3' and expected.chapter_uid=='3' and options.is_current())
    state.built=state.built+1;return {path='/native/target'}
end}
local Target=require('weread.lib.native_direct_note_target')
local settings={get_auth_scope=function() return scope end,auth_scope_matches=function(_,v) return state.valid and v==scope end}
local function fixture(online)
    state={source=source,target=target,rows={target},valid=true,online=online,prepared=0,built=0,target_identifications=0,
        access={scope={vid='7'},credentials={},fingerprint='fingerprint'},
        catalog={version=3,reading_digest='catalog',chapters={{chapterUid='2'}, {chapterUid='3',downloadable=true}}}}
end
local function resolve()
    return Target.resolve({},settings,{},source,'/native/source',{book_id='41'},row,state.online,function() return state.valid end)
end
local checks=0
local function expect(value) checks=checks+1;assert(value,'check '..checks) end
fixture(false);local result=resolve();expect(result and result.path=='/native/target' and state.prepared==1
    and state.built==0 and state.target_identifications==0)
fixture(false);state.rows={};local _,why=resolve();expect(why=='not_saved' and state.built==0)
fixture(false);state.bad_quote=true;result,why=resolve();expect(not result and why=='not_saved')
fixture(false);state.damaged=true;result,why=resolve();expect(not result and why=='not_saved' and state.prepared==0)
fixture(false);state.source={};result,why=resolve();expect(not result and why=='source_changed')
fixture(false);state.valid=false;result,why=resolve();expect(not result and why=='invalid')
fixture(false);state.rows={target,{book_id='41',chapter_uid='3',book_version=3,catalog_sha256='catalog',catalog_count=2,source_sha256='different'}}
result,why=resolve();expect(not result and why=='ambiguous' and state.prepared==0)
fixture(true);state.rows={target,{book_id='41',chapter_uid='3',book_version=3,catalog_sha256='catalog',catalog_count=2,source_sha256='different'}}
result,why=resolve();expect(result and not why and state.built==1 and state.prepared==1 and state.cancelled)
fixture(true);state.rows={target,{book_id='41',chapter_uid='3',book_version=3,catalog_sha256='catalog',catalog_count=2,source_sha256='different'}}
state.bad_quote=true;result,why=resolve();expect(not result and why=='target_unavailable' and state.built==1 and state.cancelled)
fixture(true);state.rows={};result=resolve();expect(result and state.built==1 and state.cancelled
    and state.prepared==1 and state.target_identifications==1)
fixture(true);state.rows={};state.catalog.reading_digest='different';result,why=resolve();expect(not result and why=='catalog_changed' and state.built==0 and state.cancelled)
fixture(true);state.rows={};state.catalog.chapters[2].downloadable=false;result,why=resolve();expect(not result and why=='not_entitled' and state.built==0)
fixture(true);state.rows={};state.access.renewal_pending=true;result,why=resolve();expect(not result and why=='auth_expired' and state.built==0)
fixture(true);state.rows={};state.http_error='native_auth/native_catalog_info/http_401';result,why=resolve();expect(not result and why=='auth_expired' and state.cancelled)
fixture(true);state.rows={};state.http_error='native_auth/native_catalog_catalog/http_429';result,why=resolve();expect(not result and why=='rate_limited' and state.cancelled)
print('native_direct_note_target_spec: '..checks..' checks passed')
