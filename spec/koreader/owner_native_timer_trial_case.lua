-- A new reader-scoped two-slot trial. Host RPC owns its independent grant;
-- ordinary production SourceUpload/ProgressSync owns the first operation.
return function(input,counters)
    local json,ffi=require('json'),require('ffi')
    local P=require('weread.lib.native_position_protocol');local C=require('weread.lib.native_position_contract')
    local trial,plan=input.native_timer_trial,input.native_timer_trial.plan
    local case={report={phase='init',permit_writes=trial.armed,source_reference=false,baseline_readonly=false,
        timer_controls=false,source_plan=false,restore_source=false,local_commit=false,sqlite_before_posts=false,dispatch_blocked=false,
        local_save_failed=false,receipt_kept=false,storage_notice=false,timer_stopped=false,review_worker=false,truthful_history=false,
        fresh_choice=false,cloud_choice=false,natural_timer=trial.natural_timer,
        native_gets=0,native_posts=0,blocked_posts=0,native_denied=0,last_native_status=0,acknowledged=0,steps=0,failed_line=0,
        timer_elapsed_seconds=0,review_gets=0}}
    local parent=tonumber(ffi.C.getpid());local restore_service
    local function clone(value) return json.decode(json.encode(value)) end
    local function rpc(kind,seq,extra)
        local value=extra or {};value.kind,value.seq=kind,seq
        local raw=json.encode(value);assert(#raw<14000)
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.stdout:flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local reply=json.decode(line)
        assert(reply.kind==kind and reply.seq==seq and reply.ok==true,'timer_trial/host_rejected')
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
            or counters[23]>=80 then counters[25]=counters[25]+1;error('timer_trial/native_scope',0) end
        local seq=tonumber(counters[27])
        if writing then
            assert(tonumber(ffi.C.getpid())~=parent and (seq==1 or seq==2) and counters[24]==seq-1)
            local service=seq==1 and self.plugin.source_upload.native.service or restore_service
            local row=assert(service.journal:read());assert(row.phase=='pending' and C.valid(row.metadata))
            local expected=seq==1 and plan.target or plan.baseline
            assert(P.equal(row.metadata.desired,expected) and row.metadata.source_sha256==input.source_raw_sha256)
            local body=json.decode(options.body)
            assert(body.chapterOffset==expected.chapter_offset and body.summary==expected.summary
                and body.currentProgress==expected.raw_percent and body.bookVersion==plan.version
                and body.readingTime==0 and next(body.hours)==nil)
            rpc(trial.armed and 'claim' or 'dry_body',seq,{body=body})
            if not trial.armed then counters[26]=counters[26]+1;error('timer_trial/disarmed',0) end
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
                assert(tonumber(ffi.C.getpid())==parent,'timer_trial/child_native_document');return method(document,...)
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
        local UI=require('ui/uimanager');local tr=require('weread.lib.plugin_util').tr
        local function clean()
            while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        end
        local sync=plugin.progress_sync;local timer=sync.interval
        local config=plugin.settings:get('sync');config.ask_on_conflict=true;config.upload_interval_minutes=0;config.upload_on_close=false
        plugin.settings:set('sync',config)
        jump(plan.baseline);self.report.source_reference=true
        assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        assert(sync.verified and not sync.dirty and counters[24]==0);clean();self.report.baseline_readonly=true
        self.report.phase='timer';counters[27]=1
        local uploader=plugin.source_upload;local original_prepare=uploader.prepare
        uploader:_native().service.task_options.zone=trial.time_zone
        uploader.prepare=function(active,intent,callback)
            return original_prepare(active,intent,function(prepared,reason)
                if prepared then
                    assert(prepared.transport=='native_position' and prepared.basis=='raw_txt_utf16' and prepared.is_current())
                    local metadata=assert(active.native.job.metadata)
                    assert(C.valid(metadata) and P.equal(metadata.before,plan.baseline))
                    if not trial.bind_percent then plan.target.raw_percent=metadata.desired.raw_percent end
                    assert(P.equal(metadata.desired,plan.target) and metadata.desired.raw_percent==intent.percent)
                    self.metadata=clone(metadata)
                    rpc('plan',1,{metadata=metadata,reader_percent=intent.percent})
                    self.report.source_plan=true
                end
                callback(prepared,reason)
            end)
        end
        local patch=plugin.settings.patch_reading_state
        local failed=false
        plugin.settings.patch_reading_state=function(settings,id,value,...)
            if value.last_uploaded_position and tonumber(counters[24])==1 then
                local row=assert(uploader.native.service:pending())
                assert(trial.armed and row.phase=='verified' and counters[29]==1 and not failed)
                failed=true;return false
            end
            return patch(settings,id,value,...)
        end
        local notify=sync.notify;local noticed=false
        sync.notify=function(code,data)
            if code=='upload_local_save_failed' then assert(data.acknowledged==true);noticed=true end
            return notify(code,data)
        end
        -- The real arm never replaces the production clock or runs a due task
        -- early. Only synthetic/disarmed dispatch can advance a private clock.
        local fast=not trial.armed or not trial.natural_timer;local clock=100
        if fast then assert(not trial.armed or input.reader_mock_port);timer.now=function() return clock end end
        rpc('armed',0)
        config.upload_interval_minutes=1;plugin.settings:set('sync',config)
        jump(plan.target);assert(sync.verified and sync.dirty and timer.task);self.report.timer_controls=true
        if fast then
            clock=assert(timer.due);local task=assert(timer.task);UI:unschedule(task);task()
        else
            assert(timer.now==os.time);local armed_time=assert(timer.started)
            pump(function() return sync.uploading or counters[24]>0 end)
            self.report.timer_elapsed_seconds=os.time()-armed_time
            assert(self.report.timer_elapsed_seconds>=60)
        end
        pump(function() return not sync.uploading and (failed or not trial.armed and counters[26]==1) end)
        uploader.prepare=original_prepare;plugin.settings.patch_reading_state=patch;sync.notify=notify
        config.upload_interval_minutes=0;plugin.settings:set('sync',config)
        if not trial.armed then
            assert(counters[24]==0 and counters[26]==1 and uploader.native.service:pending().phase=='pending')
            assert(plugin.settings:get_book(input.book_id).pending_upload_position)
            timer:halt();self.report.dispatch_blocked=true;self.report.phase='complete';return
        end
        local service=uploader.native.service;local record=assert(service:pending())
        local saved=plugin.settings:get_book(input.book_id)
        assert(failed and sync.state=='error' and not sync.verified and sync.dirty and not sync.uploading)
        self.report.local_save_failed=true
        assert(record.phase=='verified' and counters[24]==1 and counters[29]==1
            and not saved.last_uploaded_position and saved.pending_upload_position.source_position.chapter_offset==plan.target.chapter_offset)
        self.report.receipt_kept=true
        assert(not timer.task and not timer.cycle and not timer.scheduled);self.report.timer_stopped=true
        local notice=assert(UI:getTopmostVisibleWidget())
        assert(noticed and notice.text==tr('WeRead confirmed the upload, but the local result could not be saved. The confirmed record is kept. Check storage, then sync again to review it.'))
        self.report.storage_notice=true;rpc('verified',1,{save_failed=true,phase=record.phase});self.report.steps=1
        clean();self.report.phase='review'
        -- New local movement must survive archiving and force a fresh choice.
        local newer=clone(origin)
        if newer.chapter_offset==plan.target.chapter_offset then newer.chapter_offset=plan.baseline.chapter_offset end
        jump(newer);sync:checkpoint_local('timer_recovery_newer_local')
        local local_point=assert(sync:capture_local())
        assert(local_point.source_position.chapter_offset~=plan.target.chapter_offset)
        config.ask_on_conflict=false;plugin.settings:set('sync',config)
        assert(plugin:onWeReadSyncProgress())
        local dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.ok_text==tr('Check cloud position'))
        local gets=tonumber(counters[23]);dialog.ok_callback()
        local context=assert(plugin._native_position_review_ui)
        assert(context.task.worker and context.task.worker.job);local review_pid=context.task.worker.job.pid
        self.report.review_worker=true
        pump(function() return context.token~=nil end)
        self.report.review_gets=tonumber(counters[23])-gets;assert(self.report.review_gets==6)
        assert(service:pending().id==record.id and service:pending().phase=='verified' and counters[24]==1)
        dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.ok_text==tr('Archive and compare again'))
        assert(not dialog.text:find(tr('The previous request has no confirmed receipt. A matching cloud position does not prove that request succeeded.'),1,true))
        dialog.ok_callback();assert(not service:pending() and counters[24]==1)
        local db=assert(plugin.library_db:open());local raw=db:rowexec('SELECT payload FROM native_position_write_history');db:close()
        local history=json.decode(raw)
        assert(history.phase=='verified' and history.id==record.id and history.metadata_sha256==C.hash(record.metadata)
            and history.current_matches_target==true and not raw:find(record.metadata.desired.summary,1,true))
        self.report.truthful_history=true
        pump(function() return not sync.pulling end)
        saved=plugin.settings:get_book(input.book_id)
        assert(saved.pending_upload_position.source_position.chapter_offset==local_point.source_position.chapter_offset)
        dialog=assert(UI:getTopmostVisibleWidget());assert(dialog.ok_text==tr('Use WeRead progress') and counters[24]==1)
        self.report.fresh_choice=true;dialog.ok_callback();UI:close(dialog)
        pump(function() return not plugin.cloud_source_request and not plugin.source_navigation.job end)
        assert(sync.verified and not sync.dirty and not plugin.settings:get_book(input.book_id).pending_upload_position
            and source:current().chapter_offset==plan.target.chapter_offset and counters[24]==1)
        self.report.cloud_choice=true;clean()
        pump(function() return require('ffi/util').isSubProcessDone(review_pid) end)
        rpc('recovered',1,{verified_history=true,fresh_choice=true,cloud_choice=true})
        self.report.phase='restore';counters[27]=2
        local current=jump(plan.baseline);local candidate,receipt,done
        source:prepare_current_native_preview(function(value,_why,checked) candidate,receipt,done=value,checked,true end)
        pump(function() return done end)
        assert(candidate and receipt and candidate.chapter_offset==plan.baseline.chapter_offset
            and source:is_current_native_preview(receipt,candidate))
        self.report.restore_source=true
        local metadata=clone(self.metadata);metadata.before,metadata.desired=clone(plan.target),clone(plan.baseline)
        metadata.file_id=current.file_id
        restore_service=uploader.native.service
        local function guard()
            assert(tonumber(ffi.C.getpid())==parent,'timer_trial/restore_guard_in_child')
            return reader.document==doc and source:is_current_native_preview(receipt,candidate)
                and source:current().chapter_offset==plan.baseline.chapter_offset
        end
        local result,token,finished
        assert(restore_service:start(metadata,guard,function(value,handle) result,token,finished=value,handle,true end))
        pump(function() return finished end)
        assert(result.kind=='confirmed' and result.acknowledged and token and restore_service:pending().phase=='verified')
        rpc('verified',2);assert(restore_service:accept(token));self.report.steps=2
        assert(counters[24]==2 and counters[29]==2 and source:current().chapter_offset==plan.baseline.chapter_offset)
        clean();assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        local final=plugin.settings:get_book(input.book_id)
        assert(sync.verified and not sync.dirty and not final.pending_upload_position and not service:pending()
            and counters[24]==2 and not final.last_remote_position.summary)
        self.report.local_commit=true
        self.report.phase='complete'
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            assert(not content:find(plan.baseline.summary,1,true) and not content:find(plan.target.summary,1,true))
        end
    end
    function case:finish(reason)
        if self.original_credentials then require('weread.lib.native_credentials').new=self.original_credentials end
        if restore_service then restore_service:cancel() end
        self.report.native_gets,self.report.native_posts,self.report.native_denied=tonumber(counters[23]),tonumber(counters[24]),tonumber(counters[25])
        self.report.blocked_posts,self.report.last_native_status,self.report.acknowledged=tonumber(counters[26]),tonumber(counters[28]),tonumber(counters[29])
        self.report.sqlite_before_posts=(trial.armed and counters[24]==2 or not trial.armed and counters[26]==1) and counters[25]==0
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_native_timer_trial_case%.lua:(%d+):')) or 0
    end
    function case:private() return nil end
    return case
end
