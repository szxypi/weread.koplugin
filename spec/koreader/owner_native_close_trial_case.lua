-- A distinct closed-reader scope. Ordinary SourceClose/ProgressSync sends first;
-- exact restoration uses a fresh archive proof without a live native document.
return function(input,counters)
    local json,ffi=require('json'),require('ffi')
    local P=require('weread.lib.native_position_protocol');local C=require('weread.lib.native_position_contract')
    local trial,plan=input.native_close_trial,input.native_close_trial.plan
    local case={report={phase='init',permit_writes=trial.armed,source_reference=false,baseline_readonly=false,document_closed=false,no_closed_document_calls=false,archive_worker=false,
        source_plan=false,restore_source=false,local_commit=false,sqlite_before_posts=false,dispatch_blocked=false,
        native_gets=0,native_posts=0,blocked_posts=0,native_denied=0,last_native_status=0,acknowledged=0,steps=0,failed_line=0}}
    local parent=tonumber(ffi.C.getpid());local restore_service
    local function clone(value) return json.decode(json.encode(value)) end
    local function rpc(kind,seq,extra)
        local value=extra or {};value.kind,value.seq=kind,seq
        local raw=json.encode(value);assert(#raw<14000)
        io.stdout:write('\nWEREAD_NATIVE_THOUGHT_'..trial.rpc_token..'_STEP='..raw..'\n');io.stdout:flush()
        local line=assert(io.stdin:read('*l'));assert(#line<=16384);local reply=json.decode(line)
        assert(reply.kind==kind and reply.seq==seq and reply.ok==true,'close_trial/host_rejected')
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
            or counters[23]>=40 then counters[25]=counters[25]+1;error('close_trial/native_scope',0) end
        local seq=tonumber(counters[27])
        if writing then
            assert(counters[30]==1 and tonumber(ffi.C.getpid())~=parent and (seq==1 or seq==2) and counters[24]==seq-1)
            local service=seq==1 and self.close_controller.service or restore_service
            local row=assert(service.journal:read());assert(row.phase=='pending' and C.valid(row.metadata))
            local expected=seq==1 and plan.target or plan.baseline
            assert(P.equal(row.metadata.desired,expected) and row.metadata.source_sha256==input.source_raw_sha256)
            local body=json.decode(options.body)
            assert(body.chapterOffset==expected.chapter_offset and body.summary==expected.summary
                and body.currentProgress==expected.raw_percent and body.bookVersion==plan.version
                and body.readingTime==0 and next(body.hours)==nil)
            rpc(trial.armed and 'claim' or 'dry_body',seq,{body=body})
            if not trial.armed then counters[26]=counters[26]+1;error('close_trial/disarmed',0) end
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
        for _i,name in ipairs({'getDocumentFileContent','getTextFromXPointers','getHTMLFromXPointers','getNextVisibleChar',
            'getPrevVisibleChar','getXPointer','getCurrentPage','getPageCount','isXPointerInCurrentPage','isXPointerInDocument'}) do
            local method=doc[name]
            doc[name]=function(document,...)
                if counters[30]==1 then counters[31]=counters[31]+1;error('close_trial/closed_document',0) end
                assert(tonumber(ffi.C.getpid())==parent,'close_trial/child_native_document');return method(document,...)
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
        -- A normal read-only comparison at the original raw point establishes
        -- the cloud decision before the user advances and closes this reader.
        jump(plan.baseline)
        local sync=plugin.progress_sync
        assert(plugin:onWeReadSyncProgress());pump(function() return not sync.pulling end)
        assert(sync.verified and not sync.uploading and counters[24]==0 and not sync.dirty)
        self.report.baseline_readonly=true
        local UI=require('ui/uimanager')
        while UI:getTopmostVisibleWidget() and UI:getTopmostVisibleWidget()~=reader do UI:close(UI:getTopmostVisibleWidget()) end
        local scope=assert(source:_live());local original=assert(source:current())
        local snapshot=assert(require('weread.lib.position_source').document_metadata(doc,original.book_id,original.chapter_uid,original.render_path))
        local context=assert(source.get_upload_context());local Currentness=require('weread.lib.source_currentness')
        local restore_input={file=scope.file,book_id=original.book_id,chapter_uid=original.chapter_uid,identity=clone(snapshot.identity),
            metadata=snapshot.metadata,render_path=original.render_path,target={},chapters=clone(context.chapters),percent=context.percent,request_id=1}
        for _i,key in ipairs({'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}) do
            restore_input.target[key]=original[key]
        end
        local expected=assert(Currentness.expected{book_id=original.book_id,chapter_uid=original.chapter_uid,
            chapter_idx=require('weread.lib.source_upload_candidate').chapter_index(context.chapters,original.chapter_uid),
            raw_sha256=original.raw_sha256,raw_bytes=snapshot.record.raw_bytes})
        local access=assert(Currentness.capture(plugin.settings));local account=plugin.settings:get_auth_scope()
        jump(plan.target);self.report.source_reference=true;self.report.phase='close';counters[27]=1
        local legacy=assert(sync:capture_local());assert(sync.dirty and sync.verified)
        local Face,Native=require('weread.lib.native_close_source'),require('weread.lib.native_source_upload')
        self.Face,self.Native,self.face_factory,self.native_factory=Face,Native,Face.new,Native.new
        Face.new=function(class,options)
            local value=self.face_factory(class,options);self.close_face=value;return value
        end
        Native.new=function(class,options)
            local value=self.native_factory(class,options)
            assert(options.source==self.close_face);self.close_controller=value;value.service.task_options.zone=trial.time_zone
            local make_plan=value._plan
            value._plan=function(active,job,metadata)
                assert(counters[30]==1 and C.valid(metadata) and P.equal(metadata.before,plan.baseline))
                if not trial.bind_percent then plan.target.raw_percent=metadata.desired.raw_percent end
                assert(P.equal(metadata.desired,plan.target) and metadata.desired.raw_percent==legacy.percent)
                self.metadata=clone(metadata);rpc('plan',1,{metadata=metadata,reader_percent=legacy.percent})
                self.report.source_plan=true;return make_plan(active,job,metadata)
            end
            return value
        end
        local config=plugin.settings:get('sync');config.upload_on_close=true;config.upload_interval_minutes=0;plugin.settings:set('sync',config)
        reader:onClose(false);self.closed=true;counters[30]=1;self.report.document_closed=true
        pump(function() return self.close_face and self.close_face.worker and self.close_face.worker.job end)
        self.report.archive_worker=true
        pump(function() return not sync.uploading end)
        Face.new,Native.new=self.face_factory,self.native_factory
        local service=self.close_controller.service
        assert(counters[31]==0);self.report.no_closed_document_calls=true
        if not trial.armed then
            assert(counters[24]==0 and counters[26]==1 and service:pending().phase=='pending')
            assert(plugin.settings:get_book(input.book_id).pending_upload_position)
            self.report.dispatch_blocked=true;self.report.phase='complete';return
        end
        local saved=plugin.settings:get_book(input.book_id)
        assert(counters[24]==1 and counters[29]==1 and not service:pending()
            and saved.last_uploaded_position.wire_basis=='raw_txt_utf16' and not saved.pending_upload_position
            and saved.last_uploaded_position.source_position.chapter_offset==plan.target.chapter_offset
            and not saved.last_uploaded_position.summary and not saved.last_remote_position.summary)
        self.report.local_commit=true;rpc('verified',1);self.report.steps=1
        self.report.phase='restore';counters[27]=2
        -- The original viewport cannot be consulted after close. Reopen the
        -- frozen archive independently and bind a fresh primitive-only proof.
        restore_input.percent=legacy.percent
        local face=self.face_factory(Face,{source=source,input=restore_input,expected=expected,access=access,
            account_scope=account,get_catalog=plugin.source_close.get_catalog,deadline=os.time()+35,
            is_current=function() return self.closed and counters[30]==1 end})
        self.restore_face=face
        local candidate,receipt,done
        face:prepare_current_native_preview(function(value,_why,checked) candidate,receipt,done=value,checked,true end)
        pump(function() return done end)
        assert(candidate and receipt and candidate.chapter_offset==plan.baseline.chapter_offset
            and face:is_current_native_preview(receipt,candidate));self.report.restore_source=true
        local metadata=clone(self.metadata);metadata.before,metadata.desired=clone(plan.target),clone(plan.baseline)
        metadata.file_id=restore_input.target.file_id;restore_service=service
        local function guard()
            assert(tonumber(ffi.C.getpid())==parent,'close_trial/restore_guard_in_child')
            return self.closed and counters[30]==1 and face:is_current_native_preview(receipt,candidate)
                and face:current().chapter_offset==plan.baseline.chapter_offset
        end
        local result,token,finished
        assert(restore_service:start(metadata,guard,function(value,handle) result,token,finished=value,handle,true end))
        pump(function() return finished end)
        assert(result.kind=='confirmed' and result.acknowledged and token and restore_service:pending().phase=='verified')
        rpc('verified',2);assert(restore_service:accept(token));self.report.steps=2
        assert(counters[24]==2 and counters[29]==2 and face:current().chapter_offset==plan.baseline.chapter_offset)
        assert(counters[31]==0);self.report.no_closed_document_calls=true
        self.report.phase='complete'
    end
    function case:audit(filename,content)
        if filename:match('/settings/weread%.lua$') then
            assert(not content:find(plan.baseline.summary,1,true) and not content:find(plan.target.summary,1,true))
        end
    end
    function case:finish(reason)
        if self.Face then self.Face.new=self.face_factory;self.Native.new=self.native_factory end
        if self.restore_face then self.restore_face:cancel_upload_preview() end
        if self.original_credentials then require('weread.lib.native_credentials').new=self.original_credentials end
        if restore_service then restore_service:cancel() end
        self.report.no_closed_document_calls=self.closed==true and counters[31]==0
        self.report.native_gets,self.report.native_posts,self.report.native_denied=tonumber(counters[23]),tonumber(counters[24]),tonumber(counters[25])
        self.report.blocked_posts,self.report.last_native_status,self.report.acknowledged=tonumber(counters[26]),tonumber(counters[28]),tonumber(counters[29])
        self.report.sqlite_before_posts=(trial.armed and counters[24]==2 or not trial.armed and counters[26]==1) and counters[25]==0
        self.report.failed_line=tonumber(type(reason)=='string' and reason:match('owner_native_close_trial_case%.lua:(%d+):')) or 0
    end
    function case:private() return nil end
    return case
end
