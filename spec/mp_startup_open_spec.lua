package.path='./?.lua;'..package.path
local state, Guard
local Reader, FM = {}, {}
local function pack(...) return {n=select('#',...),...} end
local function original(class,path,...)
    state.calls=(state.calls or 0)+1;state.path=path;state.args=pack(...)
    if state.raise then error('native error',0) end
    if state.args[4] then state.args[4]() end
    return 'native',nil,'tail'
end
Reader.showReader=original
function FM:showFiles(path)
    if state.owned and not state.failure then assert(state.preserved,'first list preceded snapshot commit') end
    state.manager_path=path;state.managers=(state.managers or 0)+1
    local host={library_db={accountKey=function() return state.account end},
        showInfo=function(_self,message) state.notice=message end,
        closeWeReadUI=function() state.closed=(state.closed or 0)+1 end}
    self.instance={weread=host};return self.instance
end
package.preload['apps/reader/readerui']=function() return Reader end
package.preload['apps/filemanager/filemanager']=function() return FM end
package.preload['weread.lib.plugin_util']=function() return {unpack_args=unpack,tr=function(value) return value end} end
package.preload['weread.lib.settings']=function() return {new=function()
    state.settings=(state.settings or 0)+1;return {}
end} end
package.preload['weread.lib.library_db']=function() return {new=function() return {accountKey=function() return state.account end} end} end
package.preload['weread.lib.mp_file_identity']=function() return {resolve=function(_settings,path)
    if state.failure=='resolve' then error('private source details',0) end
    return state.owned and {book={},article={},input={path=path,key='key',stamped=state.stamped,legacy=not state.stamped}} or nil
end} end
package.preload['weread.lib.mp_record_recovery']=function() return {
    freeze=function() return state.empty and {} or {{raw='primary'},{raw='backup'}} end,
    preserve=function()
        state.preserved=true
        if state.failure=='save' then error('private storage details',0) end
        return true
    end,
    matches=function() return state.failure~='changed' end,
} end
package.preload['weread.lib.mp_records_db']=function() return {new=function() return {list=function()
    if state.failure=='list' then return nil end
    return state.saved and {{id='saved'}} or {}
end} end} end
package.preload['document/documentregistry']=function() return {getProvider=function()
    assert(state.preserved,'provider preceded snapshot commit')
    state.providers=(state.providers or 0)+1;return state.provider
end} end
package.preload['weread.ui.mp_record_recovery']=function() return {open=function(host,_book,_article,path,options)
    assert(state.preserved);state.options=options;state.source=path;state.recoveries=(state.recoveries or 0)+1
    host.mp_records_job={};return true
end} end
Guard=require('weread.ui.mp_startup_open')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    state={owned=true,account='owner',provider={provider='crengine'}}
    Reader.showReader=original;Reader.instance=nil;FM.instance=nil
    G_reader_settings={readSetting=function() return state.disabled and {weread=true} or {} end,
        isTrue=function() return state.external_disabled end}
    assert(Guard.install())
end
fixture();local first=Reader.showReader
expect(Guard.install() and Reader.showReader==first,'installation stacked its own adapter')
local callback_count=0;local callback=function() callback_count=callback_count+1 end
Reader:showReader('/cache/old.html',nil,true,false,callback)
expect(state.preserved and state.providers==1 and state.managers==1 and state.recoveries==1 and not state.calls,
    'startup did not preserve before provider/list/recovery')
expect(state.options.context_valid() and state.manager_path=='/cache' and callback_count==0,'startup lost context or called back early')
state.options.open_file('/cache/new.html')
expect(state.calls==1 and state.path=='/cache/new.html' and state.args.n==4 and state.args[1]==state.provider
    and state.args[2]==true and state.args[3]==false and state.args[4]==callback and callback_count==1,
    'selected copy lost original engine, seamless/forced flags or callback')
state.options.open_file('/cache/late.html')
expect(state.calls==1,'startup result was accepted twice')
fixture();local forced={provider='crengine'}
Reader:showReader('/cache/old.epub',forced,nil,true,callback);state.options.open_file('/cache/new.epub')
expect(not state.providers and state.args[1]==forced and state.args[2]==nil and state.args[3]==true,
    'explicit startup provider or nil hole changed')
for _i,mode in ipairs({'normal','stamped','reader','manager','disabled','external_disabled','auxiliary','other_engine','empty'}) do
    fixture()
    local provider
    if mode=='normal' then state.owned=false elseif mode=='stamped' then state.stamped=true
    elseif mode=='reader' then Reader.instance={} elseif mode=='manager' then FM.instance={}
    elseif mode=='disabled' then state.disabled=true elseif mode=='external_disabled' then state.external_disabled=true
    elseif mode=='auxiliary' then provider={order=1,provider='editor'}
    elseif mode=='other_engine' then provider={provider='mupdf'} else state.empty=true end
    local a,b,c=Reader:showReader('/safe.epub',provider,nil,nil,callback)
    expect(a=='native' and b==nil and c=='tail' and state.calls==1 and not state.recoveries,
        'unaffected startup changed its native return contract: '..mode)
end
fixture();state.empty=true;state.saved=true;Reader:showReader('/cache/old.html')
expect(state.recoveries==1 and not state.calls,'persisted snapshots were ignored when original sidecars were absent')
fixture();state.provider={provider='mupdf'};Reader:showReader('/cache/old.epub')
expect(state.calls==1 and not state.managers,'default non-CRE engine was intercepted')
for _i,failure in ipairs({'resolve','save','changed','list'}) do
    fixture();state.failure=failure;Reader:showReader('/cache/old.html')
    expect(state.managers==1 and state.notice and not state.notice:find('private',1,true) and not state.calls,
        'failed startup entered native reader or leaked detail: '..failure)
end
for _i,mode in ipairs({'cancel','account','manager_replaced','closing','disabled','reader_created'}) do
    fixture();Reader:showReader('/cache/old.html');local options=state.options
    if mode=='cancel' then options.on_cancel()
    elseif mode=='account' then state.account='new-owner'
    elseif mode=='manager_replaced' then FM.instance={}
    elseif mode=='closing' then FM.instance.tearing_down=true
    elseif mode=='disabled' then state.disabled=true else Reader.instance={} end
    options.open_file('/cache/stale.html')
    expect(not options.context_valid() and not state.calls,'obsolete startup callback opened a reader: '..mode)
end
fixture();state.owned=false;state.raise=true
local ok,why=pcall(Reader.showReader,Reader,'/safe.epub')
expect(not ok and why=='native error','native error was swallowed')
state.raise=false;state.owned=true;Reader:showReader('/cache/old.html')
expect(state.recoveries==1,'native failure left a delegation bypass')
fixture();local previous=Reader.showReader;local other=0
Reader.showReader=function(...) other=other+1;return previous(...) end
Guard.install();Reader:showReader('/cache/old.html');state.options.open_file('/cache/new.html')
expect(state.recoveries==1 and state.calls==1 and other==1,'another startup wrapper caused recursion or duplicate recovery')
G_reader_settings=nil
print('mp_startup_open_spec: '..checks..' checks')
