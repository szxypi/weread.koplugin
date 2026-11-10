package.path='./?.lua;'..package.path
local state, Guard
local FM, Reader, Doc, List = {}, {}, {}, {}
local function pack(...) return {n=select('#', ...), ...} end
local function native_doc(self, path, ...)
    if state.expect_protected then assert(state.saved[path], 'native read preceded raw preservation') end
    state.reads = (state.reads or 0)+1
    state.doc_args = pack(...)
    if state.native_error then error('native failure', 0) end
    return {path=path}, nil, 'doc-tail'
end
local function native_list(path, ...)
    state.list_args = pack(...)
    if state.cached then return state.cached, nil, 'cached-tail' end
    if state.nested and path=='/old.html' then List.getBookInfo('/inner.html') end
    local data, hole, tail = Doc:open(path, nil, 'provider')
    assert(hole==nil and tail=='doc-tail')
    return {path=data.path, percent_finished=.25}, nil, 'list-tail'
end
package.preload['apps/filemanager/filemanager']=function() return FM end
package.preload['apps/reader/readerui']=function() return Reader end
package.preload['docsettings']=function() return Doc end
package.preload['ui/widget/booklist']=function() return List end
require('apps/filemanager/filemanager'); require('apps/reader/readerui')
package.preload['weread.lib.plugin_util']=function() return {unpack_args=unpack} end
package.preload['weread.lib.mp_file_identity']=function() return {resolve=function(_settings, path)
    state.resolutions=(state.resolutions or 0)+1
    if state.resolve_error then error('private source value', 0) end
    if state.owned then return {book={}, article={}, input={path=path,stamped=state.stamped,legacy=not state.stamped}} end
end} end
package.preload['weread.lib.mp_record_recovery']=function() return {
    freeze=function(input)
        state.frozen=(state.frozen or 0)+1
        if state.recursive then Doc:open(input.path) end
        return {{raw='original'}}
    end,
    preserve=function(store, input, rows)
        assert(store and rows[1].raw=='original')
        state.preserves=(state.preserves or 0)+1
        if state.account_change then state.account='other' end
        if state.preserve_error then error('private storage value', 0) end
        if state.preserve_failed then return false end
        state.saved[input.path]=true; return true
    end,
    matches=function() return not state.changed end,
} end
package.preload['weread.lib.mp_records_db']=function() return {new=function(_settings, account)
    state.store_account=account; return {}
end} end
Guard=require('weread.ui.mp_metadata_preview')
local checks=0
local function expect(value, message) checks=checks+1; assert(value, message) end
local function fixture(kind)
    state={saved={},owned=true,account='account'}
    Doc.open, List.getBookInfo = native_doc, native_list
    FM.instance, Reader.instance = nil, nil
    G_reader_settings=nil
    local ui = kind=='reader' and {document={}} or {openFile=function() end}
    local host={ui=ui,settings={},library_db={accountKey=function() return state.account end}}
    ui.weread=host
    if kind=='reader' then Reader.instance=ui elseif kind~='initializing' then FM.instance=ui end
    assert(Guard.attach(host)); return host, ui
end
local host=fixture();local ui;state.expect_protected=true
local a,b,c=List.getBookInfo('/old.html',nil,'tail')
expect(a.path=='/old.html' and b==nil and c=='list-tail' and state.preserves==1 and state.reads==1,
    'BookList did not preserve before its actual native settings read')
expect(state.list_args.n==2 and state.list_args[1]==nil and state.list_args[2]=='tail'
    and state.doc_args.n==2 and state.doc_args[1]==nil and state.doc_args[2]=='provider', 'call contracts lost nil holes')
expect(state.store_account=='account', 'snapshots used another account')
local list_wrapper, doc_wrapper=List.getBookInfo, Doc.open
expect(Guard.attach(host) and List.getBookInfo==list_wrapper and Doc.open==doc_wrapper, 'repeat attach stacked adapters')
fixture('initializing');state.expect_protected=true;List.getBookInfo('/old.html')
expect(state.preserves==1 and state.reads==1, 'initial FileManager layout was not protected')
fixture('reader');state.expect_protected=true;List.getBookInfo('/old.html')
expect(state.preserves==1, 'reader history metadata was not protected')
for _i, mode in ipairs({'unrelated','stamped','cached'}) do
    fixture()
    if mode=='unrelated' then state.owned=false elseif mode=='stamped' then state.stamped=true
    else state.cached={marker=true} end
    local info, hole, tail=List.getBookInfo('/safe.epub')
    expect(not state.frozen and not state.preserves and hole==nil and tail,
        'safe/cached metadata caused snapshot I/O: '..mode)
    if mode=='cached' then expect(info==state.cached and not state.resolutions and not state.reads, 'cache hit opened settings') end
end
for _i, mode in ipairs({'resolve_error','preserve_failed','preserve_error','changed','account_change','recursive'}) do
    fixture();state[mode]=true
    local info=List.getBookInfo('/old.html')
    expect(info._weread_metadata_unavailable and info.been_opened==false and info.percent_finished==nil
        and info.has_annotations==nil and not state.reads,
        'failed preservation reached native migration or invented progress: '..mode)
    state[mode]=nil
    List.getBookInfo('/old.html')
    expect(state.reads==1, 'failed metadata poisoned later refresh: '..mode)
end
for _i, mode in ipairs({'detached','replaced','closing','disabled','external_disabled'}) do
    host,ui=fixture()
    if mode=='detached' then Guard.detach(host)
    elseif mode=='replaced' then FM.instance={}
    elseif mode=='closing' then ui.tearing_down=true
    else G_reader_settings={readSetting=function() return mode=='disabled' and {weread=true} or {} end,
        isTrue=function() return mode=='external_disabled' end} end
    List.getBookInfo('/old.html')
    expect(not state.preserves and state.reads==1, 'inactive plugin altered native metadata: '..mode)
end
fixture();local data,hole,tail=Doc:open('/old.html',nil,'direct')
expect(data.path=='/old.html' and hole==nil and tail=='doc-tail' and not state.resolutions,
    'non-BookList settings access was intercepted')
fixture();state.nested=true;state.expect_protected=true;List.getBookInfo('/old.html')
expect(state.preserves==2 and state.saved['/inner.html'] and state.saved['/old.html'], 'nested metadata lost its enclosing scope')
fixture();state.native_error=true
local ok,why=pcall(List.getBookInfo,'/old.html')
expect(not ok and why=='native failure', 'native errors were hidden')
state.native_error=nil;state.owned=false;Doc:open('/after.epub')
expect(state.resolutions==1, 'native error retained an inspection scope')
host=fixture();state.expect_protected=true
local old_list,old_doc=List.getBookInfo,Doc.open
local interposed_list,interposed_doc=0,0
List.getBookInfo=function(...) interposed_list=interposed_list+1;return old_list(...) end
Doc.open=function(...) interposed_doc=interposed_doc+1;return old_doc(...) end
assert(Guard.attach(host));List.getBookInfo('/old.html')
expect(state.preserves==1 and state.reads==1 and interposed_list==1 and interposed_doc==1,
    'third-party adapters caused recursion or duplicate preservation')
Guard.detach(host);G_reader_settings=nil
expect(not Guard.attach({ui={}}), 'unsupported plugin host installed global metadata adapters')
print('mp_metadata_preview_spec: '..checks..' checks')
