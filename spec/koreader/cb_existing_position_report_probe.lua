-- Isolated real HTTPS sender: private input via pipe, fixed result only.
require('ffi').log=function() end
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-cb-native-position-probe.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local Json=require('json')
local sends,reads,synthetic=0,0,false
local ok,result=pcall(function()
    local raw=io.stdin:read(65537);assert(#raw<=65536)
    local input=Json.decode(raw)
    synthetic=type(input)=='table' and input.synthetic==true
    assert(type(input)=='table' and (input.mode=='both' or input.mode=='report') and type(input.cookies)=='table')
    local pos=input.position;local book=input.context
    if input.synthetic==true then
        local fixtures=assert(debug.getinfo(1,'S').source:match('^@(.*/)'))
        assert(dofile(fixtures..'offline_network_guard.lua')())
    end
    assert(type(pos)=='table' and type(book)=='table')
    local Settings={get=function(_self,key,default) if key=='cookies' then return input.cookies end;return default end}
    local Client=require('weread.lib.client');local client=Client:new(Settings)
    local Protocol=require('weread.lib.protocol');local Payload=require('weread.lib.cb_position_payload')
    local request=client.request
    function client:request(options)
        assert(options.sensitive==true and not options.skip_cookie)
        if options.url=='https://weread.qq.com/web/book/read' then
            assert(options.method=='POST' and sends<(input.mode=='both' and 2 or 1) and type(options.body)=='string')
            local body=self:json_decode(options.body)
            local kind=input.mode=='both' and sends==0 and 'enter' or 'position'
            local now=os.time();assert(type(body.ct)=='number' and body.ct<=now and now-body.ct<=30)
            local spec={book_id=pos.book_id,chapter_uid=pos.chapter_uid,chapter_idx=pos.chapter_idx,
                chapter_offset=pos.chapter_offset,progress=pos.percent,summary=pos.summary,
                psvts=book.psvts,pclts=book.pclts,token=book.token,now=body.ct}
            if kind=='position' then spec.ts,spec.rn=body.ts,body.rn end
            local expected=Payload.build(kind,spec)
            for key,value in pairs(body) do assert(expected[key]==value) end
            for key,value in pairs(expected) do assert(body[key]==value) end
            sends=sends+1
        else
            local prefix='https://weread.qq.com/web/book/getProgress?bookId='..Protocol.urlencode(pos.book_id)..'&_='
            assert(options.method=='GET' and not options.body and options.url:sub(1,#prefix)==prefix
                and options.url:sub(#prefix+1):match('^%d+$') and reads==0)
            reads=reads+1
        end
        if input.synthetic==true then
            if options.method=='POST' then return self:json_encode({succ=1}),200,{} end
            return self:json_encode({book={bookId=pos.book_id,chapterUid=tonumber(pos.chapter_uid),
                chapterIdx=pos.chapter_idx,chapterOffset=pos.chapter_offset,progress=pos.percent,summary=pos.summary}}),200,{}
        end
        options.persist_response_cookies=false
        return request(self,options)
    end
    local Report=require('weread.lib.read_report')
    local report=Report:new{settings=Settings,client=client,scheduler={scheduleIn=function() end,unschedule=function() end},
        get_document=function() return {} end,detect_book=function() return pos.book_id end,subprocess=false}
    report._auth_fingerprint=function() return 'scoped-test' end
    report.ensure_context=function()
        local value={};for key,item in pairs(book) do value[key]=item end
        if input.mode=='report' then value.read_session_id=report.session_id;value.read_session_entered_at=1 end
        return value
    end
    report._persist_context=function() end
    local plan={position=pos,source_position={book_id=pos.book_id,chapter_uid=pos.chapter_uid,chapter_offset=pos.chapter_offset,
        basis='filtered_xhtml_utf16',upload_verified=false},basis='filtered_xhtml_utf16',transport='cb_web_position',
        is_current=function() return true end,before_send=function() return true end}
    local accepted,outcome=report:upload_cb_position(pos.book_id,pos,plan)
    return {accepted=accepted==true,acknowledged=outcome.acknowledged==true,confirmed=outcome.position_confirmed==true,
        writes=sends,reads=reads,enter_attempted=outcome.enter_attempted==true,report_attempted=outcome.report_attempted==true}
end)
if not ok and synthetic then io.stderr:write(tostring(result),'\n') end
if not ok then result={accepted=false,acknowledged=false,confirmed=false,writes=sends,reads=reads,
    failure_line=tonumber(type(result)=='string' and result:match('cb_existing_position_report_probe%.lua:(%d+):')) or 0} end
print('\nWEREAD_CB_EXISTING_NATIVE_REPORT='..Json.encode(result))
os.exit(ok and result.accepted and 0 or 1)
