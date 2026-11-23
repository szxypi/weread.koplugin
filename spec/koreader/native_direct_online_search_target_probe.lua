-- Real KOReader and synthetic services; search candidates remain local-only.
require('jit').off();require('ffi').log=function() end;require('setupkoenv')
assert(os.getenv('WEREAD_SYNTHETIC')=='1')
local home=assert(os.getenv('KO_HOME'));local plugin=home..'/plugins/weread.koplugin'
package.path=plugin..'/?.lua;'..package.path
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua');G_defaults=require('luadefaults'):open()
G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json');local input=json.decode(assert(io.stdin:read('*a')))
local settings=require('weread.lib.settings'):new();assert(settings.data_dir==home..'/weread')
settings.mock_endpoint=input.mock_endpoint
settings:set('account',{user_vid=input.credentials.vid,name='Synthetic',login_method='qr'})
settings:set('cookies',{wr_vid = input.credentials.vid,wr_skey='synthetic-web-access'});settings:flush()
local scope=assert(settings:get_auth_scope())
assert(require('weread.lib.native_credentials'):new(settings):save(input.credentials,scope,0,1))
local native=assert(require('weread.lib.native_read_access').capture(settings))
local web=assert(require('weread.lib.source_currentness').capture(settings))
local client=require('weread.lib.client'):new(settings)
local Cache=require('weread.lib.native_direct_cache');local active=function() return settings:auth_scope_matches(scope) end
local source=assert(Cache.identify(settings,scope.vid,input.path,active))
local search=require('weread.lib.native_direct_online_search_target')
local book={book_id='42',title='Synthetic',author='Fixture'}
local resolved,reason=search.resolve(client,settings,source,input.path,input.hit,native,web,active,false,book)
if input.case=='download' or input.case=='denied' then
    assert(not resolved and reason=='not_saved')
    resolved,reason=search.resolve(client,settings,source,input.path,input.hit,native,web,active,true,book)
end
if input.case=='denied' then assert(not resolved and reason=='not_entitled')
elseif input.case=='mismatch' then assert(not resolved and reason=='source_changed')
else
    assert(resolved and resolved.local_only and resolved.entry.chapter_uid==input.hit.chapter_uid
        and resolved.entry.book_id=='42' and type(resolved.anchor)=='table')
    if input.case=='cached' then assert(resolved.path==input.second and resolved.reused==true)
    elseif input.case=='download' then assert(resolved.path~=input.path and resolved.reused==false)
    else assert(resolved.path==input.path) end
    local UI=require('ui/uimanager');local socket=require('socket');local Reader=require('apps/reader/readerui')
    Reader:showReader(resolved.path)
    local deadline=socket.gettime()+90
    while not (Reader.instance and Reader.instance.document) do
        assert(socket.gettime()<deadline);UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01)
    end
    UI:forceRePaint();local reader=Reader.instance;local doc=reader.document
    local identity=require('weread.lib.book_file_identity').read_document(doc,'42')
    local index=assert(require('weread.lib.source_dom').open_direct_prepared(doc,'42',input.hit.chapter_uid,identity,
        {is_current=function() return Reader.instance==reader end}))
    local point=assert(index:locate_anchor(resolved.anchor))
    local matches=assert(doc:findAllText(input.hit.text,false,0,5,false,0));assert(#matches==1 and matches[1].start)
    assert(doc:compareXPointers(point.xpointer,matches[1].start)==0,'native anchor differs from independently found text')
end
print('WEREAD_NATIVE_ONLINE_TARGET='..json.encode{ok=true,case=input.case,verified=resolved~=nil,
    downloaded=input.case=='download',no_cloud_write=true})
