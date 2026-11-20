package.path='./?.lua;'..package.path
local state,Guard
local Reader,Utility={},{}
local function pack(...) return {n=select('#',...),...} end
local function original(ui,path,...)
    if state.raise then error('synthetic switch failure') end
    state.switched=(state.switched or 0)+1;state.last={ui=ui,path=path,args=pack(...)}
    return 'native',nil,'tail'
end
local function provider()
    if state.article and not state.stamped and not state.disabled then assert(state.preserved,'provider read before preserving raw records') end
    state.providers=(state.providers or 0)+1;return state.provider,true
end
local function stock_utility(ui,path,pre)
    if pre then pre() end
    local engine,forced=provider()
    if engine and engine.order then state.auxiliary=true;return end
    ui:switchDocument(path,nil,nil,engine,forced)
end
package.preload['apps/reader/readerui']=function() return Reader end
package.preload['apps/filemanager/filemanagerutil']=function() return Utility end
package.preload['document/documentregistry']=function() return {getProvider=provider} end
package.preload['ui/uimanager']=function() return {show=function() end,close=function(_self,widget)
    if widget.onCloseWidget then widget:onCloseWidget() end
end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_self,options) return options end} end
package.preload['ui/bidi']=function() return {filename=function(value) return value end} end
package.preload['ui/event']=function() return {new=function(_self,value) return value end} end
package.preload['dump']=function() return function() return '{synthetic_live=true}' end end
package.preload['weread.lib.mp_file_identity']=function() return {resolve=function(_settings,path)
    if state.resolve_error then error('private-source') end
    return state.article and {book={},article={},input={path=path,stamped=state.stamped,legacy=not state.stamped}} or nil
end} end
package.preload['weread.lib.mp_record_recovery']=function() return {
    freeze=function() state.frozen=true;return {{kind='primary',raw='synthetic-old'}} end,
    hash_directory=function(path) return state.shared and 'shared' or path end,
    matches=function() return not state.source_changed end,
    preserve=function(_store,_input,rows)
        assert(state.frozen);state.preserved=not state.fail_save;state.rows=rows;return state.preserved
    end} end
package.preload['weread.lib.mp_records_db']=function() return {new=function() return {} end} end
package.preload['weread.lib.plugin_util']=function() return {tr=function(value) return value end,unpack_args=unpack} end
package.preload['weread.ui.mp_record_recovery']=function() return {
    cancel=function() end,open=function(host,_book,_article,_path,options)
        state.recoveries=(state.recoveries or 0)+1;state.options=options
        -- Real recovery closes plugin views and advances their epoch itself.
        host:closeWeReadUI();return true
    end} end
Guard=require('weread.ui.mp_reader_open')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local function fixture()
    state={provider={provider='crengine'},account='owner'};Reader.switchDocument=original;Utility.openFile=stock_utility
    G_reader_settings={readSetting=function() return state.disabled and {weread=true} or {} end,
        isTrue=function(_self,key) return key=='file_ask_to_open' and state.ask end}
    local ui=setmetatable({document={file='/open/current.html'},doc_settings={data={}},handleEvent=function() state.saved=true end},{__index=Reader})
    local host={ui=ui,settings={},_reader_session_gen=1,discovery_epoch=1,
        library_db={accountKey=function() return state.account end},
        closeWeReadUI=function(self) self.discovery_epoch=self.discovery_epoch+1 end,
        showInfo=function(_self,text) state.notice=text end}
    ui.weread=host;Reader.instance=ui;assert(Guard.attach(host));return ui,host
end
local ui,host=fixture();local installed=Reader.switchDocument
expect(Guard.attach(host) and installed==Reader.switchDocument,'adapter installed twice')
local a,b,c=ui:switchDocument('/local/ordinary.epub')
expect(a=='native' and b==nil and c=='tail' and state.switched==1,'unrelated reader return contract changed')
ui=fixture();state.article=true
expect(not pcall(stock_utility,ui,'/cache/old.html'),'stock provider-before-capture gap not reproduced')
Utility.openFile(ui,'/cache/old.html',function() state.pre=(state.pre or 0)+1 end)
expect(state.preserved and state.providers==1 and state.recoveries==1 and state.pre==1 and not state.switched,
    'history bypassed capture, caller callback or explicit recovery')
