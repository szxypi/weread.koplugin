-- Real owner book: plugin selection -> uncached Read -> native EPUB -> offline
-- reopening. Private files are confined to the runner's tmpfs profile. The
-- transport allowlist is installed before the plugin loads and is fail-closed.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local trial_mode=arg[1]=='selection-trial'
local reader_trial_mode=arg[1]=='native-reader-trial'
local initial_reader_mode=arg[1]=='native-initial-reader'
local timer_trial_mode=arg[1]=='native-timer-trial'
local close_trial_mode=arg[1]=='native-close-trial'
local native_recovery_mode=arg[1]=='native-source-recovery'
local mode=(trial_mode or reader_trial_mode or timer_trial_mode or close_trial_mode or native_recovery_mode or initial_reader_mode) and 'live' or arg[1]
local report={result='UNVERIFIED',phase='init',mode=mode,anonymous_auth=false,transport_guard_selftest=false,
    plugin_selection=false,native_reader=false,source_text_visible=false,source_receipt_verified=false,page_turn=false,position_checkpoint=false,
    local_source_position_verified=false,source_navigation_roundtrip=false,source_dialog_verified=false,legacy_progress_units_preserved=false,
    credential_file_audit=false,workers_reaped=false,shelf_books=0,pages=0,profile_files_audited=0,
    failed_line=0,screenshots=0,last_http_status=0,denied_kind=0,denied_route=0,denied_flags=0,requests={0,0,0,0,0,0,0}}
