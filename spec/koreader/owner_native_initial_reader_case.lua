-- One new native first position. Host RPC owns the independent one-slot scope;
-- ordinary production SourceUpload/ProgressSync owns the first operation.
return function(input,counters)
    local json,ffi=require('json'),require('ffi')
    local P=require('weread.lib.native_position_protocol');local C=require('weread.lib.native_position_contract')
    local State=require('weread.lib.native_cloud_state')
    local trial,plan=input.native_initial_reader,input.native_initial_reader.plan
    local case={report={phase='init',permit_writes=trial.armed,source_reference=false,manual_controls=false,
        source_plan=false,no_automatic_initialization=false,local_commit=false,sqlite_before_posts=false,dispatch_blocked=false,
        native_gets=0,native_posts=0,blocked_posts=0,native_denied=0,last_native_status=0,acknowledged=0,steps=0,failed_line=0}}
    local parent=tonumber(ffi.C.getpid())
    local function clone(value) return json.decode(json.encode(value)) end
    local function rpc(kind,seq,extra)
        local value=extra or {};value.kind,value.seq=kind,seq
        local raw=json.encode(value);assert(#raw<14000)
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.stdout:flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local reply=json.decode(line)
        assert(reply.kind==kind and reply.seq==seq and reply.ok==true,'initial_reader/host_rejected')
        for key in pairs(reply) do assert(key=='kind' or key=='seq' or key=='ok') end
    end
    function case:is_native(options)
        return type(options.url)=='string' and options.url:find('https://i.weread.qq.com/',1,true)==1
    end
    function case:request(client,options,request)
        local h=options.headers or {};local grant=input.native_grant
        local allowed=options.url=='https://i.weread.qq.com/book/info?bookId='..input.book_id
            or options.url=='https://i.weread.qq.com/book/getProgress?bookId='..input.book_id
            or options.url=='https://i.weread.qq.com/shelf/sync' or options.url=='https://i.weread.qq.com/feature?synckey=0'
        local writing=options.method=='POST' and options.url=='https://i.weread.qq.com/book/read' and type(options.body)=='string'
        if h.vid~=grant.vid or h.accessToken~=grant.accessToken or h.Cookie or h.Authorization
            or options.skip_cookie~=true or options.persist_response_cookies~=false or options.sensitive~=true
            or type(options.sink)~='function' or not (allowed and options.method=='GET' and not options.body or writing)
            or counters[23]>=40 then counters[25]=counters[25]+1;error('initial_reader/native_scope',0) end
        local seq=tonumber(counters[27])
        if writing then
            assert(tonumber(ffi.C.getpid())~=parent and seq==1 and counters[24]==0)
            local service=self.plugin.source_upload.native.service
            local row=assert(service.journal:read());assert(row.phase=='pending' and C.valid(row.metadata))
            local expected=plan.target
            assert(P.equal(row.metadata.desired,expected) and State.equal(row.metadata.before,plan.baseline.native)
                and row.metadata.source_sha256==input.source_raw_sha256 and row.metadata.file_id==plan.source_file_id)
            local body=json.decode(options.body)
            assert(body.chapterOffset==expected.chapter_offset and body.summary==expected.summary
                and body.currentProgress==expected.raw_percent and body.bookVersion==plan.version
                and body.readingTime==0 and next(body.hours)==nil)
            rpc(trial.armed and 'claim' or 'dry_body',seq,{body=body})
            if not trial.armed then counters[26]=counters[26]+1;error('initial_reader/disarmed',0) end
            counters[24]=counters[24]+1
            local sink=options.sink;local chunks,size={},0
            options.sink=function(chunk)
                if chunk then size=size+#chunk;if size<=4*1024*1024 then chunks[#chunks+1]=chunk end end
                return sink(chunk)
            end
            local a,b,c=request(client,options);counters[28]=tonumber(b) or 0
            local raw=type(a)=='string' and a or table.concat(chunks)
            local decoded,ack=pcall(json.decode,raw)
            if decoded and tonumber(b) and b>=200 and b<300 and P.confirmed(ack) then
                rpc('ack',seq);counters[29]=counters[29]+1
            end
            return a,b,c
        end
        counters[23]=counters[23]+1
        local a,b,c=request(client,options);counters[28]=tonumber(b) or 0;return a,b,c
    end
    function case:secrets()
        return {input.native_grant.accessToken,input.native_grant.refreshToken,input.native_grant.deviceId}
    end
    function case:run(plugin,reader,pump,index,origin)
        self.plugin=plugin;local source,doc=plugin.source_position,reader.document
        local Credentials=require('weread.lib.native_credentials');self.original_credentials=Credentials.new
        Credentials.new=function(_self,settings)
            assert(settings.data_dir:sub(1,#assert(os.getenv('KO_HOME')))==os.getenv('KO_HOME'))
            return {read=function() return input.native_grant,1,nil,false end}
        end
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar'}) do
            local method=doc[name]
            doc[name]=function(document,...)
                assert(tonumber(ffi.C.getpid())==parent,'initial_reader/child_native_document');return method(document,...)
            end
        end
        local function jump(point)
            local target=clone(origin);target.chapter_offset=point.chapter_offset
            local finished,value
            assert(plugin:openSourcePosition(target,function(result) value,finished=result,true end))
            pump(function() return finished and source:current() end);assert(value)
            local current=assert(source:current());assert(current.chapter_offset==point.chapter_offset and current.raw_sha256==input.source_raw_sha256)
            local located=assert(index:locate(current.chapter_offset))
            assert(doc:isXPointerInCurrentPage(located.xpointer) and assert(index:capture(located.xpointer)).co==point.chapter_offset)
            return current
        end
        jump(plan.target);self.report.source_reference=true;self.report.phase='manual';counters[27]=1
        local uploader=plugin.source_upload;local original_prepare=uploader.prepare
        uploader:_native().service.task_options.zone=trial.time_zone
        uploader.prepare=function(active,intent,callback)
            return original_prepare(active,intent,function(prepared,reason)
                if prepared then
                    assert(prepared.transport=='native_position' and prepared.basis=='raw_txt_utf16' and prepared.is_current())
                    local metadata=assert(active.native.job.metadata)
                    assert(C.valid(metadata) and State.equal(metadata.before,plan.baseline.native))
                    if not trial.bind_percent then plan.target.raw_percent=metadata.desired.raw_percent;plan.source_file_id=metadata.file_id end
                    assert(metadata.file_id==plan.source_file_id)
                    assert(P.equal(metadata.desired,plan.target) and metadata.desired.raw_percent==intent.percent)
                    self.metadata=clone(metadata)
                    rpc('plan',1,{metadata=metadata,reader_percent=intent.percent})
                    self.report.source_plan=true
                end
                callback(prepared,reason)
            end)
        end
        local config=plugin.settings:get('sync');config.ask_on_conflict=true;plugin.settings:set('sync',config)
        local sync=plugin.progress_sync
        assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        local UI=require('ui/uimanager');local choice=assert(UI:getTopmostVisibleWidget())
        assert(choice.cancel_text==require('weread.lib.plugin_util').tr('Keep KOReader progress'))
        assert(choice.ok_text==require('weread.lib.plugin_util').tr('Sync current position') and not sync.verified)
        choice.cancel_callback();UI:close(choice)
        assert(not sync.verified and counters[24]==0 and counters[26]==0 and not sync:prepare_close() and not sync.interval.task)
        self.report.no_automatic_initialization=true
        assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        choice=assert(UI:getTopmostVisibleWidget())
        assert(choice.ok_text==require('weread.lib.plugin_util').tr('Sync current position'))
        choice.ok_callback();UI:close(choice);self.report.manual_controls=true
        pump(function() return not sync.uploading end);uploader.prepare=original_prepare
        if not trial.armed then
            assert(counters[24]==0 and counters[26]==1 and uploader.native.service:pending().phase=='pending')
            assert(plugin.settings:get_book(input.book_id).pending_upload_position)
            self.report.dispatch_blocked=true;self.report.phase='complete';return
        end
        local saved=plugin.settings:get_book(input.book_id)
        assert(counters[24]==1 and counters[29]==1 and not uploader.native.service:pending()
            and saved.last_uploaded_position.wire_basis=='raw_txt_utf16' and not saved.pending_upload_position
            and saved.last_uploaded_position.source_position.chapter_offset==plan.target.chapter_offset
            and not saved.last_uploaded_position.summary and not saved.last_remote_position.summary)
        assert(sync.verified and sync.verified_reason=='first_sync_confirmed')
        self.report.local_commit=true;rpc('verified',1);self.report.steps=1
        self.report.phase='complete'
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            assert(not content:find(plan.target.summary,1,true))
        end
    end
    function case:finish(reason)
        if self.original_credentials then require('weread.lib.native_credentials').new=self.original_credentials end
        self.report.native_gets,self.report.native_posts,self.report.native_denied=tonumber(counters[23]),tonumber(counters[24]),tonumber(counters[25])
        self.report.blocked_posts,self.report.last_native_status,self.report.acknowledged=tonumber(counters[26]),tonumber(counters[28]),tonumber(counters[29])
        self.report.sqlite_before_posts=(trial.armed and counters[24]==1 or not trial.armed and counters[26]==1) and counters[25]==0
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_native_initial_reader_case%.lua:(%d+):')) or 0
    end
    function case:private() return nil end
    return case
end
