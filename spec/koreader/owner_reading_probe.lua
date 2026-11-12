-- Real owner book: plugin selection -> uncached Read -> native EPUB -> offline
-- reopening. Private files are confined to the runner's tmpfs profile. The
-- transport allowlist is installed before the plugin loads and is fail-closed.
require('ffi').log=function() end
require('setupkoenv')
local ffi=require('ffi');require('ffi/posix_h')
local json=require('json')
local trial_mode=arg[1]=='selection-trial'
local mode=trial_mode and 'live' or arg[1]
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
local ok,reason=pcall(function()
    assert(mode=='live' or mode=='reopen')
    local home=assert(os.getenv('KO_HOME'))
    assert(ffi.os=='Linux' and home:match('^/dev/shm/weread%-reading%-[%w_]+/profile$'))
    local raw
    if trial_mode then
        local length=assert(io.stdin:read('*l'));assert(#length<=6 and length:match('^[1-9]%d*$') and tonumber(length)<=256*1024)
        raw=assert(io.stdin:read(tonumber(length)));assert(#raw==tonumber(length))
    else raw=assert(io.stdin:read(256*1024+1)) end
    assert(#raw<=256*1024)
    local input=json.decode(raw)
    assert((input.selection_trial~=nil)==trial_mode)
    if trial_mode then
        trial_input=input
        assert(type(input.selection_trial.rpc_token)=='string' and #input.selection_trial.rpc_token==32
            and input.selection_trial.rpc_token:match('^[a-f0-9]+$'))
        assert(type(input.selection_trial.armed)=='boolean' and input.selection_trial.armed==(os.getenv('WEREAD_SELECTION_ARMED')=='1'))
    end
    assert(type(input.vid)=='string' and input.vid:match('^[1-9]%d*$'))
    local cb_reading=input.cb_reading==true
    local cb_full=input.cb_full_book==true
    assert(not cb_full or cb_reading and type(input.full_manifest)=='table')
    assert(input.diagnostic_read_pacing==nil or input.diagnostic_read_pacing==true and cb_full)
    local diagnostic_pacing=input.diagnostic_read_pacing==true
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
        if input.selection_mock_port then
            local grant=input.selection_preview and input.selection_preview.credentials
            assert(input.vid=='900000' and input.book_id=='900001' and input.cookies.wr_skey=='mock_key'
                and grant.accessToken=='mock-native-access' and grant.refreshToken=='mock-native-refresh')
            value.mock_endpoint='http://127.0.0.1:'..input.selection_mock_port
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
        if full or input.annotations or input.progress_preview or input.progress_roundtrip or input.source_upload_preview or input.native_source_excerpt or input.selection_preview then
            local cache=value:get('cache');cache.download_book_images=full;cache.download_underlines_and_thoughts=false
            cache.auto_prefetch_next_chapter=false;value:set('cache',cache)
        end
        value:flush()
        return value
    end
    report.anonymous_auth=true
    pcall(ffi.cdef,'void *mmap(void *, unsigned long, int, int, int, long); int munmap(void *, unsigned long);')
    mapping_bytes=full and 4096+4*1024*1024 or 4096
    local memory=ffi.C.mmap(nil,mapping_bytes,3,0x21,-1,0);assert(memory~=ffi.cast('void *',-1));counters=ffi.cast('int *',memory)
    if input.annotations then
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
    local URL=require('socket.url')
    local function resource(url)
        if type(url)~='string' or #url>8192 or url:find('[%z%c%s]') then return false end
        local parts=URL.parse(url)
        if not parts or parts.scheme~='https' and parts.scheme~='http' or parts.authority~=parts.host
            or parts.fragment or type(parts.host)~='string' then return false end
        local host=parts.host:lower()
        return host:match('%.qpic%.cn$') or host:match('%.qlogo%.cn$') or host:match('%.gtimg%.com$')
            or host:match('%.qq%.com$') and host~='weread.qq.com' and host~='i.weread.qq.com'
    end
    local chapter_count=full and #input.full_manifest or 1
    local limits={2,60,math.max(8,2*chapter_count+4),4,math.max(12,6*chapter_count),full and 512 or 60}
    if selection_case then limits={2,60,12,8,18,60} end
    local resource_urls={}
    local protected_resources={}
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
            if (input.progress_roundtrip or input.native_source_excerpt) and options.sensitive == true then
                local id, stamp=options.url:match('^https://weread%.qq%.com/web/book/getProgress%?bookId=([1-9]%d*)&_=(%d+)$')
                if id==input.book_id and #stamp<=16 and math.abs(tonumber(stamp)-os.time()*1000)<=30000 then return 2 end
                if input.native_source_excerpt and id and progress_urls['https://weread.qq.com/web/book/getProgress?bookId='..id]
                    and #stamp<=16 and math.abs(tonumber(stamp)-os.time()*1000)<=30000
                    and options.diagnostic_api=='shelf_progress' and options.skip_cookie==true
                    and options.persist_response_cookies==false and h.Cookie==Cookie.to_header(cookies)
                    and h.Referer==Protocol.reader_url(id) then return 2 end
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
    local request,binary,download,follow=Client.request,Client.get_binary,Client.download_to_file,Client.request_follow
    local test={settings={get=function() return input.cookies end}}
    local valid={url=root_url,method='GET',headers={}}
    assert((classify(test,valid)~=nil)==(mode=='live'))
    for _i,url in ipairs({'https://weread.qq.com/web/book/read','https://weread.qq.com/web/login/renewal',
        'https://weread.qq.com/web/shelf/add','https://weread.qq.com/logout',root_url..'?unexpected=1'}) do
        assert(not classify(test,{url=url,method='POST',headers={},body='{}'}))
    end
    assert(not classify(test,{url=root_url,method='GET',headers={Cookie='invalid'}}))
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
    Common.isNetworkOnline,Common.isNetworkConnected=function() return mode=='live' end,function() return mode=='live' end
    local Loader=require('pluginloader');Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins={},{},{}
    for _i,entry in ipairs(Loader:_discover()) do if entry.name=='weread' then Loader:_load{entry} end end
    assert(#Loader.enabled_plugins==1)
    package.path=source..'/?.lua;'..package.path
    local FM,Reader=require('apps/filemanager/filemanager'),require('apps/reader/readerui')
    local socket=require('socket')
    local download_finished
    local download_failed=false
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
        local deadline=socket.gettime()+(full and report.phase=='prepare' and 480 or 70)
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
    report.phase='shelf'
    if mode=='live' then
        local loaded=false
        plugin:refreshBookshelf(nil,{on_loaded=function(success) loaded=success end})
        pump(function() return not plugin.shelf_refreshing end)
        assert(loaded and plugin.shelf_active_source=='web')
    end
    local books=assert(plugin.library_db:getShelf());assert(#books==input.shelf_books)
    report.shelf_books=#books
    local target
    for _i,book in ipairs(books) do if tostring(book.bookId)==input.book_id then target=book end end
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
    report.phase='detail'
    pump(function() return plugin._book_detail_view and not plugin.book_metadata_context end)
    local detail=assert(plugin._book_detail_view)
    local label=require('weread.lib.plugin_util').tr(full and mode=='live' and '⇩ Download full book' or '▤ Read')
    local pressed=false
    for _i,buttons in ipairs({detail._action_buttons or {},detail._footer_actions or {}}) do
        for _j,button in ipairs(buttons) do
            if button.text==label then assert(button.enabled~=false);button.callback();pressed=true;break end
        end
        if pressed then break end
    end
    assert(pressed)
    if mode=='live' then assert((full or plugin.book_reading_context) and not Reader.instance) end
    report.phase='prepare'
    pump(function() return Reader.instance and Reader.instance.weread and Reader.instance.document end)
    reader=Reader.instance;plugin=reader.weread
    report.phase='native'
    local document=reader.document
    assert(document.file:sub(1,#home)==home and document.file:match('%.epub$'))
    assert(plugin:detectWeReadBook()==input.book_id)
    local book=assert(plugin.settings:get_book(input.book_id))
    if full then assert(book.cached_full_book==document.file)
    else assert(book.cached_chapters and book.cached_chapters[input.chapter_uid]==document.file) end
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
    report.pages=document:getPageCount();assert(report.pages>1)
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
    local origin=document:getXPointer()
    reader.rolling:onGotoXPointer(matches[1].start);tick()
    assert(document:isXPointerInCurrentPage(matches[1].start))
    local y,x=document:getScreenPositionFromXPointer(matches[1].start)
    assert(y>=0 and y<Device.screen:getHeight() and x>=0 and x<Device.screen:getWidth())
    UI:forceRePaint();report.source_text_visible=true
    reader.rolling:onGotoXPointer(origin);tick()
    local next_page=reader:getCurrentPage()==1 and 2 or 1
    reader.rolling:onGotoPage(next_page);tick()
    assert(reader:getCurrentPage()==next_page)
    report.page_turn=true
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
    local checkpoint={file=document.file,xpointer=document:getXPointer(),page=reader:getCurrentPage()}
    local file=assert(io.open(checkpoint_path,'wb'));assert(file:write(json.encode(checkpoint)));file:close()
    report.phase='close'
    while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
    plugin:closeWeReadUI();plugin:onFlushSettings();reader:onClose(false);reader=nil
    plugin.settings:flush();G_reader_settings:flush();report.position_checkpoint=true
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
                    for _i,secret in ipairs(secrets) do assert(not content:find(secret,1,true)) end
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
    report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_reading_probe%.lua:(%d+):')) or 0
end
if trial_input then
    local value=json.encode{report=report,cookies=latest_cookies or {}};assert(#value<=16384)
    io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial_input.selection_trial.rpc_token..'_RESULT='..value..'\n')
else
    io.stdout:write('\nWEREAD_OWNER_READING_RESULT='..json.encode{report=report,cookies=latest_cookies or {},rejected_html=rejected_html,
        recovery_private=recovery_private,progress_private=progress_private,candidate_private=candidate_private,selection_private=selection_private}..'\n')
end
os.exit(ok and 0 or 1)
