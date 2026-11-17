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
print('native_account_location_spec: '..checks..' checks')
