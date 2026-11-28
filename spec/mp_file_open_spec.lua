package.path='./?.lua;'..package.path
local state,Guard
local FM={}
local function pack(...) return {n=select('#',...),...} end
local function original(ui,path,...)
    if state.raise then error('synthetic delegate failure') end
    state.delegated=(state.delegated or 0)+1;state.last={ui=ui,path=path,args=pack(...)}
    return 'original',nil,'tail'
end
FM.openFile=original
package.preload['apps/filemanager/filemanager']=function() return FM end
package.preload['document/documentregistry']=function() return {getProvider=function(_self,_path,aux)
    assert(aux==true and state.preserved);return state.provider
end} end
package.preload['weread.lib.mp_file_identity']=function() return {resolve=function()
    state.resolutions=(state.resolutions or 0)+1
    if state.resolve_error then error('private-source-value') end
    return state.article and {book={},article={},input={legacy=not state.stamped,stamped=state.stamped}} or nil
end} end
package.preload['weread.lib.mp_record_recovery']=function() return {
    freeze=function() state.frozen=true;return {} end,
    preserve=function() assert(state.frozen);state.preserved=true;return not state.preserve_failed end} end
package.preload['weread.lib.mp_records_db']=function() return {new=function() return {} end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,unpack_args=unpack} end
package.preload['weread.ui.mp_record_recovery']=function() return {
    cancel=function() state.cancelled=(state.cancelled or 0)+1 end,
    open=function(host,_book,_article,path,options)
        state.recoveries=(state.recoveries or 0)+1;state.options=options;state.recovery_host=host;state.source=path
        return true
    end} end
Guard=require('weread.ui.mp_file_open')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    FM.openFile=original
    state={provider={provider='crengine'}}
    local ui=setmetatable({},{__index=FM});local host={ui=ui,settings={},
        showInfo=function(_self,value) state.notice=value end,
        closeWeReadUI=function() state.closed=(state.closed or 0)+1 end}
    ui.weread=host;FM.instance=ui;assert(Guard.attach(host));return ui,host
end
local ui,host=fixture();local wrapper=FM.openFile
expect(Guard.attach(host) and FM.openFile==wrapper,'installation duplicated the same adapter')
local a,b,c=ui:openFile('/local/book.epub')
expect(a=='original' and b==nil and c=='tail' and state.delegated==1 and state.resolutions==1,'normal file changed its return contract')
ui=fixture();state.article=true
local callback=function() end
expect(ui:openFile('/cache/old.html',nil,nil,nil,callback) and state.recoveries==1 and not state.delegated,'old article reached the original reader before recovery')
expect(state.options.context_valid() and state.source=='/cache/old.html','recovery context lost the original path')
state.options.open_file('/cache/copy.html')
expect(state.delegated==1 and state.closed==1 and state.last.path=='/cache/copy.html','selected copy not handed to the native file manager')
expect(state.last.args.n==4 and state.last.args[1]==state.provider and state.last.args[2]==nil and state.last.args[3]==nil
    and state.last.args[4]==callback,'reader engine, nil holes or after-open callback were lost')
ui=fixture();state.article=true;local provider={provider='crengine'}
ui:openFile('/cache/old.epub',provider,callback,nil,callback);state.options.open_file('/cache/copy.epub')
expect(state.last.args[1]==provider and state.last.args[2]==callback and state.last.args[4]==callback,'forced provider/caller callbacks changed')
for _i,mode in ipairs({'auxiliary','other_engine','no_engine'}) do
    ui=fixture();state.article=true
    state.provider=mode=='auxiliary' and {provider='editor',order=1} or mode=='other_engine' and {provider='mupdf'} or nil
    ui:openFile('/cache/old.epub')
    expect(state.delegated==1 and not state.recoveries,'auxiliary/unsupported route was intercepted: '..mode)
end
for _i,mode in ipairs({'detached','replaced','closing','another_file','account_callback'}) do
    ui,host=fixture();state.article=true;ui:openFile('/cache/old.html');local saved=state.options
    if mode=='detached' then Guard.detach(host)
    elseif mode=='replaced' then FM.instance={}
    elseif mode=='closing' then ui.tearing_down=true
    elseif mode=='another_file' then state.article=false;ui:openFile('/local/new.epub')
    else Guard.cancel(host) end
    local before=state.delegated or 0;saved.open_file('/cache/stale.html')
    expect(not saved.context_valid() and (state.delegated or 0)==before,'stale context opened an article: '..mode)
end
ui=fixture();state.resolve_error=true;ui:openFile('/cache/old.html')
expect(state.notice and not state.notice:find('private-',1,true) and not state.delegated,'invalid source opened or leaked its failure')
ui,host=fixture();local previous=FM.openFile;local third_party=0
FM.openFile=function(self,path,...) third_party=third_party+1;return previous(self,path,...) end
Guard.attach(host);state.article=true;ui:openFile('/cache/old.html');state.options.open_file('/cache/copy.html')
expect(state.recoveries==1 and state.delegated==1 and third_party==1,'another plugin wrapper caused recursion or duplicate recovery')
ui=fixture();state.raise=true
expect(not pcall(ui.openFile,ui,'/local/error.epub'),'native failure was swallowed')
state.raise=false;state.article=true;ui:openFile('/cache/old.html')
expect(state.recoveries==1 and not state.delegated,'failed delegation left a bypass permit behind')
ui=fixture();state.article=true;state.preserve_failed=true;ui:openFile('/cache/old.html')
expect(state.notice and not state.delegated and not state.recoveries,'snapshot failure reached native provider/reader')
ui=fixture();state.article=true;state.stamped=true;ui:openFile('/cache/new.epub')
expect(state.delegated==1 and not state.frozen and not state.recoveries,'independent version no longer opened directly')
ui,host=fixture();ui.document={}
expect(not Guard.attach(host),'reader widget was mistaken for a file manager')
print('PASS: native FileManager adapter, callbacks, interposition and stale contexts ('..checks..' checks)')
