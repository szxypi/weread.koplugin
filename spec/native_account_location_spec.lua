package.path='./?.lua;./?/init.lua;'..package.path
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local a,b=string.rep('a',20),string.rep('b',20)
local fid=string.rep('c',64)
local identity={book_id='900001',file_id=fid}
local calls,proof_ok=0,false
local attributes={mode='file',size=1024,modification=123}
package.preload['libs/libkoreader-lfs']=function() return {attributes=function() return attributes end} end
package.preload['weread.lib.book_file_identity']=function() return {read_document=function() calls=calls+1;return identity end} end
package.preload['weread.lib.read_access']=function() return {display_book_id=function(v) return v=='900001' and v or nil end} end
package.preload['weread.lib.source_view']=function() return {matches=function() return proof_ok end} end
local Location=require('weread.lib.native_account_location')
local account=a
local document={file='/synthetic/book.epub',isXPointerInDocument=function(_,p) return p~='missing' end}
local book={cached_file=document.file}
local host={settings={get_book=function() return book end},library_db={accountKey=function() return account end},
    detectWeReadBook=function() return '900001' end}
local function config(values)
    return {data=values or {},readSetting=function(self,key) return self.data[key] end,
        saveSetting=function(self,key,v) self.data[key]=v end,delSetting=function(self,key) self.data[key]=nil end}
end
local c=config();local navigated
host.ui={document=document,doc_settings=c,rolling={onGotoXPointer=function(_,p) navigated=p;return true end}}
Location.load(host,c,document)
expect(calls==0,'document engine touched before ReaderReady')
Location.ready(host,'900001');c:saveSetting('last_xpointer','/a');Location.save(host)
local saved=c.data.weread_account_locations
expect(saved and saved.entries[a].xpointer=='/a' and saved.file_id==fid,'new account location was not saved')
account=b;c:saveSetting('last_xpointer','/a');Location.load(host,c,document)
expect(c.data.last_xpointer==nil,'another account inherited the native pointer')
Location.ready(host,'900001');c:saveSetting('last_xpointer','/b');Location.save(host)
expect(c.data.weread_account_locations.entries[a].xpointer=='/a'
    and c.data.weread_account_locations.entries[b].xpointer=='/b','account entries overwrote each other')
account=a;c:saveSetting('last_xpointer','/b');Location.load(host,c,document);navigated=nil;Location.ready(host,'900001')
expect(navigated=='/a','original account page was not restored')
account=a;c:saveSetting('last_xpointer','/a');Location.load(host,c,document)
account=b;navigated=nil;Location.ready(host,'900001')
expect(navigated=='/b','account change during reader startup restored the previous account')
account=a;Location.load(host,c,document);Location.ready(host,'900001')
local before=copy(c.data.weread_account_locations);account=b;c:saveSetting('last_xpointer','/wrong');Location.save(host)
expect(c.data.weread_account_locations.entries[a].xpointer==before.entries[a].xpointer
    and c.data.weread_account_locations.entries[b].xpointer==before.entries[b].xpointer,'changed account stole an open reader location')
account=a;attributes={mode='file',size=2048,modification=124};c:saveSetting('last_xpointer','/native')
Location.load(host,c,document);expect(c.data.last_xpointer=='/native','changed file lost its native fallback')
attributes={mode='file',size=1024,modification=123};identity={book_id='900001',file_id=string.rep('d',64)}
Location.load(host,c,document);navigated=nil;Location.ready(host,'900001')
expect(navigated=='/native','changed identity did not restore the old native behavior')
c:saveSetting('last_xpointer','/replacement');Location.save(host)
expect(c.data.weread_account_locations.file_id==fid,'changed file overwrote another source\'s location')
identity={book_id='900001',file_id=fid}
local invalid=copy(c.data.weread_account_locations);invalid.entries[a].xpointer='missing'
local invalid_config=config({last_xpointer='/fallback',weread_account_locations=invalid})
host.ui.doc_settings=invalid_config;Location.load(host,invalid_config,document);navigated=nil;Location.ready(host,'900001')
invalid_config:saveSetting('last_xpointer','/replacement');Location.save(host)
expect(navigated=='/fallback' and invalid_config.data.weread_account_locations.entries[a].xpointer=='missing',
    'invalid saved pointer replaced the account record or lost its native fallback')
local legacy=config({last_xpointer='/unknown'});host.ui.doc_settings=legacy
Location.load(host,legacy,document);Location.ready(host,'900001');Location.save(host)
expect(legacy.data.last_xpointer=='/unknown' and not legacy.data.weread_account_locations,
    'unknown legacy position was automatically claimed')
local auth={vid='900000',epoch=1};local auth_valid=true;local save_ok=true
host.settings.get_auth_scope=function() return auth end
host.settings.auth_scope_matches=function(_self,value) return auth_valid and value==auth end
host.settings.patch_reading_state=function(_self,_id,patch)
    if not save_ok then return false end
    book.native_location_claims=copy(patch.native_location_claims);return true
