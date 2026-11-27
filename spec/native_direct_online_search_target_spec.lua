package.path='./?.lua;'..package.path
package.preload.util=function() return {htmlEntitiesToUtf8=function(value)
    return value:gsub('&amp;','&'):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&quot;','"')
end} end
local Crypto=require('weread.lib.crypto')
local raw='<html><body><p>Unique preceding context before <b>needle</b> and a distinct following sentence.</p></body></html>'
local begin=assert(raw:find('needle',1,true))-1
local hit={chapter_uid='3',start=begin,finish=begin+6+#'</b>',text='needle',source_verified=false}
local scope={vid='7',epoch=1}
local source={book_id='41',chapter_uid='2',book_version=3,file_id=string.rep('a',64),key='s',copy=0,
    source_sha256=Crypto.sha256_hex(raw),catalog_sha256='catalog',catalog_order=1,catalog_count=2,catalog_next='3'}
local destination={book_id='41',chapter_uid='3',book_version=3,file_id=string.rep('b',64),key='t',copy=0,
    source_sha256=Crypto.sha256_hex(raw),catalog_sha256='catalog',catalog_order=2,catalog_count=2,catalog_prev='2'}
local state
local cache={}
function cache.valid_entry(entry,book,vid) return type(entry)=='table' and entry.book_id==book and vid=='7' end
function cache.identify(_,_,path,current)
    if not current() then return nil end
    if path=='/native/source' then return state.source end
    if path=='/native/target' then state.target_identifications=state.target_identifications+1;return state.target end
end
function cache.list(_,owner,book,current,uid)
    assert(owner==scope.vid and book==source.book_id and uid==destination.chapter_uid and current())
    return state.rows
end
function cache.open(_,_,_,entry,current,with_entry)
    assert(with_entry)
    if current() and not state.damaged and entry==state.target then return {path='/native/target'},state.target end
end
package.loaded['weread.lib.native_direct_cache']=cache
package.loaded['weread.lib.native_direct_path']={contains=function(_,path) return path=='/native/target' or path=='/native/source' end}
package.loaded['weread.lib.native_direct_position']={same=function(a,b) return a==b end,
    verified_source=function(_,_,entry,path,_,_,current)
        assert((path=='/native/target' and entry==state.target or path=='/native/source' and entry==state.source) and current())
        state.reads=state.reads+1
        if state.error then return nil,state.error end
        if state.change_source then state.source={} end
        if state.change_target then state.target={} end
        if state.revoke then state.valid=false end
        return state.raw
    end}
package.loaded['weread.lib.native_read_access']={matches=function(_,access) return state.valid and access==state.native end}
package.loaded['weread.lib.source_currentness']={matches=function(_,access) return state.valid and access==state.web end}
package.loaded['weread.lib.native_authorization']={new=function() return {cancel=function() state.cancelled=true end} end}
package.loaded['weread.lib.native_book_catalog']={read=function() if state.http_error then error(state.http_error,0) end;return {} end}
package.loaded['weread.ui.native_direct_reading']={project=function() return state.catalog end}
package.loaded['weread.lib.native_direct_reader']={build=function(_,_,_,chapter,expected,options)
    assert(chapter.chapterUid=='3' and expected.chapter_uid=='3' and options.is_current())
    state.built=state.built+1;return {path='/native/target'}
end}
local Search=require('weread.lib.native_direct_online_search_target')
local settings={}
local function fixture()
    state={source=source,target=destination,rows={destination},valid=true,raw=raw,reads=0,built=0,target_identifications=0,
        native={scope=scope,credentials={vid='7'},fingerprint='fingerprint'},web={web={cookies={wr_vid='7'}}},
        catalog={version=3,reading_digest='catalog',chapters={{chapterUid='2'}, {chapterUid='3',downloadable=true}}}}
end
local function resolve(download,selected)
    return Search.resolve({},settings,source,'/native/source',selected or hit,state.native,state.web,
        function() return state.valid end,download,{book_id='41'})
end
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label or ('check '..checks)) end
fixture();local result,why=resolve(false)
expect(result and not why and result.entry==destination and result.path=='/native/target' and result.reused and result.local_only
    and result.anchor and state.reads==1 and state.built==0 and state.target_identifications==1,
    'saved match did not use its verified identity and recheck after source processing')
expect(result.anchor.point_unit=='unicode_scalars' and result.anchor.basis=='filtered_xhtml_utf16',
    'local anchor lacked source identity')
fixture();state.rows={};result,why=resolve(false);expect(not result and why=='not_saved' and state.built==0,'missing chapter downloaded without consent')
fixture();state.rows={};result,why=resolve(true);expect(result and not why and result.reused==false and state.built==1 and state.cancelled,'consented download failed')
fixture();state.rows={};state.catalog.reading_digest='different';result,why=resolve(true)
expect(not result and why=='catalog_changed' and state.built==0 and state.cancelled,'changed catalog accepted')
fixture();state.rows={};state.catalog.chapters[2].downloadable=false;result,why=resolve(true)
expect(not result and why=='not_entitled' and state.built==0,'unavailable chapter downloaded')
fixture();state.raw=raw:gsub('needle','altered');result,why=resolve(false)
expect(not result and why=='source_changed','changed source returned a target')
fixture();local wrong={chapter_uid='3',start=begin,finish=begin+6,text='wrong',source_verified=false}
result,why=resolve(false,wrong);expect(not result and why=='target_unavailable','changed quote accepted')
fixture();state.error='web_expired';result,why=resolve(true)
expect(not result and why=='web_expired' and state.built==0,'expired web session triggered download')
fixture();state.source={};result,why=resolve(false);expect(not result and why=='source_changed','changed source chapter accepted')
fixture();state.change_source=true;result,why=resolve(false);expect(not result and why=='source_changed','source change during lookup accepted')
fixture();state.change_target=true;result,why=resolve(false);expect(not result and why=='source_changed','target change during lookup accepted')
fixture();state.revoke=true;result,why=resolve(false);expect(not result and why=='session_changed','session change during lookup accepted')
fixture();state.valid=false;result,why=resolve(false);expect(not result and why=='invalid','changed account accepted')
fixture();state.native.renewal_pending=true;result,why=resolve(true);expect(not result and why=='invalid','pending renewal accepted')
fixture();state.web.web.cookies.wr_vid='8';result,why=resolve(true);expect(not result and why=='invalid','other web account accepted')
fixture();state.rows={};state.http_error='native_auth/native_catalog_info/http_429';result,why=resolve(true)
expect(not result and why=='rate_limited' and state.cancelled,'rate limit was hidden')
fixture();local same={chapter_uid='2',start=begin,finish=begin+6+#'</b>',text='needle',source_verified=false}
result,why=resolve(false,same);expect(result and not why and result.path=='/native/source' and state.built==0,'current chapter did not resolve')
print(('native_direct_online_search_target_spec: %d checks'):format(checks))
