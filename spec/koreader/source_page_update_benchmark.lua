-- Synthetic reader events; no network, credentials, book files or account data.
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'))
package.path=home..'/plugins/weread.koplugin/?.lua;'..package.path
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local json=require('json')
local Identity=require('weread.lib.book_file_identity')
local Crypto=require('weread.lib.crypto')
local book={book_id='42',bookVersion=1}
local root=Identity.encode(book,{{chapterUid=1}},Identity.capture(book),Crypto.sha256_hex('synthetic'))
local page,positions=1,0
local doc={file='/synthetic.epub',getDocumentFileContent=function(_,path) assert(path==Identity.PATH);return root end,
    getCurrentPage=function() return page end,getCurrentPos=function() return page*100 end,
    getPageXPointer=function(_,value) positions=positions+1;return '/body/DocFragment[1]/body/p/text().'..value end,
    getNormalizedXPointer=function(_,value) return value end}
local scheduled
local scheduler={scheduleIn=function(_,_,fn) scheduled=fn end,
    unschedule=function(_,fn) if scheduled==fn then scheduled=nil end end}
local Service=require('weread.lib.source_position')
local svc=Service:new{scheduler=scheduler,get_document=function() return doc end,get_book_id=function() return '42' end,
    get_account=function() return 'synthetic' end,get_mode=function() return 'page' end,
    get_retained=function() return nil end}
svc:on_reader_ready()
local function run(changing,n)
    local start=os.clock();positions=0
    for _=1,n do
        if changing then page=page+1 end
        assert(svc:on_view_changed())
    end
    return {calls=positions,cpu_ms=(os.clock()-start)*1000}
end
local changed=run(true,1000)
local unchanged=run(false,1000)
assert(svc.job and svc.job.scope.location.page==page and scheduled)
svc:stop();assert(not svc.job and not scheduled)
print('\nWEREAD_SOURCE_PAGE_BENCHMARK='..json.encode({result='PASS',changed=changed,unchanged=unchanged}))
