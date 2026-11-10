-- Close an actual native document, then finish only against mock HTTP.
return function(reader,plugin,pump,clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match('^http://127%.0%.0%.1:%d+$'))
    local Json=require('json')
    local id=assert(plugin:detectWeReadBook())
    clean_popups(reader)
    assert(plugin.progress_sync.verified and not plugin.source_dispatch:pending(id))
    local config=plugin.settings:get('sync');config.upload_on_close=true;plugin.settings:set('sync',config)
    reader.rolling:onGotoPage(reader:getCurrentPage()==1 and 2 or 1)
    pump(function() return plugin.source_position:current()~=nil end)
    local point=assert(plugin.source_position:current())
    local candidate
    plugin.source_position:prepare_upload_preview(function(value) candidate=value end)
    pump(function() return candidate~=nil end)
    assert(candidate.chapter_offset==point.chapter_offset and candidate.summary)
    assert(plugin.progress_sync.dirty,'native movement did not mark close intent dirty')
    local checkpoint={path=reader.document.file,xpointer=reader.document:getXPointer(),page=reader:getCurrentPage(),chapter_uid=point.chapter_uid}
    local closed,posts,reads=false,0,0
    local recover=os.getenv('WEREAD_TEST_SOURCE_RECOVERY')=='1'
    local function mock_request(path,data)
        local HTTP,LTN=require('socket.http'),require('ltn12')
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and 'POST' or 'GET',source=raw and LTN.source.string(raw),
            headers=raw and {['Content-Type']='application/json',['Content-Length']=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function renewals()
        local total=0
        for _i,row in ipairs(mock_request('/__state').totals) do if row.path=='/web/login/renewal' then total=total+row.count end end
        return total
    end
    local auth_before=recover and renewals()
    if recover then mock_request('/__control',{match='/web/book/chapter/e_0',times=1,status=401,web_renewal_mode='rotate'}) end
    local original=plugin.client.request
    function plugin.client:request(options)
        if options.url=='https://weread.qq.com/web/book/read' then
            assert(closed,'close upload did not wait for independent source preparation')
            assert(plugin.source_dispatch:pending(id),'close upload sent without a durable journal')
            local body=Json.decode(options.body)
            assert(body.co==candidate.chapter_offset and body.ci==candidate.chapter_idx and body.sm==candidate.summary and body.rt==0,
                'close report did not use its frozen source point and zero duration')
            posts=posts+1
        elseif closed and options.url:find('/web/book/getProgress',1,true) then reads=reads+1 end
        return original(self,options)
    end
    local document=reader.document
    for _i,name in ipairs({'getDocumentFileContent','getHTMLFromXPointers','getTextFromXPointers','getNextVisibleChar',
        'getPrevVisibleChar','getXPointer','getCurrentPage','getPageCount'}) do
        local method=document[name]
        document[name]=function(self,...)
            assert(not closed,'close preparation touched a destroyed native document: '..name)
            return method(self,...)
        end
    end
    reader:onClose(false);closed=true
    pump(function() return not plugin.progress_sync.uploading end)
    local saved=plugin.settings:get_book(id)
    assert(posts==1 and reads>=1,'closed document did not complete one report and independent readback')
    assert(not saved.pending_upload_position and not saved.source_dispatch,'confirmed close retained stale pending state')
    assert(saved.last_uploaded_position.chapter_offset==point.chapter_offset and saved.last_uploaded_position.chapter_uid==point.chapter_uid
        and saved.last_uploaded_position.wire_basis=='filtered_xhtml_utf16' and not saved.last_uploaded_position.summary)
    if recover then assert(renewals()==auth_before+1,'closed source recovery renewed more than once') end
    plugin.client.request=original
    local file=assert(io.open(assert(os.getenv('WEREAD_EVIDENCE'))..'/source-close-result.json','wb'))
    file:write(Json.encode{result='PASS',synthetic_only=true,actual_native_document_closed=true,
        independent_source_preparation=true,no_closed_native_document_calls=true,source_wire_and_summary=true,
        durable_dispatch_before_http=true,report_posts=posts,position_readback_gets=reads,elapsed_seconds=0,
        closed_401_recovered=recover,mock_authentication_posts=recover and 1 or 0,
        real_account_data_writes_attempted=0});file:close()
    return checkpoint
end
