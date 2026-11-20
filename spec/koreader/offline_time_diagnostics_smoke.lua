-- Real KOReader Menu/ButtonDialog, worker and SQLite using synthetic ledger rows.
require('ffi').log=function() end
require('setupkoenv')
local home=assert(os.getenv('KO_HOME'));assert(home:match('^/dev/shm/weread%-time%-reasons%-%w+$'))
local source=assert(os.getenv('WEREAD_SOURCE'));package.path=source..'/?.lua;'..package.path
G_defaults=require('luadefaults'):open();G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
local Device=require('device');require('document/canvascontext'):init(Device)
local UI=require('ui/uimanager');local socket=require('socket');local json=require('json')
local Ledger=require('weread.lib.offline_time_store');local Coverage=require('weread.lib.readtime_coverage')
local Common=require('weread.ui.common');local Review=require('weread.ui.offline_time_review')
local Day=require('weread.lib.readtime_accounting').day;local Contract=require('weread.lib.readtime_transfer_contract')
local tr=require('weread.lib.plugin_util').tr
local account=string.rep('a',20);local ledger=Ledger:new(home);local day=Day(os.time());assert(os.time()>day+60)
local coverage=Coverage:new(home,function() return day-3*86400 end);assert(coverage:initialize())
local windows={}
local function add(start,zone,unsupported)
    local id=assert(ledger:begin(account,{book_id='42',stats_book=1,start_time=start,time_zone=zone or '+08:00',
        book_version=unsupported and 0 or 7,file_id=unsupported and '' or string.rep('f',64),
        version_source=unsupported and 'unavailable' or 'epub_snapshot'}))
    windows[#windows+1]={id=id,start=start}
end
add(day-86400-300,nil,true)
local earlier=day-2*86400+100;add(earlier)
add(day-86400+100);add(os.time()-20);add(day-86400+200,'+09:00')
add(day-4*86400+100);add(day-86400+300);add(day-86400+300)
for _,window in ipairs(windows) do
    assert(ledger:collect(account,window.id,{{page='1',start_time=window.start,duration=10}},window.start+10,true))
end
assert(ledger:_access(account,function(db) db:exec("UPDATE segments SET state='unknown' WHERE id=(SELECT MAX(id) FROM segments)");return true end))
assert(coverage:reserve(account,earlier+5,5))
local before=Contract.digest(assert(ledger:review_page(account,'all',0,nil,20)))
local scope={epoch=1};local host={settings={data_dir=home,get_auth_scope=function() return scope end,
    auth_scope_matches=function(_self,value) return value==scope end},ui={document={}},_reader_session_gen=1,
    library_db={accountKey=function() return account end,getBook=function() return {title='合成阅读书籍'} end},
    offline_time={store=ledger,state='disabled',update=function() end},readtime_coverage=coverage,
    client={json_encode=function(_self,value) return json.encode(value) end,json_decode=function(_self,value) return json.decode(value) end,
        request=function() error('unexpected network') end},showList=Common.showList,showBusy=Common.showBusy,
    closeBusy=Common.closeBusy,refreshUI=Common.refreshUI,showInfo=Common.showInfo}
function host:closeWeReadUI() Review.close(self);self.discovery_epoch=(self.discovery_epoch or 0)+1 end
local function pump(predicate)
    local until_time=socket.gettime()+20
    while not predicate() do assert(socket.gettime()<until_time,'worker timeout');UI:setInputTimeout(0);UI:handleInput();socket.sleep(.01) end
end
local function choose(label)
    for _,row in ipairs(assert(host._offline_time_menu).item_table) do
        if row.text==tr(label) then host._offline_time_menu:onMenuSelect(row);return end
    end
    error('missing menu action')
end
local function button(label)
    for _,row in ipairs(assert(host._offline_time_detail).buttons) do for _,item in ipairs(row) do
        if item.text==tr(label) then item.callback();return end
    end end
    error('missing dialog action')
end
Review.show(host);pump(function() return host._offline_time_menu~=nil end)
choose('Check saved time');pump(function() return host._offline_time_detail~=nil end)
assert(host._offline_time_detail.title:find('5 秒',1,true));button('Why some time was not selected')
local details=assert(host._offline_time_detail).title
for _,entry in ipairs({{'Today in Beijing time: %1','10 秒'},{'Other time zones, not yet transferable: %1','10 秒'},
    {'Other historical dates, for a later batch: %1','10 秒'},{'Source or time needs verification: %1','10 秒'},
    {'Before coverage tracking began: %1','10 秒'},{'Reserved for other reports: %1','5 秒'},
    {'Overlapping local records: %1','10 秒'}}) do
    assert(details:find((tr(entry[1]):gsub('%%1',entry[2])),1,true),'missing diagnostic')
end
UI:forceRePaint();local shot=os.getenv('WEREAD_SHOT');if shot then Device.screen:shot(shot) end
button('Back');pump(function() return host._offline_time_detail~=nil end);button('Skip this book for now')
pump(function() return host._offline_time_detail~=nil end)
assert(host._offline_time_detail.title:find(tr('No locally verified time is available in this check.'),1,true))
button('Why some time was not selected');assert(host._offline_time_detail.title:find(tr('Books skipped in this session: %1'):gsub('%%1','60 秒'),1,true))
button('Close');assert(not host._offline_time_review)
assert(Contract.digest(assert(ledger:review_page(account,'all',0,nil,20)))==before)
print('PASS: real KOReader offline diagnostics, skip, ledger preservation and no network')
