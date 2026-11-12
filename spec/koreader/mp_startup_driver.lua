-- A later validation userpatch observes the real reader.lua entry and loop.
local UI=require('ui/uimanager')
local Reader,FM=require('apps/reader/readerui'),require('apps/filemanager/filemanager')
local Json=require('json')
local evidence=assert(os.getenv('WEREAD_EVIDENCE'))
local phase=assert(os.getenv('WEREAD_STARTUP_PHASE'))
local function read(path)
    local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();return raw
end
local function write(path,raw)
    local f=assert(io.open(path,'wb'));assert(f:write(raw));assert(f:close())
end
local input=Json.decode(read(evidence..'/startup-input.json'))
assert(require('userpatch').execution_status['2-weread-startup-records.lua']==true)
assert(package.loaded['weread.ui.mp_startup_open'] and not Reader.instance and not FM.instance,
    'startup protection was not loaded before the native entry')
local Crypto=require('weread.lib.crypto')
local Settings=require('weread.lib.settings')
local Store=require('weread.lib.mp_records_db')
local Versions=require('weread.lib.mp_cache_versions')
local settings=Settings:new()
local store=assert(Store.new(settings,require('weread.lib.library_db'):new(settings):accountKey()))
local function preserved()
    local hashes={}
    for _i,row in ipairs(assert(store:list(input.key))) do hashes[Crypto.sha256_hex(assert(store:get(input.key,row.id)))]=true end
    for _i,hash in ipairs(input.original_raw_hashes) do assert(hashes[hash],'cold startup provider read preceded raw snapshot commit') end
end
local created,provider_reads=0,0
local permitted=phase=='reopen'
local new=Reader.new
Reader.new=function(class,options)
    assert(permitted,'native reader constructed before explicit record selection')
    created=created+1;return new(class,options)
end
local Doc=require('docsettings')
local native=Doc.open
Doc.open=function(self,path,...)
    if path==input.target and phase~='reopen' then preserved();provider_reads=provider_reads+1 end
    return native(self,path,...)
end
local report={result='UNVERIFIED',synthetic_only=true,real_reader_lua_entry=true,patch_loaded_before_native_entry=true,
    phase=phase,content=input.content,account_requests=0,account_data_writes=0}
local stage='waiting'
local deadline=require('socket').gettime()+60
local function verify_body(reader)
    local text=reader.document:getTextFromXPointer('/html/body') or reader.document:getTextFromXPointer('/body')
    assert(text and text:find(input.content=='epub' and 'FM_EPUB_TEXT' or 'OLDTEXT',1,true),'startup opened another body version')
    if input.content=='html' then assert(not text:find('NEWTEXT',1,true),'startup reused the other shared body cache') end
end
local function finish()
    assert(Crypto.sha256_hex(read(input.target))==input.source_sha256,'startup changed original article bytes')
    preserved()
    report.result='PASS';report.native_reader_instances=created;report.original_provider_reads=provider_reads
    write(evidence..'/startup-'..phase..'.json',Json.encode(report))
    Reader.new=new;Doc.open=native
    UI:quit(0)
