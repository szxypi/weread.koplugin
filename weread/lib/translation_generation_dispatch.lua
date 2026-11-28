-- One native translation operation after fresh source/baseline revalidation.
-- Both the mode GET and generation POST consume a durable claim before I/O.
-- This module neither prepares plans nor supplies source/baseline authority.
local Model=require('weread.lib.translation_generation')
local Wire=require('weread.lib.translation_generation_wire')
local Native=require('weread.lib.native_read_access')
local Position=require('weread.lib.native_position_protocol')
local Protocol=require('weread.lib.protocol')
local M={}
local BASE='https://i.weread.qq.com'
local function hash(value) return type(value)=='string' and #value==64 and value:match('^[a-f0-9]+$')~=nil end
local function current(settings,selected,plan,options)
    if not selected or selected.renewal_pending or not selected.scope or not Position.credentials(selected.credentials)
        or selected.scope.vid~=plan.owner or selected.credentials.vid~=plan.owner or selected.fingerprint~=plan.grant_sha256
        or not Native.matches(settings,selected) or type(options.is_current)~='function' then return false end
    local ok,value=pcall(options.is_current);return ok and value==true
end
local function evidence(witness,baseline,plan)
    return type(witness)=='table' and witness.kind=='source_verified' and witness.book_id==plan.book_id
        and witness.chapter_uid==tostring(plan.chapter_uid) and witness.source_sha256==plan.source_sha256
        and witness.catalog_sha256==plan.catalog_sha256 and witness.version==plan.book_version
        and witness.translate_version==plan.translate_version and hash(witness.file_id)
        and hash(baseline) and baseline==plan.baseline_sha256
end
local function headers(credentials)
    return {baseapi='30',appver='2.1.2.10245900',basever='2.1.2.10245900',osver='11',channelId='900',
        Accept='application/json', ['User-Agent']='WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)',
        vid=credentials.vid,accessToken=credentials.accessToken}
end
function M.send_once(client,settings,selected,plan,journal,operation,options)
    local out={kind='unavailable',attempted=false}
    if not Model.valid(plan) or type(options)~='table' or type(options.recheck)~='function'
        or type(journal)~='table' or operation~='mode' and operation~='generation' then return out end
    local ok=pcall(function()
        local function owns() return current(settings,selected,plan,options) end
        assert(owns(),'translation_dispatch/stale')
        local witness,baseline=options.recheck()
        assert(owns() and evidence(witness,baseline,plan),'translation_dispatch/changed')
        local url,body,method=BASE..'/trans/pdfepub?cbid='..Protocol.urlencode(plan.book_id)
            ..'&transFormat=epubTranslate&transType=epubTranslate',nil,'GET'
        local request_headers=headers(selected.credentials)
        if operation=='generation' then
            local value=assert(Model.generation_body(plan,client))
            body=client:json_encode(value)
            assert(type(body)=='string' and #body<=16384 and body:match('"texts"%s*:%s*%[%s*%]'),'translation_dispatch/encoding')
            url,method=BASE..'/en/bookread','POST';request_headers['Content-Type']='application/json'
        end
        assert(owns(),'translation_dispatch/stale')
        local claimed=operation=='mode' and journal:claim_mode(plan) or operation=='generation' and journal:claim_generation(plan)
        assert(claimed,'translation_dispatch/claim')
        -- A cancellation or session change after commit still consumes the
        -- claim; it must not trigger a second request after a restart.
        assert(owns(),'translation_dispatch/stale')
        local chunks,size,overflow={},0,false
        out.attempted=true;out.kind='unconfirmed'
        local success,response,code=pcall(client.request,client,{url=url,method=method,body=body,headers=request_headers,
            skip_cookie=true,persist_response_cookies=false,sensitive=true,diagnostic_api='translation_generation_'..operation,
            timeout={8,20},sink=function(chunk)
                if chunk~=nil then
                    if type(chunk)~='string' then overflow=true;return nil,'invalid_response' end
                    size=size+#chunk
                    if size>Wire.MAX_BYTES then overflow=true;return nil,'response_limit' end
                    chunks[#chunks+1]=chunk
                end
                return 1
            end})
        if not success or response~=nil or tonumber(code)~=200 or overflow or not owns() then return end
        local parsed=Wire.decode(table.concat(chunks));if not parsed then return end
        local wire={http_status=200,body_truncated=false}
        if operation=='mode' then
            if journal:record_mode(plan,parsed,wire) then out.kind='mode_confirmed' end
        else
            local state=journal:record_status(plan,parsed,wire)
            if state then out.kind=state.result end
        end
    end)
    if not ok and not out.attempted then out.kind='unavailable' end
    return out
end
return M
