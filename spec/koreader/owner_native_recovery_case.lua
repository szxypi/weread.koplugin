-- Real ReaderUI/SDK, one host-claimed authorization, no data POST transport.
return function(input,counters)
    local json,ffi=require('json'),require('ffi')
    local C=require('weread.lib.native_position_contract');local P=require('weread.lib.native_position_protocol')
    local trial=input.native_recovery;local parent=tonumber(ffi.C.getpid())
    local case={report={phase='init',source_reference=false,manual_controls=false,source_plan=false,expired_observed=false,
        renewal_saved=false,new_grant_snapshot=false,dispatch_blocked=false,sqlite_before_block=false,native_file_audit=false,
        fresh_source=false,no_expiry=false,native_gets=0,authentication_posts=0,blocked_posts=0,expired_responses=0,
        native_denied=0,last_native_status=0,source_preparations=0,failed_line=0}}
    local function rpc(kind,seq,value)
        value=value or {};value.kind,value.seq=kind,seq
        local raw=json.encode(value);assert(#raw<14000)
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.stdout:flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local result=json.decode(line)
        assert(result.kind==kind and result.seq==seq and result.ok==true,'native_recovery/host_rejected')
        for key in pairs(result) do assert(key=='kind' or key=='seq' or key=='ok') end
    end
    function case:is_native(options) return type(options.url)=='string' and options.url:find('https://i.weread.qq.com/',1,true)==1 end
    function case:request(client,options,request)
        local h=options.headers or {};local url=options.url
        local function check(ok)
            if not ok then counters[25]=counters[25]+1;error('native_recovery/native_scope',0) end
        end
        check(options.skip_cookie==true and options.persist_response_cookies==false and options.sensitive==true
            and not h.Cookie and not h.Authorization and type(options.sink)=='function')
        if url=='https://i.weread.qq.com/login' then
            local grant,revision,err,pending=self.plugin.native_renewal.store:read()
            check(options.method=='POST' and type(options.body)=='string' and #options.body<14000 and not h.vid and not h.accessToken
                and not err and grant and revision==2 and pending and counters[24]==0 and counters[27]==1
                and not self.plugin.source_upload.native.service:pending() and tonumber(ffi.C.getpid())~=parent)
            rpc('claim',2,{body=json.decode(options.body)});counters[24]=1
        elseif url=='https://i.weread.qq.com/book/read' then
            check(options.method=='POST' and counters[24]==1 and counters[29]==1 and counters[26]==0 and self.fresh
                and h.vid==input.vid and h.accessToken==self.fresh.accessToken and tonumber(ffi.C.getpid())~=parent)
            local row=assert(self.plugin.source_upload.native.service.journal:read())
            assert(row.phase=='pending' and C.valid(row.metadata) and row.metadata.desired.chapter_offset==trial.target.chapter_offset)
            rpc('data',5,{body=json.decode(options.body)});counters[26]=1
            error('native_recovery/data_transport_blocked',0)
        else
            check(options.method=='GET' and not options.body and counters[23]<80 and h.vid==input.vid and type(h.accessToken)=='string'
                and (url=='https://i.weread.qq.com/book/info?bookId='..input.book_id
                    or url=='https://i.weread.qq.com/book/getProgress?bookId='..input.book_id
                    or url=='https://i.weread.qq.com/shelf/sync' or url=='https://i.weread.qq.com/feature?synckey=0'))
            if counters[24]==0 then check(h.accessToken==input.native_grant.accessToken)
            elseif counters[29]==1 then check(self.fresh and h.accessToken==self.fresh.accessToken) end
            counters[23]=counters[23]+1
        end
        local a,b,c=request(client,options);counters[28]=tonumber(b) or 0
        if tonumber(b)==401 then
            check(options.method=='GET' and counters[27]==0 and counters[24]==0)
            counters[27]=1;rpc('expiry',1,{url=url,status=401})
        end
        return a,b,c
    end
    function case:run(plugin,reader,pump,index,origin)
        self.plugin=plugin;local source,doc=plugin.source_position,reader.document
        local initial=plugin.native_renewal.store
        local grant,initial_revision,err=initial:read();assert(not grant and initial_revision==0 and not err)
        assert(initial:save(input.native_grant,plugin.settings:get_auth_scope(),0,input.shelf_books))
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar'}) do
            local method=doc[name];doc[name]=function(document,...)
                assert(tonumber(ffi.C.getpid())==parent,'native_recovery/child_document');return method(document,...)
            end
        end
        local target=json.decode(json.encode(origin));target.chapter_offset=trial.target.chapter_offset
        local done,applied
        assert(plugin:openSourcePosition(target,function(value) done,applied=true,value end));pump(function() return done and source:current() end)
        assert(applied and source:current().chapter_offset==target.chapter_offset)
        local located=assert(index:locate(target.chapter_offset));assert(doc:isXPointerInCurrentPage(located.xpointer)
            and assert(index:capture(located.xpointer)).co==target.chapter_offset);self.report.source_reference=true
        local prepare=source.prepare_current_native_preview
        source.prepare_current_native_preview=function(active,callback) counters[30]=counters[30]+1;return prepare(active,callback) end
        local store=plugin.native_renewal.store;local save=store.save
        store.save=function(active,credentials,scope,revision,count)
            assert(tonumber(ffi.C.getpid())==parent and revision==2 and counters[24]==1 and counters[29]==0)
            rpc('verified',3,{credentials=credentials,book_count=count})
            local ok,reason=save(active,credentials,scope,revision,count)
            assert(ok);case.fresh=credentials;counters[29]=1;return ok,reason
        end
        local uploader=plugin.source_upload;local original=uploader.prepare;uploader:_native().service.task_options.zone=trial.time_zone
        uploader.prepare=function(active,intent,callback)
            return original(active,intent,function(prepared,why)
                if prepared then
                    local metadata=assert(active.native.job.metadata)
                    assert(prepared.is_current() and C.valid(metadata) and P.equal(metadata.before,trial.baseline)
                        and metadata.desired.chapter_offset==trial.target.chapter_offset and metadata.desired.summary==trial.target.summary
                        and metadata.desired.raw_percent==intent.percent)
                    case.report.source_plan=true
                    if counters[27]==0 then
                        rpc('no_expiry',0,{metadata=metadata,reader_percent=intent.percent});case.report.no_expiry=true
                        prepared.release();callback(nil,'source_cancelled');return
                    end
                    assert(counters[29]==1 and counters[30]==2)
                    rpc('plan',4,{metadata=metadata,reader_percent=intent.percent})
                end
                callback(prepared,why)
            end)
        end
        local config=plugin.settings:get('sync');config.ask_on_conflict=true;plugin.settings:set('sync',config)
        self.report.phase='manual';local sync=plugin.progress_sync
        assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        local UI=require('ui/uimanager');local choice=assert(UI:getTopmostVisibleWidget())
        assert(choice.cancel_text==require('weread.lib.plugin_util').tr('Keep KOReader progress'))
        choice.cancel_callback();UI:close(choice);self.report.manual_controls=true
        pump(function() return not sync.uploading end);uploader.prepare=original;store.save=save
        local saved=assert(plugin.settings:get_book(input.book_id));assert(saved.pending_upload_position and not saved.last_uploaded_position)
        if self.report.no_expiry then
            assert(counters[24]==0 and counters[26]==0 and counters[30]==1 and not uploader.native.service:pending())
        else
            assert(counters[24]==1 and counters[26]==1 and counters[29]==1 and counters[30]==2
                and uploader.native.service:pending().phase=='pending')
            self.report.expired_observed,self.report.renewal_saved,self.report.new_grant_snapshot=true,true,true
            self.report.dispatch_blocked,self.report.sqlite_before_block,self.report.fresh_source=true,true,true
        end
        self.report.phase='complete'
    end
    function case:secrets()
        local values={}
        for _i,grant in ipairs({input.native_grant,self.fresh}) do
            for _j,key in ipairs({'accessToken','refreshToken','deviceId'}) do values[#values+1]=grant[key] end
        end
        return values
    end
    function case:allows_secret_file(filename,content)
        local store=self.plugin and self.plugin.native_renewal.store
        if not store or filename~=store.path then return false end
        local home=assert(os.getenv('KO_HOME'));assert(filename:sub(1,#home+1)==home..'/' and #content<=65536)
        local record=assert(store:_read());local expected=self.fresh or input.native_grant
        for key in pairs(record) do assert(key=='revision' or key=='authorization') end
        local fields={vid=true,accessToken=true,refreshToken=true,deviceId=true,epoch=true,verified_at=true,book_count=true}
        for key in pairs(record.authorization) do assert(fields[key]) end
        assert(record.revision==(self.fresh and 3 or 1) and record.renewal_pending==nil and record.authorization.epoch==1
            and record.authorization.book_count==input.shelf_books and type(record.authorization.verified_at)=='number')
        for _i,key in ipairs({'vid','accessToken','refreshToken','deviceId'}) do assert(record.authorization[key]==expected[key]) end
        local permitted={};for _i,key in ipairs({'accessToken','refreshToken','deviceId'}) do permitted[expected[key]]=true end
        self.report.native_file_audit=true;return permitted
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            assert(not content:find(trial.baseline.summary,1,true) and not content:find(trial.target.summary,1,true))
        end
    end
    function case:finish(reason)
        self.report.native_gets,self.report.authentication_posts,self.report.native_denied=tonumber(counters[23]),tonumber(counters[24]),tonumber(counters[25])
        self.report.blocked_posts,self.report.expired_responses,self.report.last_native_status=tonumber(counters[26]),tonumber(counters[27]),tonumber(counters[28])
        self.report.source_preparations=tonumber(counters[30])
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_native_recovery_case%.lua:(%d+):')) or 0
    end
    function case:private() return nil end
    return case
end