end
document.getXPointer=function() return '/claimed' end
document.isXPointerInCurrentPage=function(_,value) return value=='/claimed' end
Location.load(host,legacy,document);Location.ready(host,'900001')
expect(Location.can_claim(host),'unknown legacy position offered no explicit account recovery')
account=b;expect(not Location.can_claim(host) and not Location.claim(host),'another account claimed the open reader')
account=nil;expect(not Location.can_claim(host) and not Location.claim(host),'signed-out reader claimed an account location')
account=a;attributes={mode='file',size=2048,modification=124}
expect(not Location.can_claim(host),'changed cached file could be claimed')
attributes={mode='file',size=1024,modification=123}
book.native_location_claims={invalid={schema=1}}
expect(not Location.claim(host),'malformed saved claims were overwritten')
book.native_location_claims=nil
document.isXPointerInCurrentPage=function() return false end
expect(not Location.claim(host),'a location outside the current page was claimed')
document.isXPointerInCurrentPage=function(_,value) return value=='/claimed' end
save_ok=false;expect(not Location.claim(host) and not book.native_location_claims,'failed local save claimed a position')
save_ok=true;expect(Location.claim(host),'explicit local claim failed')
expect(book.native_location_claims and not legacy.data.weread_account_locations,'claim required rewriting native sidecar')
for key,value in pairs(book.native_location_claims) do
    expect(#key==64 and value.path_hash==key and key~=document.file,'claim stored a raw file path')
end
local recovered=config({last_xpointer='/someone-else'});host.ui.doc_settings=recovered
Location.load(host,recovered,document);Location.ready(host,'900001')
expect(navigated=='/claimed','durable claim did not restore the selected account page')
local warning
host.showTransientInfo=function(_self,text) warning=text end
host.ui.rolling.onGotoXPointer=function(_self,p)
    if p=='/claimed' then return false end
    navigated=p;return true
end
Location.load(host,recovered,document);navigated=nil;Location.ready(host,'900001')
expect(navigated=='/someone-else' and warning~=nil and not recovered.data.weread_account_locations,
    'failed claim restore did not retain the native fallback and report the failure')
host.ui.rolling.onGotoXPointer=function() return true end
book.native_location_claims=nil;auth_valid=false
Location.load(host,legacy,document);Location.ready(host,'900001')
expect(not Location.can_claim(host) and not Location.claim(host),'stale authentication could claim a position')
auth_valid=true
host.ui.doc_settings=legacy;host.ui.view={view_mode='scroll',dimen={w=200,h=200}}
document.getCurrentPos=function() return 100 end
document.getTextFromPositions=function() return {pos0='/claimed'} end
document.getPosFromXPointer=function() return 900 end
Location.load(host,legacy,document);Location.ready(host,'900001')
expect(not Location.claim(host),'offscreen scroll location was claimed')
document.getTextFromPositions=function() return nil end
expect(not Location.claim(host),'image-only scroll viewport was claimed without visible text')
document.getTextFromPositions=function() return {pos0='/claimed'} end
document.getPosFromXPointer=function() return 140 end
expect(Location.claim(host),'visible scroll location could not be claimed')
Location.before_close(host);host.ui.document=nil;legacy:saveSetting('last_xpointer','/stale-origin');Location.save(host)
expect(legacy.data.weread_account_locations.entries[a].xpointer=='/claimed',
    'scroll close saved an offscreen native page origin')
legacy:delSetting('weread_account_locations');legacy:saveSetting('last_xpointer','/unknown')
book.native_location_claims=nil;host.ui.document=document;host.ui.view=nil
local percent_legacy=config({last_percent=.55});host.ui.doc_settings=percent_legacy
Location.load(host,percent_legacy,document);Location.ready(host,'900001')
percent_legacy:saveSetting('last_xpointer','/percent');Location.save(host)
expect(not percent_legacy.data.weread_account_locations,'unowned legacy percentage was automatically claimed')
host.ui.doc_settings=legacy
local source={book_id='900001',file_id=fid};book.last_local_position={source_position=source,
    source_view={view={xpointer='/unknown'}}};proof_ok=true
Location.load(host,legacy,document);Location.ready(host,'900001');Location.save(host)
expect(legacy.data.weread_account_locations.entries[a].xpointer=='/unknown'
    and legacy.data.weread_account_locations.legacy.xpointer=='/unknown','verified legacy position did not migrate')
local bad=config({last_xpointer='/untouched',weread_account_locations={schema=99}});host.ui.doc_settings=bad
Location.load(host,bad,document);Location.ready(host,'900001');Location.save(host)
expect(bad.data.last_xpointer=='/untouched' and bad.data.weread_account_locations.schema==99,
    'unrecognized account location data was overwritten')
local cyclic=copy(c.data.weread_account_locations);cyclic.legacy={xpointer='/old'};cyclic.legacy.loop=cyclic
expect(not Location.map_valid(cyclic,'900001'),'cyclic legacy metadata was accepted')
host.ui.doc_settings=c;book.cached_file='/another/book.epub';c:saveSetting('last_xpointer','/unrelated')
Location.load(host,c,document);expect(c.data.last_xpointer=='/unrelated','unrelated file was changed')
local chapter='99'
local Protocol=require('weread.lib.protocol')
identity.chapter_count=1
document.getDocumentFileContent=function() return '<dc:source>'..Protocol.reader_url('900001',chapter)
    ..'</dc:source><spine><itemref idref="chapter"/></spine>' end
book.annotation_documents={[document.file]={clean=true,chapters={{chapterUid=chapter}}}}
book.cached_chapters={[chapter]='/another/chapter.epub'}
local older=config({last_xpointer='/from-a',weread_account_locations=copy(saved)})
older.data.weread_account_locations.entries={[a]={xpointer='/from-a'}}
host.ui.doc_settings=older;account=b
Location.load(host,older,document);navigated=nil
host.ui.rolling.onGotoXPointer=function(_self,value) navigated=value;return true end
Location.ready(host,'900001')
expect(host._weread_retained_chapter==document and older.data.last_xpointer==nil and not navigated,
    'another account inherited the old chapter position')
account=a;Location.load(host,older,document);Location.ready(host,'900001')
expect(navigated=='/from-a','old chapter lost its account position')
book.annotation_documents[document.file].chapters[1].chapterUid='101'
Location.load(host,older,document);navigated=nil;Location.ready(host,'900001')
expect(not navigated and not host._native_account_location.allowed,'unrelated chapter proof restored a saved position')
print('native_account_location_spec: '..checks..' checks')
