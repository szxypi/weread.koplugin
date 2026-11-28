-- Add a synthetic, independently generated copy of the target chapter.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local dir=assert(os.getenv('KO_HOME'))..'/weread';local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=dir,cache_dir=dir,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_,value) return value==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local capture=Access.capture
Access.capture=function(s,existing) return capture(s,existing or store) end
local selected=assert(Access.capture(settings))
local client=require('weread.lib.client'):new(settings)
local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid,
    is_current=function() return Access.matches(settings,selected) end})
local catalog=require('weread.lib.native_book_catalog').read(auth,input.credentials,'42','native_catalog');auth:cancel()
local row=assert(catalog.reading_chapters[2]);assert(row.chapterUid=='38' and row.downloadable)
row.catalog_order=2;row.catalog_count=#catalog.reading_chapters;row.catalog_prev=catalog.reading_chapters[1].chapterUid
local expected={book_id='42',chapter_uid='38',book_version=catalog.version,
    reading_catalog_sha256=catalog.reading_digest,access_fingerprint=selected.fingerprint}
local result=assert(require('weread.lib.native_direct_reader').build(client,settings,
    {book_id='42',title='Synthetic',author='Fixture'},row,expected,{is_current=function() return true end}))
print('WEREAD_CONFLICT_PREPARED='..json.encode{path=result.path})
