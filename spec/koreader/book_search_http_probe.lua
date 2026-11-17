-- Credentials and returned snippets exist only on the private input pipe.
-- Output is limited to fixed result flags and counts.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/weread-book-search-probe-settings.lua')
local Device=require('device')
require('document/canvascontext'):init(Device)
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local Protocol=require('weread.lib.protocol')
local Search=require('weread.lib.book_search')
local bytes=io.stdin:read(8*1024*1024+1)
local phase='decode'
local ok,result=pcall(function()
    assert(#bytes<=8*1024*1024)
    local input=json.decode(bytes);bytes=nil
    local state,reason=Search.new(input.book,input.keyword,input.chapters,input.first)
    if not state then return {result='UNVERIFIED',reason=reason} end
    phase='settings'
    local settings={cookies=input.cookies}
    function settings:get(key,default) if key=='cookies' then return self.cookies end;return default end
    function settings:get_auth_scope() return {vid=self.cookies.wr_vid,epoch=1} end
    function settings:auth_scope_matches(scope) return scope and scope.vid==self.cookies.wr_vid and scope.epoch==1 end
    phase='client'
    local client=require('weread.lib.client'):new(settings)
    local request=client.request;local calls=0
    function client:request(options)
        calls=calls+1
        local expected=calls==1 and 'https://weread.qq.com/api/userInfo?userVid='..Protocol.urlencode(input.cookies.wr_vid)
            or calls==2 and Search.url(state)
        assert(expected and options.url==expected and options.method=='GET' and options.sensitive
            and options.skip_cookie and options.persist_response_cookies==false)
        return request(self,options)
    end
    phase='fetch'
    local page,err=Search.fetch(client,state)
    if not page then return {result='UNVERIFIED',reason=err,requests=calls} end
    local keys,unverified={},true
    for _i,hit in ipairs(page.hits) do
        keys[#keys+1]=hit.chapter_uid..':'..string.format('%.0f',hit.start)..':'..string.format('%.0f',hit.finish)
        unverified=unverified and hit.source_verified==false
    end
    table.sort(keys);table.sort(input.expected_keys)
    local matches=#keys==#input.expected_keys
    if matches then for i,key in ipairs(keys) do if key~=input.expected_keys[i] then matches=false;break end end end
    return {result='PASS',requests=calls,hits=#keys,independent_results_match=matches,candidates_unverified=unverified}
end)
print('\nWEREAD_BOOK_SEARCH_HTTP='..json.encode(ok and result or {result='UNVERIFIED',reason='probe_failed',phase=phase}))
os.exit(ok and result.result=='PASS' and result.requests==2 and result.independent_results_match
    and result.candidates_unverified and 0 or 1)