expect(state.options.context_valid(),'recovery invalidated itself while closing its plugin views')
state.options.open_file('/cache/new.html')
expect(state.switched==1 and state.last.path=='/cache/new.html' and state.last.args[3]==state.provider and state.last.args[4],
    'native history provider/forced state not preserved')
state.options.open_file('/cache/new.html');expect(state.switched==1,'completed opener could replay')
ui=fixture();state.article=true;local after=function() end;local forced={provider='crengine'}
ui:switchDocument('/cache/old.epub',true,after,forced,true);state.options.open_file('/cache/copy.epub')
expect(state.last.args.n==4 and state.last.args[1] and state.last.args[2]==after and state.last.args[3]==forced
    and state.last.args[4],'switch parameters or callback holes changed')
ui,host=fixture();state.article=true;state.ask=true
Utility.openFile(ui,'/cache/old.html');local dialog=assert(host._mp_reader_open_confirmation)
expect(state.preserved and not state.providers and not state.recoveries,'native ask happened after provider migration')
dialog.cancel_callback();dialog.ok_callback()
expect(not host._mp_reader_open_confirmation and not state.providers and not state.switched,'cancelled ask retained a late opener')
ui,host=fixture();state.article=true;state.ask=true
Utility.openFile(ui,'/cache/old.html');dialog=host._mp_reader_open_confirmation;dialog.ok_callback()
expect(state.providers==1 and state.recoveries==1 and not host._mp_reader_open_confirmation,'confirmed native ask did not hand off once')
dialog.ok_callback();expect(state.providers==1,'native open confirmation could replay')
ui,host=fixture();state.article=true;state.ask=true;Utility.openFile(ui,'/cache/old.html')
dialog=host._mp_reader_open_confirmation;state.source_changed=true;dialog.ok_callback()
expect(not state.providers and not state.recoveries and state.notice,'changed source reached provider from an old open prompt')
for _i,event in ipairs({'account','session','document','instance','closing','detached','cancel','another_file'}) do
    ui,host=fixture();state.article=true;ui:switchDocument('/cache/old.html');local options=state.options
    if event=='account' then state.account='new-owner'
    elseif event=='session' then host._reader_session_gen=2
    elseif event=='document' then ui.document={file='/other'}
    elseif event=='instance' then Reader.instance={}
    elseif event=='closing' then ui.tearing_down=true
    elseif event=='detached' then Guard.detach(host)
    elseif event=='cancel' then Guard.cancel(host)
    else state.article=false;ui:switchDocument('/local/other.epub') end
    local before=state.switched or 0;options.open_file('/cache/stale.html')
    expect(not options.context_valid() and (state.switched or 0)==before,'stale recovery opened after '..event)
end
ui=fixture();state.article=true;state.fail_save=true;ui:switchDocument('/cache/old.html')
expect(state.notice and not state.providers and not state.switched and not state.recoveries,'snapshot failure reached native provider')
ui=fixture();state.article=true;state.shared=true;ui:switchDocument('/cache/old.html')
expect(state.saved and state.rows[2].kind=='live','unsaved current shared notes omitted before provider lookup')
ui=fixture();state.article=true;state.stamped=true;ui:switchDocument('/cache/new.epub')
expect(state.switched==1 and not state.frozen and not state.recoveries,'independent article no longer opens directly')
ui=fixture();state.article=true;state.disabled=true;ui:switchDocument('/cache/old.html')
expect(state.switched==1 and not state.frozen,'disabled plugin still intercepted native reading')
ui,host=fixture();state.article=true;local previous=Reader.switchDocument;local third_party=0
Reader.switchDocument=function(self,path,...) third_party=third_party+1;return previous(self,path,...) end
Guard.attach(host);ui:switchDocument('/cache/old.html');state.options.open_file('/cache/copy.html')
expect(state.recoveries==1 and state.switched==1 and third_party==1,'third-party wrapper recursed or repeated recovery')
ui=fixture();state.raise=true;expect(not pcall(ui.switchDocument,ui,'/local/error.epub'),'native switch failure swallowed')
state.raise=false;state.article=true;ui:switchDocument('/cache/old.html')
expect(state.recoveries==1 and not state.switched,'failed delegation left a bypass guard')
print('mp_reader_open_spec: '..checks..' checks')