local counters,plugin,reader,latest_cookies
local mapping_bytes=4096
local rejected_html
local descriptors={}
local annotation_case
local recovery_private
local progress_case,progress_private
local candidate_case,candidate_private
local selection_case,selection_private
local trial_input
local timer_trial_input
local reader_trial_input
local initial_reader_input
local close_trial_input
local native_recovery_input
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    local combined_home=os.getenv('WEREAD_COMBINED_UPLOAD_READ')=='1'
    assert(ffi.os=='Linux' and (home:match('^/dev/shm/weread%-reading%-[%w_]+/profile$')
        or combined_home and home:match('^/dev/shm/weread%-upload%-ui%-[%w_]+/profile$')))
    local raw
    if trial_mode or reader_trial_mode or timer_trial_mode or close_trial_mode or native_recovery_mode or initial_reader_mode then
        local length=assert(io.stdin:read('*l'));assert(#length<=6 and length:match('^[1-9]%d*$') and tonumber(length)<=256*1024)
        raw=assert(io.stdin:read(tonumber(length)));assert(#raw==tonumber(length))
    else raw=assert(io.stdin:read(256*1024+1)) end
    assert(#raw<=256*1024)
    local input=json.decode(raw)
    assert((input.combined_upload_read==true)==combined_home)
    assert((input.selection_trial~=nil)==trial_mode)
    assert((input.native_initial_reader~=nil)==initial_reader_mode)
    assert((input.native_reader_trial~=nil)==reader_trial_mode)
    assert((input.native_timer_trial~=nil)==timer_trial_mode)
    assert((input.native_close_trial~=nil)==close_trial_mode)
    assert((input.native_recovery~=nil)==native_recovery_mode)
    if native_recovery_mode then
        native_recovery_input=input
        assert(input.native_source_excerpt==true and type(input.native_recovery.rpc_token)=='string'
            and #input.native_recovery.rpc_token==32 and input.native_recovery.rpc_token:match('^[a-f0-9]+$'))
    end
    if close_trial_mode then
        close_trial_input=input
        assert(input.native_source_excerpt==true and type(input.native_close_trial.rpc_token)=='string'
            and #input.native_close_trial.rpc_token==32 and input.native_close_trial.rpc_token:match('^[a-f0-9]+$'))
        assert(type(input.native_close_trial.armed)=='boolean' and input.native_close_trial.armed==(os.getenv('WEREAD_NATIVE_CLOSE_ARMED')=='1'))
    end
    if timer_trial_mode then
        timer_trial_input=input
        assert(input.native_source_excerpt==true and type(input.native_timer_trial.rpc_token)=='string'
            and #input.native_timer_trial.rpc_token==32 and input.native_timer_trial.rpc_token:match('^[a-f0-9]+$'))
        assert(type(input.native_timer_trial.armed)=='boolean' and input.native_timer_trial.armed==(os.getenv('WEREAD_NATIVE_TIMER_ARMED')=='1'))
    end
    if initial_reader_mode then
        initial_reader_input=input
        assert(input.native_source_excerpt==true and type(input.native_initial_reader.rpc_token)=='string'
            and #input.native_initial_reader.rpc_token==32 and input.native_initial_reader.rpc_token:match('^[a-f0-9]+$'))
        assert(type(input.native_initial_reader.armed)=='boolean' and input.native_initial_reader.armed==(os.getenv('WEREAD_NATIVE_INITIAL_READER_ARMED')=='1'))
    end
    if reader_trial_mode then
        reader_trial_input=input
        assert(input.native_source_excerpt==true and type(input.native_reader_trial.rpc_token)=='string'
            and #input.native_reader_trial.rpc_token==32 and input.native_reader_trial.rpc_token:match('^[a-f0-9]+$'))
        assert(type(input.native_reader_trial.armed)=='boolean' and input.native_reader_trial.armed==(os.getenv('WEREAD_NATIVE_READER_ARMED')=='1'))
    end
    if trial_mode then
        trial_input=input
        assert(type(input.selection_trial.rpc_token)=='string' and #input.selection_trial.rpc_token==32
            and input.selection_trial.rpc_token:match('^[a-f0-9]+$'))
        assert(type(input.selection_trial.armed)=='boolean' and input.selection_trial.armed==(os.getenv('WEREAD_SELECTION_ARMED')=='1'))
    end
    assert(type(input.vid)=='string' and input.vid:match('^[1-9]%d*$'))
    local cb_reading=input.cb_reading==true
    local cb_full=input.cb_full_book==true
    local single_page=input.cb_single_page==true
    assert(input.reader_estimate_probe==nil or input.reader_estimate_probe==true and not cb_reading
        and not input.full_manifest and input.source_format=='web_xhtml' and not input.annotations
        and not input.progress_preview and not input.progress_roundtrip and not input.source_upload_preview
        and not input.native_source_excerpt and not input.selection_preview and not input.off_shelf_home)
    if input.reader_estimate_probe then report.reader_estimate_verified=false;report.reader_estimate_stage=0 end
    local synthetic_txt_retry=os.getenv('WEREAD_SYNTHETIC_TXT_RETRY')=='1'
    assert(not synthetic_txt_retry or cb_reading and not cb_full and input.cb_mock_port
        and input.vid=='900000' and input.book_id=='CB_SyntheticResume' and input.source_format=='web_txt')
    assert(input.cb_single_page==nil or single_page and cb_reading and not cb_full)
    assert(not cb_full or cb_reading and type(input.full_manifest)=='table')
    assert(input.diagnostic_read_pacing==nil or input.diagnostic_read_pacing==true and cb_full)
    local diagnostic_pacing=input.diagnostic_read_pacing==true
    local missing_resume=input.missing_resume_probe==true
    local resume_warning=input.resume_warning_probe==true
    local off_shelf_home=input.off_shelf_home==true
    local off_shelf_store=input.off_shelf_store==true
    local off_shelf_cover=input.off_shelf_cover==true
    local off_shelf_marks=input.off_shelf_marks==true
    assert(input.off_shelf_cover==nil or off_shelf_cover and off_shelf_store)
    assert(input.off_shelf_marks==nil or off_shelf_marks and off_shelf_store and type(input.native_marks_expected)=='table')
    if off_shelf_cover then report.store_cover_verified,report.home_cover_verified=false,false end
    if off_shelf_marks then report.marks_snapshot_verified,report.marks_requests,report.marks_count=false,0,0 end
    assert(input.off_shelf_store==nil or off_shelf_store and off_shelf_home)
    if off_shelf_store then
        local grant=assert(input.native_grant)
        assert(type(grant)=='table' and grant.vid==input.vid and type(input.store_search_keyword)=='string'
            and #input.store_search_keyword>0 and #input.store_search_keyword<=512
            and not input.store_search_keyword:find('[%z%c]'))
        for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do assert(type(grant[key])=='string' and #grant[key]>=8) end
        assert(#grant.deviceId==32)
        report.store_search_verified,report.store_metadata_verified=false,false
        report.store_search_requests,report.store_metadata_requests=0,0
    end
    assert(input.off_shelf_home==nil or off_shelf_home and not cb_reading and not input.full_manifest
        and not missing_resume and not input.annotations and not input.progress_preview and not input.progress_roundtrip
        and not input.source_upload_preview and not input.selection_preview)
    if off_shelf_home then
        assert(type(input.off_shelf_row)=='table' and input.off_shelf_row.bookId==input.book_id
            and type(input.off_shelf_row.title)=='string' and #input.off_shelf_row.title>0 and #input.off_shelf_row.title<=1024
            and type(input.off_shelf_row.author)=='string' and #input.off_shelf_row.author<=1024)
        report.home_recent_verified=false
    end
    assert(input.resume_warning_probe==nil or resume_warning and missing_resume)
    if resume_warning and mode=='live' then report.resume_warning_verified=false end
    assert(input.missing_resume_probe==nil or missing_resume and not cb_reading and not input.full_manifest
        and input.source_format=='web_xhtml' and not input.annotations and not input.progress_preview
        and not input.progress_roundtrip and not input.source_upload_preview and not input.selection_preview)
    if missing_resume then report.missing_resume_verified=false end
    if cb_reading then report.source_match_reason='none' end
    if cb_full then report.cb_handoff={full_to_single=false,single_to_full=false,different_files=false,
        same_source=false,position_preserved=false,cloud_unverified=false} end
    assert(type(input.book_id)=='string' and (cb_reading and #input.book_id<=67 and input.book_id:match('^CB_[A-Za-z0-9]+$')
        or not cb_reading and input.book_id:match('^[1-9]%d*$')))
    assert(not cb_reading or not ((input.full_manifest and not cb_full) or input.annotations or input.progress_preview
        or input.progress_roundtrip or input.source_upload_preview or input.native_source_excerpt or input.selection_preview))
    assert(type(input.chapter_uid)=='string' and input.chapter_uid:match('^[1-9]%d*$'))
    assert(type(input.source_text)=='string' and #input.source_text>=32 and #input.source_text<=128)
    assert(input.source_format=='web_xhtml' or input.source_format=='web_txt')
    assert(type(input.source_raw_sha256)=='string' and #input.source_raw_sha256==64 and input.source_raw_sha256:match('^[a-f0-9]+$'))
    assert(type(input.source_sample_offset)=='number' and input.source_sample_offset>=0 and input.source_sample_offset%1==0)
    assert(type(input.cookies)=='table' and input.cookies.wr_vid == input.vid)
    local full=type(input.full_manifest)=='table'
    local chapter_ids,chapter_urls={},{}
    if full then
        report.native_images_decoded=0
        report.download_error,report.download_error_module,report.download_error_line='none','none',0
        report.download_error_chapter,report.reader_context_failure=0,'none'
        report.reader_identity_shape={field='none',kind='none',zero=false,null=false}
        report.reader_python_projection={checked=false,valid=false,reason='none'}
        report.reader_cookie_snapshot={checked=false,same_login=false,same_header=false}
        assert(#input.full_manifest>=2 and #input.full_manifest<=(cb_full and 128 or 32) and input.source_format=='web_xhtml')
        for _i,item in ipairs(input.full_manifest) do
            assert(type(item.chapter_uid)=='string' and item.chapter_uid:match('^[1-9]%d*$') and not chapter_ids[item.chapter_uid])
            chapter_ids[item.chapter_uid]=true
        end
        assert(chapter_ids[input.chapter_uid])
    else chapter_ids[input.chapter_uid]=true end
    latest_cookies=input.cookies
    local source=home..'/plugins/weread.koplugin'
    package.path=source..'/?.lua;'..package.path
    G_defaults=require('luadefaults'):open()
    G_reader_settings=require('luasettings'):open(home..'/settings.reader.lua')
    G_reader_settings:saveSetting('extra_plugin_paths',{home..'/plugins'})
    G_reader_settings:saveSetting('language','zh_CN');require('gettext').changeLang('zh_CN')
    G_reader_settings:saveSetting('color_rendering',false)
    local Device=require('device');require('document/canvascontext'):init(Device)
    Device.screen.shot=function() report.screenshots=report.screenshots+1;error('screenshots disabled',0) end
    local UI=require('ui/uimanager');UI:setRunForeverMode();UI:setInputTimeout(0)
    pcall(ffi.cdef,'int memfd_create(const char *, unsigned int);')
    local auth={auth_schema_version=1,auth_epoch=1,account={user_vid=input.vid,name=''},cookies=input.cookies,api_key=''}
    local fd=tonumber(ffi.C.memfd_create('weread-reading-probe',1));assert(fd>=0)
    descriptors[#descriptors+1]=fd
    local bytes='return '..require('dump')(auth,nil,true);local offset=0
    while offset<#bytes do
        local n=tonumber(ffi.C.write(fd,ffi.cast('const char *',bytes)+offset,#bytes-offset));assert(n>0);offset=offset+n
    end
    local Settings=require('weread.lib.settings');local new_settings=Settings.new
    function Settings:new()
        local value=new_settings(self);assert(not value.mock_endpoint)
        if input.off_shelf_mock_port then
            assert(off_shelf_home and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.off_shelf_mock_port
        elseif input.resume_mock_port then
            assert(missing_resume and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.resume_mock_port
        elseif input.cb_mock_port then
            assert(input.cb_reading==true and input.vid=='900000' and input.book_id=='CB_SyntheticResume'
                and input.cookies.wr_vid=='900000' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.cb_mock_port
        elseif input.selection_mock_port then
            local grant=input.selection_preview and input.selection_preview.credentials
            assert(input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key'
                and grant.accessToken=='mock-native-access' and grant.refreshToken=='mock-native-refresh')
            value.mock_endpoint='http://127.0.0.1:'..input.selection_mock_port
        elseif input.initial_plan_mock_port then
            assert(input.initial_plan_preview==true and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.initial_plan_mock_port
        elseif input.unstarted_mock_port then
            assert(input.unstarted_preview==true and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.unstarted_mock_port
        elseif input.cloud_mock_port then
            assert(input.raw_cloud_preview and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.cloud_mock_port
        elseif input.time_capture_mock_port then
            assert(input.native_time_capture and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key')
            value.mock_endpoint='http://127.0.0.1:'..input.time_capture_mock_port
        elseif input.reader_mock_port then
            local grant=input.native_grant
            assert((reader_trial_mode or timer_trial_mode or close_trial_mode or native_recovery_mode or initial_reader_mode) and input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key'
                and grant.accessToken=='synthetic-native-access' and grant.refreshToken=='synthetic-native-refresh')
            value.mock_endpoint='http://127.0.0.1:'..input.reader_mock_port
        end
        local flush=value.store.flush
        local secrets={'account','cookies','api_key','wr_ticket','wr_wrpa','device_fingerprint'}
        value.store.flush=function(store,...)
            local held={}
            for _i,key in ipairs(secrets) do held[key]=store.data[key];store.data[key]=nil end
            local result={pcall(flush,store,...)}
            for _i,key in ipairs(secrets) do store.data[key]=held[key] end
            if held.cookies then latest_cookies=held.cookies end
            assert(result[1]);return unpack(result,2)
        end
        for key,item in pairs(auth) do value.store:saveSetting(key,key=='cookies' and latest_cookies or item) end
        value.settings_file='/proc/self/fd/'..fd
        local sync=value:get('sync');sync.pull_on_open=false;sync.upload_on_close=false;sync.upload_interval_minutes=0
        value:set('sync',sync)
        local config=value:get('read_report');config.enabled=false;value:set('read_report',config)
        if off_shelf_store then local shelf=value:get('shelf');shelf.source='gateway';value:set('shelf',shelf) end
        if full or off_shelf_store or input.annotations or input.progress_preview or input.progress_roundtrip or input.source_upload_preview or input.native_source_excerpt or input.selection_preview or input.native_time_capture then
            local cache=value:get('cache');cache.download_book_images=full;cache.download_underlines_and_thoughts=false
            if off_shelf_store then cache.show_annotations=off_shelf_marks end
            cache.auto_prefetch_next_chapter=false;value:set('cache',cache)
        end
        value:flush()
        return value
    end
    if off_shelf_store then
        local grant_fd=tonumber(ffi.C.memfd_create('weread-reading-native-grant',1));assert(grant_fd>=0)
        descriptors[#descriptors+1]=grant_fd
        local saved={};for key,value in pairs(input.native_grant) do saved[key]=value end
        saved.epoch,saved.verified_at,saved.book_count=1,os.time(),0
        local grant_bytes='return '..require('dump')({revision=1,authorization=saved},nil,true);local written=0
        while written<#grant_bytes do
            local n=tonumber(ffi.C.write(grant_fd,ffi.cast('const char *',grant_bytes)+written,#grant_bytes-written));assert(n>0);written=written+n
        end
        local Credentials=require('weread.lib.native_credentials');local new_credentials=Credentials.new
        function Credentials:new(settings,...)
            local value=new_credentials(self,settings,...);value.path='/proc/self/fd/'..grant_fd;return value
        end
    end
    report.anonymous_auth=true
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    mapping_bytes=full and 4096+4*1024*1024 or 4096
    local memory=ffi.C.mmap(nil,mapping_bytes,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    if input.native_time_capture then
        assert(mode=='live' and not full and arg[2] and arg[2]:match('/owner_native_time_capture_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_time_capture=candidate_case.report
    elseif input.annotations then
        assert(not full and arg[2])
        annotation_case=dofile(arg[2])(input,mode,counters)
        report.annotations=annotation_case.report
    elseif input.progress_preview then
        assert(not full and arg[2])
        progress_case=dofile(arg[2])(input,counters)
        report.progress_preview=progress_case.report
    elseif input.progress_roundtrip then
        assert(not full and arg[2])
        progress_case=dofile(arg[2])(input,counters)
        report.progress_roundtrip=progress_case.report
    elseif input.source_upload_preview then
        assert(not full and arg[2])
        candidate_case=dofile(arg[2])(input)
        report.source_candidate=candidate_case.report
    elseif input.cb_sync_limit_preview then
        assert(input.cb_sync_limit_preview==true and cb_reading and not full and arg[2] and arg[2]:match('/owner_cb_sync_limit_case%.lua$'))
        candidate_case=dofile(arg[2])(input,mode,counters)
        report.cb_sync_limit=candidate_case.report
    elseif input.initial_plan_preview then
        assert(input.initial_plan_preview==true and input.native_source_excerpt==true and input.source_format=='web_txt'
            and mode=='live' and not full and arg[2] and arg[2]:match('/owner_initial_plan_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.initial_plan=candidate_case.report
    elseif input.unstarted_preview then
        assert(input.unstarted_preview==true and input.native_source_excerpt==true and input.source_format=='web_txt'
            and not full and arg[2] and arg[2]:match('/owner_unstarted_case%.lua$'))
        candidate_case=dofile(arg[2])(input,mode,counters)
        report.unstarted=candidate_case.report
    elseif input.raw_cloud_preview then
        assert(input.native_source_excerpt==true and input.source_format=='web_txt' and not full and arg[2]
            and arg[2]:match('/owner_cloud_source_case%.lua$'))
        candidate_case=dofile(arg[2])(input,mode,counters)
        report.cloud_source=candidate_case.report
    elseif native_recovery_mode then
        assert(input.source_format=='web_txt' and not full and arg[2] and arg[2]:match('/owner_native_recovery_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_recovery=candidate_case.report
    elseif close_trial_mode then
        assert(input.native_source_excerpt==true and input.source_format=='web_txt' and not full and arg[2]
            and arg[2]:match('/owner_native_close_trial_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_close_trial=candidate_case.report
    elseif timer_trial_mode then
        assert(type(arg[2])=='string' and arg[2]:match('/owner_native_timer_trial_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_timer_trial=candidate_case.report
    elseif initial_reader_mode then
        assert(input.native_source_excerpt==true and input.source_format=='web_txt' and not full and arg[2]
            and arg[2]:match('/owner_native_initial_reader_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_initial_reader=candidate_case.report
    elseif reader_trial_mode then
        assert(input.native_source_excerpt==true and input.source_format=='web_txt' and not full and arg[2]
            and arg[2]:match('/owner_native_reader_trial_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_reader_trial=candidate_case.report
    elseif input.native_source_excerpt then
        assert(input.native_source_excerpt==true and input.source_format=='web_txt' and not full
            and arg[2] and arg[2]:match('/owner_native_excerpt_case%.lua$'))
        candidate_case=dofile(arg[2])(input,counters)
        report.native_source_excerpt=candidate_case.report
    elseif input.selection_preview then
        local case_pattern=trial_mode and (input.bookmark_trial and '/owner_bookmark_trial_case%.lua$'
            or input.highlight_trial and '/owner_highlight_trial_case%.lua$' or '/owner_selection_trial_case%.lua$') or '/owner_selection_preview_case%.lua$'
        assert(arg[2] and arg[2]:match(case_pattern))
        selection_case=dofile(arg[2])(input,mode,counters)
        if trial_mode then report.selection_trial=selection_case.report else report.selection_preview=selection_case.report end
    else assert(not arg[2]) end
    local Protocol=require('weread.lib.protocol')
    local Cookie=require('weread.lib.cookie')
    local original_login,original_cookie_header=input.cookies.wr_skey,Cookie.to_header(input.cookies)
    local root_url=Protocol.reader_url(input.book_id)
    local chapter_url=Protocol.reader_url(input.book_id,input.chapter_uid)
    for uid in pairs(chapter_ids) do chapter_urls[Protocol.reader_url(input.book_id,uid)]=uid end
    local content_chapters={}
    for uid in pairs(chapter_ids) do content_chapters[Protocol.e(uid)]=Protocol.reader_url(input.book_id,uid) end
    local progress_urls={}
    for _i,id in ipairs(input.shelf_ids) do progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id]=true end
    if off_shelf_home then progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..input.book_id]=true end
    local URL=require('socket.url')
    local function resource(url)
        if type(url)~='string' or #url>8192 or url:find('[%z%c%s]') then return false end
        local parts=URL.parse(url)
        if not parts or parts.scheme~='https' and parts.scheme~='http' or parts.authority~=parts.host
            or parts.fragment or type(parts.host)~='string' then return false end
        local host=parts.host:lower()
        return host:match('%.qpic%.cn$') or host:match('%.qlogo%.cn$') or host:match('%.gtimg%.com$')
            or parts.scheme=='https' and (host:match('^[%w-]+%.file%.myqcloud%.com$')
                or host:match('^[%w-]+%.image%.myqcloud%.com$'))
            or host:match('%.qq%.com$') and host~='weread.qq.com' and host~='i.weread.qq.com'
    end
    local chapter_count=full and #input.full_manifest or 1
    local limits={2,60,math.max(8,2*chapter_count+4),4,math.max(12,6*chapter_count),full and 512 or 60}
    if selection_case or reader_trial_mode or timer_trial_mode or close_trial_mode or native_recovery_mode or initial_reader_mode or input.raw_cloud_preview then limits={2,60,12,8,18,60} end
    if synthetic_txt_retry then limits={2,60,20,4,32,60} end
    local resource_urls={}
    local protected_resources={}
    local parent_pid=tonumber(ffi.C.getpid())
    local native_search_url=off_shelf_store and ('https://i.weread.qq.com/store/search?'
        ..Protocol.sorted_query{keyword=input.store_search_keyword,scope=10,count=20,maxIdx=0})
    local native_metadata_url=off_shelf_store and ('https://i.weread.qq.com/book/info?bookId='..Protocol.urlencode(input.book_id))
    local native_marks_url=off_shelf_marks and ('https://i.weread.qq.com/book/bookmarklist?bookId='..Protocol.urlencode(input.book_id)..'&synckey=0')
    local function native_read(options)
        if not off_shelf_store or mode~='live' or options.method~='GET' or options.body~=nil
            or options.skip_cookie~=true or options.persist_response_cookies~=false or options.sensitive~=true then return end
        local h=options.headers or {}
        if h.vid~=input.vid or h.accessToken~=input.native_grant.accessToken or h.Cookie or h.cookie or h.Authorization or h.authorization then return end
        if options.url==native_search_url and options.diagnostic_api=='native_discovery_search' then return 23 end
        if options.url==native_metadata_url and options.diagnostic_api=='native_metadata' then return 24 end
        if options.url==native_marks_url and options.diagnostic_api=='native_my_marks' then return 25 end
    end
    local function protected_resource(url)
        if not resource(url) then return false end
        local parts=URL.parse(url)
        return parts.scheme=='https' and parts.authority=='res.weread.qq.com'
    end
    if full then
        assert(type(input.protected_resource_urls)=='table' and #input.protected_resource_urls<=(cb_full and 128 or 32))
        for _i,url in ipairs(input.protected_resource_urls) do
            assert(protected_resource(url));protected_resources[url]=true
        end
    end
    local function public_redirect(url)
        if type(url)~='string' or #url>8192 or url:find('[%z%c%s]') then return false end
        local parts=URL.parse(url)
        if not parts or parts.scheme~='https' and parts.scheme~='http' or parts.authority~=parts.host
            or parts.fragment or type(parts.host)~='string' then return false end
        local host=parts.host:lower()
        local a,b,c,d=host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
        if a then
            a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
            return a<=255 and b<=255 and c<=255 and d<=255 and a~=0 and a~=10 and a~=127 and a<224
                and not (a==100 and b>=64 and b<=127 or a==169 and b==254 or a==172 and b>=16 and b<=31
                    or a==192 and (b==0 or b==168) or a==198 and (b==18 or b==19 or b==51 and c==100)
                    or a==203 and b==0 and c==113)
        end
        return #host<=253 and host:match('^[a-z%d.-]+%.[a-z][a-z]+$') and not host:match('%.local$')
            and not host:match('%.localhost$') and not host:match('%.internal$')
    end
    local function classify(client,options)
        if mode~='live' then return end
        local h=options.headers or {}
        if h.Authorization or h.authorization or h.accessToken or h.vid then return end
        if resource_urls[options.url] then
            if options.method=='GET' and not options.body and options.persist_response_cookies==false then
                if protected_resources[options.url] then
                    local cookies=client.settings:get('cookies',{})
                    if options.skip_cookie==false and cookies.wr_vid == input.vid
                        and (not h.Cookie or h.Cookie==Cookie.to_header(cookies)) then return 6 end
                elseif options.skip_cookie==true and not h.Cookie then return 6 end
            end
            return
        end
        local cookies=client.settings:get('cookies',{})
        if cookies.wr_vid~=input.vid then return end
        if h.Cookie and h.Cookie~=Cookie.to_header(cookies) then return end
        if options.skip_cookie and not h.Cookie then return end
        if options.method=='GET' and not options.body then
            if options.url=='https://weread.qq.com/web/shelf/sync' then return 1 end
            if progress_urls[options.url] then return 2 end
            if options.sensitive == true then
                local id, stamp=options.url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId=([1-9]%d*)&_=(%d+)$')
                if not id then
                    id,stamp=options.url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId=(CB_[A-Za-z0-9]+)&_=(%d+)$')
                end
                if id and #stamp<=16 and math.abs(tonumber(stamp)-os.time()*1000)<=30000 then
                    if (input.progress_roundtrip or input.native_source_excerpt or missing_resume)
                        and id==input.book_id and (missing_resume or id:match('^[1-9]%d*$')) then return 2 end
                    -- Normal shelf rendering may fetch a display-only progress
                    -- value. Admit only a captured shelf member and the exact
                    -- non-persisting read contract; no account write is added.
                    if progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id]
                        and options.diagnostic_api=='shelf_progress' and options.skip_cookie==true
                        and options.persist_response_cookies==false and h.Cookie==Cookie.to_header(cookies)
                        and h.Referer==Protocol.reader_url(id) then return 2 end
                end
            end
            if options.url==root_url or chapter_urls[options.url] then return 3 end
            if (input.source_upload_preview or input.native_source_excerpt or selection_case) and options.url=='https://weread.qq.com/api/userInfo?userVid='..input.vid
                and options.sensitive==true and options.diagnostic_api=='source_currentness'
                and options.skip_cookie==true and options.persist_response_cookies==false
                and h.Cookie==Cookie.to_header(cookies) and h['X-Vid']==input.vid and h['X-Skey']==cookies.wr_skey
                and h.Referer==chapter_url then return 3 end
        elseif options.method=='POST' and type(options.body)=='string' and #options.body<=16384 then
            local decoded,payload=pcall(json.decode,options.body)
            if not decoded or type(payload)~='table' then return end
            if options.url=='https://weread.qq.com/web/book/chapterInfos' then
                local count=0;for _key in pairs(payload) do count=count+1 end
                if payload.bookIds and #payload.bookIds==1 and payload.bookIds[1]==input.book_id
                    and count==1 then return 4 end
            end
            local shard=type(options.url)=='string' and options.url:match('^https://weread%.qq%.com/web/book/chapter/([et]_%d)$')
            if shard and ({e_0=true,e_1=true,e_2=true,e_3=true,t_0=true,t_1=true})[shard] then
                local keys={b=true,c=true,r=true,ct=true,ps=true,pc=true,sc=true,prevChapter=true,st=true,s=true}
                local count=0;for key in pairs(payload) do if not keys[key] then return end;count=count+1 end
                if count==10 and payload.b==Protocol.e(input.book_id) and content_chapters[payload.c]
                    and payload.sc==1 and payload.prevChapter==false and payload.st==(shard=='e_2' and 1 or 0)
                    and h.Referer==content_chapters[payload.c] then return 5 end
            end
        end
    end
    local Client=require('weread.lib.client')
    if input.native_time_capture then
        -- This isolated dwell test needs the book, not background shelf
        -- decoration. Keep the read-only transport allowlist unchanged.
        Client.get_shelf_display_progress=function() error('capture_shelf_progress_disabled',0) end
        assert(not pcall(Client.get_shelf_display_progress,Client,input.book_id))
    end
    local request,binary,download,follow=Client.request,Client.get_binary,Client.download_to_file,Client.request_follow
    local test={settings={get=function() return input.cookies end}}
    local valid={url=root_url,method='GET',headers={}}
    assert((classify(test,valid)~=nil)==(mode=='live'))
    for _i,url in ipairs({'https://weread.qq.com/web/book/read','https://weread.qq.com/web/login/renewal',
        'https://weread.qq.com/web/shelf/add','https://weread.qq.com/logout',root_url..'?unexpected=1'}) do
        assert(not classify(test,{url=url,method='POST',headers={},body='{}'}))
    end
    assert(not classify(test,{url=root_url,method='GET',headers={Cookie='invalid'}}))
    do
        local shelf_id
        for _i,id in ipairs(input.shelf_ids) do
            if (id:match('^[1-9]%d*$') or id:match('^CB_[A-Za-z0-9]+$'))
                and (id~=input.book_id or not (input.progress_roundtrip or input.native_source_excerpt or missing_resume)) then
                shelf_id=id;break
            end
        end
        if shelf_id then
            local check={url='https://weread.qq.com/web/book/getProgress?bookId='..shelf_id..'&_='..tostring(os.time()*1000),
                method='GET',sensitive=true,skip_cookie=true,persist_response_cookies=false,diagnostic_api='shelf_progress',
                headers={Cookie=Cookie.to_header(input.cookies),Referer=Protocol.reader_url(shelf_id)}}
            assert((classify(test,check)==2)==(mode=='live'))
            check.diagnostic_api='other';assert(not classify(test,check));check.diagnostic_api='shelf_progress'
            check.headers.Cookie='invalid';assert(not classify(test,check));check.headers.Cookie=Cookie.to_header(input.cookies)
            check.headers.Referer='https://weread.qq.com/';assert(not classify(test,check));check.headers.Referer=Protocol.reader_url(shelf_id)
            check.url='https://weread.qq.com/web/book/getProgress?bookId='..shelf_id..'&_=1';assert(not classify(test,check))
            local foreign
            for i=1,5001 do
                local id=tostring(i)
                if not progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id] then foreign=id;break end
            end
            assert(foreign)
            check.url='https://weread.qq.com/web/book/getProgress?bookId='..foreign..'&_='..tostring(os.time()*1000)
            check.headers.Referer=Protocol.reader_url(foreign);assert(not classify(test,check))
        end
    end
    if missing_resume then
        local other_id
        for _i,id in ipairs(input.shelf_ids) do if id~=input.book_id then other_id=id;break end end
        assert(other_id)
        local check={url='https://weread.qq.com/web/book/getProgress?bookId='..other_id..'&_='..tostring(os.time()*1000),
            method='GET',sensitive=true,skip_cookie=true,persist_response_cookies=false,diagnostic_api='shelf_progress',
            headers={Cookie=Cookie.to_header(input.cookies),Referer=Protocol.reader_url(other_id)}}
        assert((classify(test,check)==2)==(mode=='live'))
        check.headers.Cookie='invalid';assert(not classify(test,check))
        check.headers.Cookie=Cookie.to_header(input.cookies);check.diagnostic_api='other';assert(not classify(test,check))
        for _i,id in ipairs(input.shelf_ids) do
            if id:match('^CB_[A-Za-z0-9]+$') then
                check.url='https://weread.qq.com/web/book/getProgress?bookId='..id..'&_='..tostring(os.time()*1000)
                check.diagnostic_api='shelf_progress';check.headers.Referer=Protocol.reader_url(id)
                assert((classify(test,check)==2)==(mode=='live'))
                check.url='https://weread.qq.com/web/book/getProgress?bookId=CB_'..string.rep('Z',65)..'&_='..tostring(os.time()*1000)
                assert(not classify(test,check));break
            end
        end
    end
    local params=Protocol.make_content_params(input.book_id,input.chapter_uid,'synthetic-probe-only',{sc=1})
    local content_request={url='https://weread.qq.com/web/book/chapter/e_0',method='POST',
        headers={Referer=chapter_url},body=json.encode(params)}
    assert((classify(test,content_request)~=nil)==(mode=='live'))
    params.c=Protocol.e('999999999999999');content_request.body=json.encode(params)
    assert(not classify(test,content_request))
    assert(not resource('https://127.0.0.1/test') and not resource('https://weread.qq.com/logout'))
    for _i,url in ipairs({'http://127.0.0.1/x','https://10.1.1.1/x','http://192.168.1.1/x',
        'https://user:secret@cdn.qq.com/x','https://cdn.local/x','https://cdn.qq.com/x#fragment'}) do
        assert(not public_redirect(url))
    end
    assert(public_redirect('https://cdn.qq.com/image') and public_redirect('http://101.32.1.1/image'))
    if off_shelf_store then
        local valid_native={url=native_search_url,method='GET',skip_cookie=true,persist_response_cookies=false,sensitive=true,
            diagnostic_api='native_discovery_search',headers={vid=input.vid,accessToken=input.native_grant.accessToken}}
        assert((native_read(valid_native)==23)==(mode=='live'))
        for _i,change in ipairs({'url','method','body','cookie','owner','token','authorization','skip','persist','sensitive'}) do
            local value={};for key,item in pairs(valid_native) do value[key]=item end
            value.headers={vid=input.vid,accessToken=input.native_grant.accessToken}
            if change=='url' then value.url='https://i.weread.qq.com/login' elseif change=='method' then value.method='POST'
            elseif change=='body' then value.body='{}' elseif change=='cookie' then value.headers.Cookie='forbidden'
            elseif change=='owner' then value.headers.vid='0' elseif change=='token' then value.headers.accessToken='invalid'
            elseif change=='authorization' then value.headers.Authorization='forbidden'
            elseif change=='skip' then value.skip_cookie=false elseif change=='persist' then value.persist_response_cookies=true
            else value.sensitive=false end
            assert(not native_read(value))
        end
        valid_native.url,valid_native.diagnostic_api=native_metadata_url,'native_metadata'
        assert((native_read(valid_native)==24)==(mode=='live'))
        valid_native.url='https://i.weread.qq.com/book/info?bookId=99999999999999999999'
        assert(not native_read(valid_native))
        if off_shelf_marks then
            valid_native.url,valid_native.diagnostic_api=native_marks_url,'native_my_marks'
            assert((native_read(valid_native)==25)==(mode=='live'))
            valid_native.url='https://i.weread.qq.com/book/bookmarklist?bookId=99999999999999999999&synckey=0'
            assert(not native_read(valid_native))
        end
    end
    local public_url='https://res.qpic.cn/probe-only'
    resource_urls[public_url]=true
    local public_request={url=public_url,method='GET',skip_cookie=true,persist_response_cookies=false,headers={}}
    assert((classify({settings={get=function() return {} end}},public_request)~=nil)==(mode=='live'))
    public_request.headers.Cookie=Cookie.to_header(input.cookies);assert(not classify(test,public_request))
    resource_urls[public_url]=nil
    for url in pairs(protected_resources) do
        resource_urls[url]=true
        local options={url=url,method='GET',skip_cookie=false,persist_response_cookies=false,headers={}}
        assert((classify(test,options)~=nil)==(mode=='live'))
        options.headers.Cookie='invalid';assert(not classify(test,options))
        options.headers.Cookie=nil;options.skip_cookie=true;assert(not classify(test,options))
        resource_urls[url]=nil
    end
    report.transport_guard_selftest=true
    function Client:request(options)
        local native_slot=native_read(options)
        if native_slot then
            if counters[native_slot]>=(native_slot==25 and 2 or 1) or tonumber(ffi.C.getpid())==parent_pid then
                counters[6]=counters[6]+1;error('native reading scope rejected',0)
            end
            counters[native_slot]=counters[native_slot]+1
            return request(self,options)
        end
        if candidate_case and candidate_case.is_native and candidate_case:is_native(options) then
            return candidate_case:request(self,options,request)
        end
        if selection_case and selection_case:is_native(options) then return selection_case:request(self,options,request) end
        if progress_case and progress_case:is_write(options) then
            if input.progress_roundtrip then return progress_case:request(self,options,request) end
            return progress_case:request(self,options)
        end
        if annotation_case and annotation_case:is_native(options) then
            return annotation_case:request(self,options,request)
        end
        if resource_urls[options.url] and not protected_resources[options.url] then options.skip_cookie=true end
        local kind=classify(self,options)
        if not kind or counters[kind-1]>=limits[kind] then
            if input.off_shelf_mock_port and off_shelf_store and counters[6]==0 then
                local api=options.diagnostic_api
                if type(api)=='string' and #api<=60 and api:match('^native_[a-z_]+$') then
                    ffi.copy(ffi.cast('char *',memory)+512,api,#api);counters[29]=#api
                end
            end
            if input.native_source_excerpt and counters[6]==0 then
                local url,h=options.url or '',options.headers or {}
                local id,stamp=url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId=([1-9]%d*)&_=(%d+)$')
                counters[20]=id and 2 or url:find('&_=',1,true) and 3 or progress_urls[url] and 1 or 4
                counters[21]=(id==input.book_id and 1 or 0)+(options.sensitive==true and 2 or 0)
                    +(id and progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id] and 4 or 0)
                    +(options.skip_cookie==true and 8 or 0)+(options.persist_response_cookies==false and 16 or 0)
                    +(h.Cookie==Cookie.to_header(self.settings:get('cookies',{})) and 32 or 0)
                    +(id and h.Referer==Protocol.reader_url(id) and 64 or 0)
                    +(stamp and #stamp<=16 and math.abs(tonumber(stamp)-os.time()*1000)<=30000 and 128 or 0)
                counters[22]=({shelf_progress=1,position_readback=2,source_currentness=3})[options.diagnostic_api] or 4
            end
            if input.annotations and input.annotations.reply_check and counters[6]==0 then
                local url,h=options.url or '',options.headers or {}
                local id,stamp=url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId=([1-9]%d*)&_=(%d+)$')
                if not id then id,stamp=url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId=(CB_[A-Za-z0-9]+)&_=(%d+)$') end
                counters[27]=(id and 1 or 0)+(id and progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id] and 2 or 0)
                    +(options.diagnostic_api=='shelf_progress' and 4 or 0)+(options.sensitive==true and 8 or 0)
                    +(options.skip_cookie==true and 16 or 0)+(options.persist_response_cookies==false and 32 or 0)
                    +(stamp and #stamp<=16 and math.abs(tonumber(stamp)-os.time()*1000)<=30000 and 64 or 0)
                    +(id and h.Referer==Protocol.reader_url(id) and 128 or 0)
            end
            if counters[6]==0 then
                local url,h=options.url or '',options.headers or {}
                counters[9]=url:find('/web/book/getProgress',1,true) and 1
                    or url:find('/web/book/read',1,true) and 2 or url:find('/web/login/',1,true) and 3
                    or url:find('/web/shelf/',1,true) and 4 or url:find('/web/book/chapter',1,true) and 5
                    or url:find('/web/reader/',1,true) and 6 or resource(url) and 7
                    or url:find('/api/agent/gateway',1,true) and 8 or url:find('/web/book/',1,true) and 9 or 10
                counters[10]=(options.method=='GET' and 1 or 0)+(options.method=='POST' and 2 or 0)
                    +(options.skip_cookie and 4 or 0)+(h.Cookie and 8 or 0)
                    +(h.Cookie==Cookie.to_header(self.settings:get('cookies',{})) and 16 or 0)
                    +(h.Authorization and 32 or 0)+(h.accessToken and 64 or 0)+(options.body and 128 or 0)
                    +(self.settings:get('cookies',{}).wr_vid == input.vid and 256 or 0)
            end
            counters[6]=counters[6]+1;counters[8]=kind or 7;error('reading scope rejected',0)
        end
        counters[kind-1]=counters[kind-1]+1
        -- Controlled diagnostic only. The host labels this separately from
        -- normal production acceptance; no response or receipt is fabricated.
        if diagnostic_pacing and (kind==3 or kind==5) then
            require('socket').sleep(1)
            counters[19]=counters[19]+1
        end
        local response,code,headers,status=request(self,options)
        counters[7]=tonumber(code) or 0
        if full and kind==3 and code==200 and not options.sink then
            local context_valid,problem=pcall(require('weread.lib.reader_context').project,{book_id=input.book_id},response,
                function(encoded) return self:json_decode(encoded) end)
            if not context_valid and counters[11]==0 then
                counters[11]=({['reader_context/invalid_identity']=1,['reader_context/invalid_response']=2,
                    ['reader_context/book_mismatch']=3,['reader_context/invalid_session']=4})[problem] or 5
                if type(response)=='string' and #response<=4*1024*1024 then
                    ffi.copy(ffi.cast('char *',memory)+4096,response,#response)
                    counters[16]=#response
                    local jar=self.settings:get('cookies',{})
                    local effective=(options.headers or {}).Cookie or (options.headers or {}).cookie or Cookie.to_header(jar)
                    counters[17]=jar.wr_skey == original_login and 1 or 2
                    counters[18]=effective==original_cookie_header and 1 or 2
                end
                if problem=='reader_context/invalid_identity' then
                    local encoded=response:match('window%.__INITIAL_STATE__%s*=%s*(%{.-%})%s*;%s*%(function')
                    local parsed,initial=pcall(json.decode,encoded or '')
                    local state=parsed and type(initial)=='table' and initial.reader
                    if type(state)=='table' then
                        local chapter=type(state.currentChapter)=='table' and state.currentChapter or {}
                        local progress=type(state.progress)=='table' and state.progress or {}
                        if type(progress.book)=='table' then progress=progress.book end
                        local rows={type(state.bookInfo)=='table' and state.bookInfo or {},chapter,progress}
                        for index,row in ipairs(rows) do
                            local value=row.bookId
                            if (index==1 or value~=nil and value~=json.util.null)
                                and not pcall(require('weread.lib.reader_context').identifier,value) then
                                counters[12]=index
                                counters[13]=({['nil']=1,['function']=2,number=3,string=4,boolean=5})[type(value)] or 6
                                counters[14]=(value==0 or value=='0') and 1 or 0
                                counters[15]=value==json.util.null and 1 or 0
                                break
                            end
                        end
                    end
                end
            end
        end
        return response,code,headers,status
    end
    local function resource_options(url,options)
        assert(resource(url),'resource scope rejected')
        resource_urls[url]=true
        options=options or {};options.skip_cookie=not protected_resources[url];options.persist_response_cookies=false;options.sensitive=true
        return options
    end
    function Client:get_binary(url,options)
        return binary(self,url,resource_options(url,options))
    end
    function Client:download_to_file(url,path,options)
        return download(self,url,path,resource_options(url,options))
    end
    function Client:request_follow(options,...)
        -- download_to_file installs its own reset callback. Compose the guard
        -- here so streamed image/archive redirects keep that production reset.
        if resource_urls[options.url] then
            local redirected=options.on_redirect
            options.on_redirect=function(previous,next_url,...)
                assert(resource_urls[previous] and public_redirect(next_url),'resource redirect rejected')
                resource_urls[next_url]=true
                if protected_resources[previous] and protected_resource(next_url) then protected_resources[next_url]=true end
                if redirected then redirected(previous,next_url,...) end
            end
        end
        return follow(self,options,...)
    end
    local Common=require('weread.ui.common')
    local forced_offline=false
    Common.isNetworkOnline,Common.isNetworkConnected=function() return mode=='live' and not forced_offline end,function() return mode=='live' and not forced_offline end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' or input.native_time_capture and entry.name=='statistics' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==(input.native_time_capture and 2 or 1))
    package.path=source..'/?.lua;'..package.path
    local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
    local socket=require('socket')
    local download_finished
    local download_failed=false
    local synthetic_failure=false
    if synthetic_txt_retry and mode=='live' then
        local Downloader=require('weread.lib.downloader')
        local completed=Downloader._notifyCompletion
        function Downloader:_notifyCompletion(dl,success,...)
            if dl.suffix=='chapter' and not success then synthetic_failure=true end
            return completed(self,dl,success,...)
        end
    end
    if full then
        local Downloader=require('weread.lib.downloader')
        local completed=Downloader._notifyCompletion
        function Downloader:_notifyCompletion(dl,success,...)
            if dl.suffix=='full' then download_finished=success end
            return completed(self,dl,success,...)
        end
        local failed=Downloader._failChapter
        function Downloader:_failChapter(dl,err)
            if dl.suffix=='full' and not download_failed then
                download_failed=true
                report.download_error_chapter=dl.index
                local text=tostring(err)
                report.download_error=text:find('resource scope rejected',1,true) and 'resource_scope'
                    or text:find('reading scope rejected',1,true) and 'request_scope'
                    or text:find('returned empty object',1,true) and 'empty_content' or 'other'
                local file,line=text:match('([%w_]+)%.lua:(%d+):')
                report.download_error_module=({content=true,client=true,reader_context=true,position_source=true,downloader=true,
                    owner_reading_probe=true})[file] and file or 'other'
                report.download_error_line=tonumber(line) or 0
            end
            return failed(self,dl,err)
        end
    end
    local status_at=0
    local function tick()
        UI:setInputTimeout(0);UI:handleInput()
        if full then
            local dialog=UI:getTopmostVisibleWidget()
            local tr=require('weread.lib.plugin_util').tr
            if dialog and dialog.ok_callback and (dialog.ok_text==tr('Download') or dialog.ok_text==tr('Read now')) then
                UI:close(dialog);dialog.ok_callback()
            end
            if socket.gettime()-status_at>=2 then
                status_at=socket.gettime()
                local dl=plugin and plugin.downloader._active_job
                local snapshot={phase=report.phase,download_index=dl and dl.index or 0,download_total=dl and dl.total or 0,
                    active_download=dl~=nil,busy=plugin and plugin.busy_message~=nil or false,
                    reader_open=Reader.instance and Reader.instance.document~=nil or false,
                    confirmation=dialog and dialog.ok_callback~=nil or false,last_http_status=tonumber(counters[7]),
                    context_failure=tonumber(counters[11]),requests={}}
                for _i=1,7 do snapshot.requests[_i]=tonumber(counters[_i-1]) end
                local file=assert(io.open(home..'/probe-status.json','wb'));file:write(json.encode(snapshot));file:close()
            end
        end
    end
    local function pump(predicate)
        local deadline=socket.gettime()+(full and report.phase=='prepare' and 480
            or input.off_shelf_mock_port and off_shelf_cover and 15 or 70)
        while not predicate() do
            assert(download_finished~=false,'full download did not complete')
            assert(not download_failed,'full chapter failed')
            assert(not (full and report.phase=='prepare' and counters[11]>0 and plugin
                and not plugin.downloader._active_job),'full catalog context rejected')
            assert(socket.gettime()<deadline);tick();socket.sleep(.01)
        end
    end
    if progress_case and input.progress_roundtrip then progress_case:install_guard() end
    FM:showFiles(home);plugin=assert(FM.instance.weread)
    local host=plugin
    if off_shelf_cover then
        local fetch=plugin.fetchVisibleShelfCovers
        plugin.fetchVisibleShelfCovers=function(self,view,items,options)
            local only_target={}
            for index,row in ipairs(items) do
                only_target[index]=tostring(row.bookId or row.book_id)==input.book_id and row or {}
            end
            return fetch(self,view,only_target,options)
        end
    end
    report.phase='shelf'
    if mode=='live' and not combined_home then
        local loaded=false
        plugin:refreshBookshelf(nil,{on_loaded=function(success) loaded=success end})
        pump(function() return not plugin.shelf_refreshing end)
        assert(loaded and plugin.shelf_active_source=='web')
    end
    local books=assert(plugin.library_db:getShelf());assert(#books==input.shelf_books)
    report.shelf_books=#books
    local target
    for _i,book in ipairs(books) do if tostring(book.bookId)==input.book_id then target=book end end
    local function target_with_cover()
        local view=plugin.shelf_view
        if not view then return end
        for index,row in ipairs(view:getVisibleBooks()) do
            if tostring(row.bookId or row.book_id)==input.book_id then
                local path=plugin:getShelfCoverCache():pathFor(row)
                if path and view.cover_paths and view.cover_paths[row]==path and view._item_rows
                    and view._item_rows[index] and view._item_rows[index]._has_cover then return row,path end
            end
        end
    end
    local function select_recent_home()
        plugin:closeWeReadUI();plugin:showHome()
        if off_shelf_cover then
            pump(function() return target_with_cover()~=nil end);UI:forceRePaint();report.home_cover_verified=true
        end
        local view=assert(plugin.shelf_view);local selected
        for _i,row in ipairs(view.books) do
            if tostring(row.bookId or row.book_id)==input.book_id then assert(not selected);selected=row end
        end
        assert(selected and selected._cached,'off-shelf recent book missing from home')
        assert(#assert(plugin.library_db:getShelf())==input.shelf_books,'home changed the shelf snapshot')
        view.on_select(selected,'books');return selected
    end
    local function verify_personal(reader_ui)
        if not off_shelf_marks then return end
        pump(function() local state=reader_ui.weread._personal_marks
            return state and state.loaded and state.snapshot and state.complete end)
        local state=reader_ui.weread._personal_marks
        local value={};for key,item in pairs(state.snapshot) do value[key]=item end;value.fetched_at=1
        local function same(a,b)
            if type(a)~=type(b) then return false end
            if type(a)~='table' then return a==b end
            for key,item in pairs(a) do if not same(item,b[key]) then return false end end
            for key in pairs(b) do if a[key]==nil then return false end end
            return true
        end
        assert(same(value,input.native_marks_expected),'personal mark snapshot mismatch')
        if input.off_shelf_mock_port and #input.native_marks_expected.updated>0 then
            assert(#state.records>0 and state.overlay.enabled,'synthetic personal mark was not mapped')
        end
        UI:forceRePaint();report.marks_snapshot_verified=true;report.marks_count=#value.updated
    end
    if off_shelf_home then
        assert(not target,'off-shelf target unexpectedly in cloud shelf')
        for _i,id in ipairs(input.shelf_ids) do assert(id~=input.book_id) end
        if mode=='reopen' then select_recent_home();report.home_recent_verified=true
        elseif off_shelf_store then
            -- Search and details use the production native source. Cover
            -- downloads are limited to this selected book in cover mode.
            if not off_shelf_cover then plugin.fetchVisibleShelfCovers=function() end end
            plugin:showBookstore()
            local search
            for _i,button in ipairs(plugin.shelf_view._action_buttons or {}) do
                if button.text==require('weread.lib.plugin_util').tr('Search WeRead') then search=button end
            end
            assert(search);search.callback()
            pump(function() local top=UI:getTopmostVisibleWidget();return top and top.setInputText~=nil end)
            local dialog=UI:getTopmostVisibleWidget();dialog:setInputText(input.store_search_keyword);dialog.buttons[1][2].callback()
            pump(function() return not plugin.discovery_loading and plugin.discovery_state
                and plugin.discovery_state.kind=='search' and plugin.discovery_state.cursor==0 end)
            assert(plugin.discovery_state.source_kind=='native' and counters[23]==1)
            local view=assert(plugin.shelf_view);local index
            for position,row in ipairs(view.books) do if tostring(row.bookId)==input.book_id then index=position end end
            assert(index and view.paged)
            local page=math.floor((index-1)/view.page_size)+1
            if page~=view.page then view.on_page_changed(page);view=assert(plugin.shelf_view) end
            if off_shelf_cover then
                pump(function() return target_with_cover()~=nil end)
                view=assert(plugin.shelf_view)
                local _,path=target_with_cover()
                local image=assert(require('ui/renderimage'):renderImageFile(path,false,nil,nil))
                assert(image:getWidth()>0 and image:getWidth()<=300 and image:getHeight()>0 and image:getHeight()<=450)
                image:free();UI:forceRePaint();report.store_cover_verified=true
            end
            local visible
            for _i,row in ipairs(view:getVisibleBooks()) do if tostring(row.bookId)==input.book_id then visible=row end end
            assert(visible);UI:forceRePaint();view.on_select(visible,'books');report.store_search_verified=true
        else plugin:showBookRecord(input.off_shelf_row,{verified_metadata=true}) end
        report.plugin_selection=true
    else
        assert(target)
        plugin:showHome()
        -- The source sample need not be in the six most recent Home rows; use the
        -- normal shelf selection callback with the actual file-backed shelf row.
        plugin:closeWeReadUI();plugin:showBookshelf()
        local view=assert(plugin.shelf_view);assert(type(view.on_select)=='function')
        local index
        for position,book in ipairs(view.books) do if tostring(book.bookId)==input.book_id then index=position end end
        assert(index and view.paged)
        local page=math.floor((index-1)/view.page_size)+1
        if page~=view.page then plugin:showShelfView('books',nil,nil,{page=page});view=assert(plugin.shelf_view) end
        local visible
        for _i,book in ipairs(view:getVisibleBooks()) do if tostring(book.bookId)==input.book_id then visible=book end end
        assert(visible);UI:forceRePaint();target=visible
        view.on_select(target,'books');report.plugin_selection=true
    end
    report.phase='detail'
    local fallback_uid=input.chapter_uid=='99999999999999999999' and '99999999999999999998' or '99999999999999999999'
    local fallback_path=home..'/synthetic-resume-fallback.epub'
    local fallback_marker='Synthetic fallback; never a real book.\n'
    local detail,read_button
    local tr=require('weread.lib.plugin_util').tr
    if not (off_shelf_home and mode=='reopen') then
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    if off_shelf_store then
        local selected=assert(plugin.settings:get_book(input.book_id))
        assert(selected.detail_source=='native' and counters[24]==1,'native book detail was not verified')
        report.store_metadata_verified=true
    end
    detail=assert(plugin._book_detail_view)
    if missing_resume and mode=='live' then
        local file=assert(io.open(fallback_path,'wb'));assert(file:write(fallback_marker));assert(file:close())
        local saved=plugin.settings:get('books',{});local selected=assert(saved[input.book_id])
        assert(not selected.cached_full_book and (not selected.cached_chapters or not next(selected.cached_chapters)))
        selected.cached_chapters={[fallback_uid]=fallback_path}
        selected.pending_upload_position={book_id=input.book_id,chapter_uid=input.chapter_uid}
        selected.pending_upload_account=assert(plugin.library_db:accountKey())
        saved[input.book_id]=selected;plugin.settings:set('books',saved);plugin.settings:flush()
        local checked=assert(plugin.settings:get_book(input.book_id))
        assert(checked.cached_chapters[fallback_uid]==fallback_path and not checked.cached_chapters[input.chapter_uid]
            and checked.pending_upload_position.chapter_uid==input.chapter_uid)
    end
    local label=require('weread.lib.plugin_util').tr(full and mode=='live' and '⇩ Download full book' or '▤ Read')
    local pressed=false
    for _i,buttons in ipairs({detail._action_buttons or {},detail._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do
            if button.text==label then
                assert(button.enabled~=false)
                if resume_warning and mode=='live' then
                    forced_offline=true;button.callback()
                    local warning=assert(plugin._missing_resume_confirmation)
                    assert(UI:getTopmostVisibleWidget()==warning.dialog and warning.dialog.ok_text==tr('Read cached copy'))
                    warning.dialog.cancel_callback();assert(not plugin._missing_resume_confirmation and not Reader.instance)
                    local unchanged=assert(plugin.settings:get_book(input.book_id))
                    assert(unchanged.pending_upload_position.book_id==input.book_id
                        and unchanged.pending_upload_position.chapter_uid==input.chapter_uid
                        and unchanged.cached_chapters[fallback_uid]==fallback_path)
                    forced_offline=false;report.resume_warning_verified=true
                end
                read_button=button;button.callback();pressed=true;break
            end
        end
        if pressed then break end
    end
    assert(pressed)
    end
    if mode=='live' then assert((full or plugin.book_reading_context) and not Reader.instance) end
    report.phase='prepare'
    if synthetic_txt_retry and mode=='live' then
        pump(function() return synthetic_failure or Reader.instance~=nil end)
        assert(synthetic_failure and not Reader.instance,'failed TXT shard opened a partial book')
        pump(function() return not plugin.book_reading_context and not plugin.downloader._active_job end)
        local book=plugin.settings:get_book(input.book_id) or {}
        assert(not book.cached_file and not (book.cached_chapters and book.cached_chapters[input.chapter_uid]),
            'failed TXT shard replaced the reading cache')
        local message=assert(UI:getTopmostVisibleWidget())
        assert(message.text==tr('No chapters were downloaded.'),'TXT failure did not show the expected message')
        UI:close(message)
        assert(plugin._book_detail_view==detail and read_button and read_button.enabled~=false)
        read_button.callback()
    end
    pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document end)
    reader=Reader.instance;plugin=reader.weread
    report.phase='native'
    local document=reader.document
    assert(document.file:sub(1,#home)==home and document.file:match('%.epub$'))
    assert(plugin:detectWeReadBook()==input.book_id)
    verify_personal(reader)
    local book=assert(plugin.settings:get_book(input.book_id))
    if full then assert(book.cached_full_book==document.file)
    else assert(book.cached_chapters and book.cached_chapters[input.chapter_uid]==document.file) end
    if missing_resume then
        local fallback=assert(io.open(fallback_path,'rb'));local marker=fallback:read('*a');fallback:close()
        assert(marker==fallback_marker and book.cached_chapters[fallback_uid]==fallback_path and document.file~=fallback_path)
        report.missing_resume_verified=true
    end
    local source_receipt=assert(require('weread.lib.position_source').read_document(document,input.book_id,input.chapter_uid))
    assert(source_receipt.format==input.source_format and source_receipt.raw_sha256==input.source_raw_sha256)
    report.source_receipt_verified=true
    if full then
        local RenderImage=require('ui/renderimage')
        local function decode_image(raw_image)
            assert(type(raw_image)=='string' and #raw_image>0 and #raw_image<=64*1024*1024)
            local bitmap=assert(RenderImage:renderImageData(raw_image,#raw_image,false,160,160))
            assert(bitmap:getWidth()>0 and bitmap:getHeight()>0);bitmap:free()
            report.native_images_decoded=report.native_images_decoded+1
        end
        local opf=assert(document:getDocumentFileContent('OEBPS/content.opf'))
        for item in opf:gmatch('<item%s[^>]+>') do
            local media=item:match('media%-type="([^"]+)"')
            local href=item:match('href="([^"]+)"')
            if media and media:match('^image/') then
                assert(href and href:match('^images/[^/]+$'))
                decode_image(document:getDocumentFileContent('OEBPS/'..href))
            end
        end
        for _i,item in ipairs(input.full_manifest) do
            local source_record=assert(require('weread.lib.position_source').document_metadata(document,input.book_id,item.chapter_uid))
            local body=assert(document:getDocumentFileContent(source_record.record.render_path))
            for data in body:gmatch('src=["\'](data:image/[^"\']+)["\']') do
                decode_image(require('mime').unb64(assert(data:match('^data:image/[^;]+;base64,(.+)$'))))
            end
        end
    end
    report.pages=document:getPageCount();assert(single_page and report.pages==1 or not single_page and report.pages>1)
    local matches=assert(document:findAllText(input.source_text,false,0,4,false,0))
    assert(matches[1] and matches[1].start)
    local source_index,source_reason=require('weread.lib.source_dom').open(document,input.book_id,input.chapter_uid)
    assert(source_index,source_reason)
    local source_match,match_reason=source_index:capture(matches[1].start)
    if not source_match and cb_reading then
        local reason_name=type(match_reason)=='string' and match_reason:match('^source_dom/([a-z_]+)$')
        report.source_match_reason=({walk_diverged=true,anchor_ambiguous=true,anchor_missing=true,source_point_unavailable=true,
            invalid_point=true,source_unsupported=true,source_unavailable=true,cancelled=true})[reason_name] and reason_name or 'other'
        local Dom=require('weread.lib.source_dom')
        local begin=source_index.flat:find(assert(Dom.normalize(input.source_text)),1,true)
        local prefix=Dom.normalize(document:getTextFromXPointers(source_index.root..'.0',matches[1].start))
        local anchor=source_index.map:anchor(input.source_sample_offset)
        if begin and prefix and begin~=#prefix+1 then report.source_match_reason='sample_start_mismatch'
        elseif not anchor then report.source_match_reason='source_anchor_unavailable'
        elseif not source_index.flat:find(anchor.text,1,true) then report.source_match_reason='source_anchor_missing' end
    end
    assert(source_match,match_reason)
    assert(source_match.co==input.source_sample_offset)
    report.native_reader=true
    local checkpoint_path=home..'/checkpoint.json'
    if mode=='reopen' then
        local file=assert(io.open(checkpoint_path,'rb'));local checkpoint=json.decode(file:read('*a'));file:close()
        assert(checkpoint.file==document.file and document:isXPointerInCurrentPage(checkpoint.xpointer))
        assert(reader:getCurrentPage()==checkpoint.page)
    end
    if candidate_case and candidate_case.reader_ready then candidate_case:reader_ready(plugin,reader,pump,source_index) end
    local origin=document:getXPointer()
    reader.rolling:onGotoXPointer(matches[1].start);tick()
    assert(document:isXPointerInCurrentPage(matches[1].start))
    local y,x=document:getScreenPositionFromXPointer(matches[1].start)
    assert(y>=0 and y<Device.screen:getHeight() and x>=0 and x<Device.screen:getWidth())
    UI:forceRePaint();report.source_text_visible=true
    reader.rolling:onGotoXPointer(origin);tick()
    if not single_page then
        local next_page=reader:getCurrentPage()==1 and 2 or 1
        reader.rolling:onGotoPage(next_page);tick()
        assert(reader:getCurrentPage()==next_page)
        report.page_turn=true
    end
    UI:forceRePaint()
    -- Read an ordinary body page through the production cooperative service,
    -- independent archive worker, position dialog and bound native navigator.
    if full then reader.rolling:onGotoXPointer(matches[1].start)
    else reader.rolling:onGotoPage(math.min(3,report.pages)) end
    tick()
    local service=assert(plugin.source_position)
    pump(function() return service:current()~=nil end)
    local position=assert(service:current())
    local basis=require('weread.lib.position_source').coordinate_basis(input.source_format)
    assert(position.basis==basis and position.upload_verified==false and position.raw_sha256==input.source_raw_sha256)
    local location=assert(require('weread.lib.source_context').location(document,reader.view.view_mode))
    local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
    local native_point=dofile(fixtures..'owner_viewport_point.lua')(document,location,Device.screen:getHeight())
    local current,current_reason=source_index:capture(native_point)
    if not current and cb_reading then
        local reason_name=type(current_reason)=='string' and current_reason:match('^source_dom/([a-z_]+)$')
        report.source_match_reason=({walk_diverged=true,anchor_ambiguous=true,anchor_missing=true,source_point_unavailable=true,
            invalid_point=true,source_unsupported=true,source_unavailable=true,cancelled=true})[reason_name] and reason_name or 'other'
    end
    assert(current,current_reason);assert(current.co==position.chapter_offset)
    report.local_source_position_verified=true
    plugin:showReadingPosition()
    pump(function() return plugin._source_position_message~=nil end)
    assert(plugin._source_position_message.text:find('已定位到当前页正文',1,true)
        and plugin._source_position_message.text:find('精确云端同步仍在验证中',1,true))
    UI:forceRePaint();plugin:closeReadingPositionMessage();report.source_dialog_verified=true
    if input.reader_estimate_probe then
        report.reader_estimate_verified=dofile(fixtures..'owner_reader_estimate_case.lua')(input,plugin,reader,pump,report)
    end
    if annotation_case then
        annotation_case:run(plugin,reader,pump,tick)
        -- Restore the exact validated source target after the overlay tour.
        local restored
        assert(plugin:openSourcePosition(position,function(value) restored=value or false end))
        pump(function() return restored~=nil end);assert(restored)
        annotation_case.report.position_restored=true
    end
    local legacy=assert(plugin.progress_sync:capture_local())
    local applied
    assert(plugin:openSourcePosition(position,function(result) applied=result or false end))
    pump(function() return applied~=nil end)
    assert(applied and applied.basis==basis and applied.chapter_offset==position.chapter_offset)
    local retained=assert(plugin.progress_sync:current_source_target())
    assert(retained.basis==basis and retained.chapter_offset==position.chapter_offset and retained.upload_verified==false)
    local applied_anchor=assert(plugin.progress_sync.source_anchor)
    assert(applied_anchor.document==document and document:isXPointerInCurrentPage(applied_anchor.xpointer))
    local roundtrip=assert(source_index:capture(applied_anchor.xpointer))
    assert(roundtrip.co==position.chapter_offset)
    report.source_navigation_roundtrip=true
    local after=assert(plugin.progress_sync:capture_local())
    assert(after.chapter_offset==legacy.chapter_offset and after.source_position.basis==basis
        and after.source_position.chapter_offset==position.chapter_offset and (full or after.chapter_offset~=position.chapter_offset))
    report.legacy_progress_units_preserved=true
    if progress_case then progress_case:run(plugin,reader,pump,source_index,position) end
    if candidate_case then candidate_case:run(plugin,reader,pump,source_index,position) end
    if selection_case then selection_case:run(plugin,reader,pump,source_index,position) end
    if cb_full then
        plugin,reader=dofile(fixtures..'cb_full_handoff_case.lua')(input,report.cb_handoff,plugin,reader,pump,tick,position)
        document=reader.document
    end
    if close_trial_mode then
        assert(candidate_case.closed==true and candidate_case.report.document_closed
            and candidate_case.report.no_closed_document_calls)
    else
        local checkpoint={file=document.file,xpointer=document:getXPointer(),page=reader:getCurrentPage()}
        local file=assert(io.open(checkpoint_path,'wb'));assert(file:write(json.encode(checkpoint)));file:close()
    end
    report.phase='close'
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    plugin:closeWeReadUI();plugin:onFlushSettings();if not close_trial_mode then reader:onClose(false) end;reader=nil
    plugin.settings:flush();G_reader_settings:flush();report.position_checkpoint=true
    if off_shelf_home and mode=='live' then
        local file=assert(io.open(checkpoint_path,'rb'));local checkpoint=json.decode(file:read('*a'));file:close()
        plugin=host;select_recent_home()
        pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document
            and Reader.instance.document.file==checkpoint.file
            and Reader.instance.document:isXPointerInCurrentPage(checkpoint.xpointer) end)
        reader=Reader.instance;plugin=reader.weread
        verify_personal(reader)
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        plugin:closeWeReadUI();plugin:onFlushSettings();reader:onClose(false);reader=nil;plugin.settings:flush()
        report.home_recent_verified=true
    end
    pump(function() return not plugin.shelf_cover_job and not plugin.shelf_cover_pending
        and not plugin.book_reading_context and not plugin.downloader._active_job
        and not host.shelf_cover_job and not host.shelf_cover_pending
        and not host.book_reading_context and not host.downloader._active_job end)
    local status=ffi.new('int[1]')
    pump(function()
        local child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG))
        -- Reap all completed direct workers; zero still means a live child.
        while child>0 do child=tonumber(ffi.C.waitpid(-1,status,ffi.C.WNOHANG)) end
        -- Linux ECHILD is 10 (posix_h exposes waitpid but no errno constants).
        return child<0 and ffi.errno()==10
    end)
    report.workers_reaped=true
    report.phase='audit'
    local lfs=require('libs/libkoreader-lfs')
    local secrets={}
    if off_shelf_store then
        for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do secrets[#secrets+1]=input.native_grant[key] end
    end
    if annotation_case then
        for _i,value in ipairs(annotation_case:secrets()) do secrets[#secrets+1]=value end
    end
    if selection_case then for _i,value in ipairs(selection_case:secrets()) do secrets[#secrets+1]=value end end
    if candidate_case and candidate_case.secrets then for _i,value in ipairs(candidate_case:secrets()) do secrets[#secrets+1]=value end end
    for key,value in pairs(latest_cookies) do if key~='wr_vid' and #value>=8 then secrets[#secrets+1]=value end end
    for key,value in pairs(input.cookies) do if key~='wr_vid' and #value>=8 then secrets[#secrets+1]=value end end
    local function audit(path)
        for entry in lfs.dir(path) do
            if entry~='.' and entry~='..' and not (path==home and entry=='plugins') then
                local filename=path..'/'..entry;local info=assert(lfs.symlinkattributes(filename))
                if info.mode=='directory' then audit(filename)
                elseif info.mode=='file' then
                    report.profile_files_audited=report.profile_files_audited+1
                    assert(report.profile_files_audited<=1024 and info.size<=(full and 64 or 16)*1024*1024)
                    local handle=assert(io.open(filename,'rb'));local content=handle:read('*a');handle:close()
                    local permitted=candidate_case and candidate_case.allows_secret_file and candidate_case:allows_secret_file(filename,content)
                    for _i,secret in ipairs(secrets) do
                        if not (type(permitted)=='table' and permitted[secret]==true) then assert(not content:find(secret,1,true)) end
                    end
                    if candidate_case then candidate_case:audit(filename,content) end
                else error('unexpected profile entry',0) end
            end
        end
    end
    audit(home);report.credential_file_audit=true
    assert(counters[6]==0)
    if diagnostic_pacing and mode=='live' then
        assert(counters[19]==counters[2]+counters[4] and counters[19]>=#input.full_manifest*4)
    else assert(counters[19]==0) end
    report.phase,report.result='complete','PASS'
end)
if counters then
    if progress_case then progress_case:finish(reason);progress_private=progress_case:private() end
    if candidate_case then candidate_case:finish(reason);candidate_private=candidate_case:private() end
    if selection_case then selection_case:finish(reason);selection_private=selection_case:private() end
    if annotation_case then
        annotation_case:finish(reason)
        if annotation_case.private then recovery_private=annotation_case:private() end
    end
    for index=1,7 do report.requests[index]=tonumber(counters[index-1]) end
    if report.store_search_requests~=nil then
        report.store_search_requests,report.store_metadata_requests=tonumber(counters[23]),tonumber(counters[24])
    end
    if report.marks_requests~=nil then report.marks_requests=tonumber(counters[25]) end
    if report.store_search_requests~=nil and counters[29]>0 then
        report.synthetic_denied_api=ffi.string(ffi.cast('char *',counters)+512,tonumber(counters[29]))
    end
    report.last_http_status,report.denied_kind=tonumber(counters[7]),tonumber(counters[8])
    report.denied_route,report.denied_flags=tonumber(counters[9]),tonumber(counters[10])
    if report.reader_context_failure then
        report.reader_context_failure=({'none','invalid_identity','invalid_response','book_mismatch','invalid_session','other'})[tonumber(counters[11])+1]
        report.reader_identity_shape={field=({'none','book','chapter','progress'})[tonumber(counters[12])+1],
            kind=({'none','nil','function','number','string','boolean','other'})[tonumber(counters[13])+1],
            zero=counters[14]==1,null=counters[15]==1}
        if counters[16]>0 then
            rejected_html=require('mime').b64(ffi.string(ffi.cast('char *',counters)+4096,tonumber(counters[16]))):gsub('%s+','')
            report.reader_cookie_snapshot={checked=true,same_login=counters[17]==1,same_header=counters[18]==1}
        end
    end
    ffi.C.munmap(counters,mapping_bytes)
end
for _i,fd in ipairs(descriptors) do ffi.C.close(fd) end
if not ok then
    report.failed_line=tonumber(type(reason)=='string' and (reason:match('owner_reading_probe%.lua:(%d+):')
        or reason:match('owner_reader_estimate_case%.lua:(%d+):'))) or 0
end
if native_recovery_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}};assert(#value<=16384)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..native_recovery_input.native_recovery.rpc_token..'_RESULT='..value..'\n')
elseif close_trial_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}};assert(#value<=16384)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..close_trial_input.native_close_trial.rpc_token..'_RESULT='..value..'\n')
elseif timer_trial_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}};assert(#value<=16384)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..timer_trial_input.native_timer_trial.rpc_token..'_RESULT='..value..'\n')
elseif initial_reader_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}}
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..initial_reader_input.native_initial_reader.rpc_token..'_RESULT='..value..'\n')
elseif reader_trial_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}};assert(#value<=16384)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..reader_trial_input.native_reader_trial.rpc_token..'_RESULT='..value..'\n')
elseif trial_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}};assert(#value<=16384)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial_input.selection_trial.rpc_token..'_RESULT='..value..'\n')
else
    io.stdout:write('\nWEREAD_OWNER_READING_RESULT='..json.encode{report=report,cookies=latest_cookies or {},rejected_html=rejected_html,
        recovery_private=recovery_private,progress_private=progress_private,candidate_private=candidate_private,selection_private=selection_private}..'\n')
end
os.exit(ok and 0 or 1)