end
local tick
tick=function()
    local ok,why=pcall(function()
        assert(require('socket').gettime()<deadline,'cold startup validation deadline')
        local top=UI:getTopmostVisibleWidget()
        -- A fresh official profile can show statistics' one-time migration
        -- notice. Dismiss that exact native message through its normal action;
        -- do not hide plugin errors or operate a recovery dialog underneath it.
        if top and type(top.onTapClose)=='function' then
            local gettext=require('gettext')
            local count=#require('readhistory').hist;assert(count<32)
            for n=0,count do
                local expected=require('ffi/util').template(gettext.ngettext(
                    'Conversion complete.\nImported one book to the database.\nTap to continue.',
                    'Conversion complete.\nImported %1 books to the database.\nTap to continue.',n),n)
                if top.text==expected then
                    top:onTapClose();report.native_statistics_notices_dismissed=(report.native_statistics_notices_dismissed or 0)+1
                    return
                end
            end
        end
        if phase=='reopen' then
            if not Reader.instance or not Reader.instance.weread or not Reader.instance.document then return end
            local expected=Json.decode(read(evidence..'/startup-recovered.json'))
            local reader=Reader.instance
            assert(reader.document.file==expected.path and not FM.instance and created==1)
            if UI:getTopmostVisibleWidget()~=reader then return end
            verify_body(reader)
            assert(reader.document:isXPointerInCurrentPage(input.xpointer),'cold reopen lost the selected native position')
            assert(require('weread.lib.mp_record_data').same(reader.annotation.annotations,expected.annotations),
                'cold reopen lost selected notes')
            report.independent_process=true;report.direct_stamped_reopen=true
            reader:onClose(false);finish();return
        end
        local manager=FM.instance
        local host=manager and manager.weread
        if stage=='waiting' then
            if not host or not host._mp_records_menu then return end
            if UI:getTopmostVisibleWidget()~=host._mp_records_menu then return end
            assert(not Reader.instance and created==0 and provider_reads>0)
            preserved();report.raw_candidates_preserved_before_provider=true
            local selected
            for index,row in ipairs(assert(store:list(input.key))) do
                if Crypto.sha256_hex(assert(store:get(input.key,row.id)))==input.chosen_raw_sha256 then
                    host._mp_records_menu.item_table[index].callback();selected=true;break
                end
            end
            assert(selected and host._mp_records_confirmation)
            local dialog=host._mp_records_confirmation
            assert(UI:getTopmostVisibleWidget()==dialog,'startup confirmation is not the visible widget')
            UI:forceRePaint();require('device').screen:shot(evidence..'/startup-choice.png')
            report.record_confirmation_visible=true
            if phase=='cancel' then
                local late=assert(host.mp_records_job).open_file
                dialog.cancel_callback();UI:close(dialog)
                UI:close(assert(host._mp_records_menu))
                late(input.target)
                assert(not host.mp_records_job and not Reader.instance and created==0)
                report.cancel_kept_filemanager=true;report.late_callback_ignored=true;finish();return
            elseif phase=='source-changed' then
                write(input.target,read(input.source_backup)..'changed')
                dialog.ok_callback()
                assert(not host.mp_records_job and not Reader.instance and created==0)
                write(input.target,read(input.source_backup))
                report.changed_source_blocked=true;report.synthetic_source_restored=true;finish();return
            end
            assert(phase=='restore');permitted=true;stage='opening';dialog.ok_callback()
        elseif stage=='opening' then
            local reader=Reader.instance
            if not reader or not reader.weread or not reader.document then return end
            if UI:getTopmostVisibleWidget()~=reader then return end
            local expected=assert(Versions.resolve(input.root,input.key))
            assert(reader.document.file==expected and expected~=input.target and created==1)
            verify_body(reader)
            assert(reader.document:isXPointerInCurrentPage(input.xpointer),'startup recovery lost the selected native position')
            local annotations=reader.annotation.annotations
            local function project(rows)
                local out={};for _i,row in ipairs(rows or {}) do out[#out+1]={page=row.page,pos0=row.pos0,pos1=row.pos1,
                    drawer=row.drawer,text=row.text,note=row.note,datetime=row.datetime} end
                table.sort(out,function(a,b) return tostring(a.drawer or '')<tostring(b.drawer or '') end);return out
            end
            assert(require('weread.lib.mp_record_data').same(project(annotations),input.annotations),'startup recovery changed selected notes')
            UI:forceRePaint();require('device').screen:shot(evidence..'/startup-restored.png')
            write(evidence..'/startup-recovered.json',Json.encode{path=expected,annotations=annotations,content=input.content})
            report.explicit_choice_before_reader=true;report.selected_position_and_notes_restored=true
            report.original_raw_snapshots_retained=true
            reader:onClose(false);finish();return
        end
    end)
    if not ok then
        report.result='FAIL';write(evidence..'/startup-'..phase..'.json',Json.encode(report))
        require('logger').err('Synthetic startup validation failed:',why)
        UI:quit(1);return
    end
    if report.result~='PASS' then UI:scheduleIn(.1,tick) end
end
UI:scheduleIn(.1,tick)
