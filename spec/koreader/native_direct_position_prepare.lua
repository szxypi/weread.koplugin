-- Prepare one synthetic native chapter in the installed-plugin profile.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
package.path=assert(arg[1])..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):wrap({});G_defaults=require('luadefaults'):open()
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local home=assert(os.getenv('KO_HOME'));local dir=home..'/weread';assert(require('libs/libkoreader-lfs').mkdir(dir))
local scope={vid=input.credentials.vid,epoch=1}
local settings={data_dir=dir,cache_dir=dir,mock_endpoint=input.mock_endpoint,
    get=function(_,_,default) return default end,get_auth_scope=function() return scope end,auth_scope_matches=function(_,s) return s==scope end}
local store={read=function() return input.credentials,1,nil,false end}
local Access=require('weread.lib.native_read_access');local original=Access.capture
Access.capture=function(s,existing) return original(s,existing or store) end
local selected=assert(Access.capture(settings));local client=require('weread.lib.client'):new(settings)
local auth=require('weread.lib.native_authorization'):new(client,{expected_vid=scope.vid,
    is_current=function() return Access.matches(settings,selected) end})
local catalog=require('weread.lib.native_book_catalog').read(auth,input.credentials,'42','native_catalog');auth:cancel()
local row=assert(catalog.reading_chapters[1]);assert(row.chapterUid=='37' and row.chapterIdx==1)
row.catalog_order=1;row.catalog_count=1
local expected={book_id='42',chapter_uid='37',book_version=catalog.version,
    reading_catalog_sha256=catalog.reading_digest,access_fingerprint=selected.fingerprint}
local result=assert(require('weread.lib.native_direct_reader').build(client,settings,
    {book_id='42',title='Synthetic',author='Fixture'},row,expected,{is_current=function() return true end}))
print('WEREAD_POSITION_PREPARED='..json.encode{path=result.path})
