-- Stock native reader + actual HTTP executor. The mock endpoint is mandatory;
-- nothing here loads the owner's Keychain or can fall back to an upstream API.
return function(reader, plugin, pump, clean_popups)
    assert(plugin.settings.mock_endpoint and plugin.settings.mock_endpoint:match("^http://127%.0%.0%.1:%d+$"))
    local Json, HTTP, LTN = require("json"),require("socket.http"),require("ltn12")
    local UI = require("ui/uimanager")
    local input_file=assert(io.open(assert(os.getenv("WEREAD_TEST_OWNER_ROUNDTRIP")),"rb"))
    local input=Json.decode(input_file:read("*a"));input_file:close()
    local Source=require("weread.lib.position_source")
    local origin
    pump(function() origin=plugin.source_position:current();return origin~=nil end)
    local source_index=assert(require("weread.lib.source_dom").open(reader.document,input.book_id,input.chapter_uid))
    local factory=dofile(debug.getinfo(1,"S").source:match("^@(.*/)") .. "owner_progress_roundtrip_case.lua")
    local function request(path,data)
        local chunks,raw={},data and Json.encode(data)
        local _,code=HTTP.request{url=plugin.settings.mock_endpoint..path,proxy=plugin.settings.mock_endpoint,
            method=raw and "POST" or "GET",source=raw and LTN.source.string(raw),
            headers=raw and {["Content-Type"]="application/json",["Content-Length"]=tostring(#raw)} or {},sink=LTN.sink.table(chunks)}
        assert(code==200);return Json.decode(table.concat(chunks))
    end
    local function posts()
        local count=0
        for _i,row in ipairs(request("/__state").totals) do
            assert(row.path~="/web/login/renewal","executor renewed a Web grant")
            if row.path=="/web/book/read" then count=count+row.count end
        end
        return count
    end
    local results=Json.decode("[]")
    for index,mode in ipairs({"plain","probe-noack","restore-noack","probe-rejected","concurrent"}) do
        clean_popups(reader)
        request("/__control",{progress_roundtrip_mode=mode=="probe-rejected" and "plain" or mode,
            times=mode=="probe-rejected" and 1 or 0,skip=mode=="probe-rejected" and 2 or 0,
            match=mode=="probe-rejected" and "/web/book/read" or "",status=503})
        plugin.read_report.session_id="synthetic-roundtrip-session-"..index
        local counters=require("ffi").new("int[1024]")
        local case=factory(input,counters)
        local original=plugin.client.request
        plugin.client.request=function(client,options)
            if case:is_write(options) then return case:request(client,options,original) end
            return original(client,options)
        end
        case:install_guard()
        local before=posts()
        case:run(plugin,reader,pump,source_index,origin);case:finish()
        plugin.client.request=original
        local report=case.report
        local expected=(mode=="concurrent" or mode=="probe-rejected") and 3 or 4
        assert(report.posts_attempted==expected and posts()==before+expected,"executor repeated or exceeded its POST sequence")
        assert(report.reader_position_restored and report.source_upload_gate_preserved and report.source_points_verified,
            "executor lost native source scope or local restoration")
        assert(report.synthetic_acknowledgements==0,"executor manufactured a successful reply")
        if mode=="plain" then assert(report.result=="PASS" and report.safe_resolution and report.probe_confirmed)
        elseif mode=="probe-noack" or mode=="restore-noack" then
            assert(report.result=="UNVERIFIED" and report.restoration_verified and report.safe_resolution,"known restoration not verified")
        elseif mode=="probe-rejected" then
            assert(report.result=="UNVERIFIED" and report.restoration_verified and not report.safe_resolution and not report.probe_seen,
                "unobserved probe was incorrectly resolved by unchanged baseline")
        else
            assert(report.unrelated_position_seen and not report.restoration_verified and not report.safe_resolution,
                "unrelated cloud position was restored or resolved")
        end
        results[#results+1]={mode=mode,result=report.result,posts_attempted=report.posts_attempted,
            restoration_verified=report.restoration_verified,safe_resolution=report.safe_resolution,
            probe_seen=report.probe_seen,unrelated_position_seen=report.unrelated_position_seen}
        assert(Source.document_metadata(reader.document,input.book_id,input.chapter_uid).record.raw_sha256==input.source_raw_sha256)
    end
    request("/__control",{progress_roundtrip_mode="plain",match="",times=0,skip=0})
    UI:forceRePaint()
    local out=assert(io.open(assert(os.getenv("WEREAD_EVIDENCE")).."/owner-roundtrip-executor-result.json","wb"))
    out:write(Json.encode{result="PASS",synthetic_only=true,real_account_data_writes_attempted=0,authorization_posts=0,
        automatic_write_retries=0,cases=results});out:close()
end
