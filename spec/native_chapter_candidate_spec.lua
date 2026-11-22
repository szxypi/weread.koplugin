package.path = './?.lua;' .. package.path
package.preload.logger=function() return {info=function() end,warn=function() end,err=function() end,dbg=function() end} end
local ok_lfs = pcall(require, 'lfs')
if not ok_lfs then
    local lfs = {
        attributes = function(_, field) if field == 'mode' then return 'directory' end end,
        symlinkattributes = function(path)
            local file = io.open(path, 'rb')
            if file then file:close(); return { mode='file' } end
        end,
    }
    package.loaded['libs/libkoreader-lfs'] = lfs
end
local current, source_reason, remote_reason = true
local source_calls, remote_calls = 0, 0
package.loaded['weread.lib.native_read_access'] = {
    capture=function() return { renewal_pending=false, fingerprint='account-a' } end,
    matches=function() return current end,
}
local body = '<html><body><img src="../images/cover.png"/><p>fixture</p></body></html>'
local image = '\137PNG\r\n\26\nfixture'
local css='html,body{font-size:0;color:black}.hidden{font-size:0}p{color:black}'
local source = { book_id='42', chapter_uid='37', book_version=1, catalog_sha256=string.rep('a',64),
    source_channel='eink', coordinate_source_authoritative=false, is_text=false, body=body, css=css,
    body_parts={{source='text/37.xhtml',data=body}}, style_parts={{source='style/book.css',data=css}},
    assets={{source='images/cover.png',data=image,media_type='image/png'}}, unusable_resources=0 }
package.loaded['weread.lib.native_chapter_source'] = { fetch=function()
    source_calls=source_calls+1
    if source_reason then return nil,source_reason end
    return source
end }
local remote = require('weread.lib.native_chapter_remote')
local real_complete = remote.complete
remote.complete = function(...)
    remote_calls=remote_calls+1
    if remote_reason then return nil,remote_reason end
    return real_complete(...)
end
local Position=require('weread.lib.position_source')
local Candidate=require('weread.lib.native_chapter_candidate')
local book,chapter={book_id='42'},{chapterUid='37'}
local position=assert(Position.capture(book,chapter,body,'web_xhtml'))
local root=os.tmpname();os.remove(root);assert(os.execute('mkdir -p '..string.format('%q',root))==0)
local workspace={asset_dir=root}
local function fetch(web,proof) return Candidate.fetch({}, {}, book, chapter, web or body, proof or position, workspace) end
local result=assert(fetch())
assert(result.xhtml:find('../images/eink-',1,true) and #result.assets==1)
assert(not result.css:match('html,body%s*%{[^}]*font%-size')
    and result.css:find('.hidden{font-size:0}',1,true) and result.css:find('color:black',1,true),
    'native styles must retain the same root font-size protection as Web chapters')
local file=assert(io.open(result.assets[1].path,'rb'));assert(file:read('*a')==image);file:close()
assert(result.assets[1].size==#image and source_calls==1 and remote_calls==1)
assert(not fetch(body..'different') and source_calls==1, 'mismatched Web proof must stop before native request')
source.body=body..'different';assert(not fetch() and remote_calls==1,'different native bytes must fall back before image requests')
source.body=body
source_reason='not_entitled';assert(not fetch());source_reason=nil
remote_reason='native_resources/missing';assert(not fetch());remote_reason=nil
remote_reason='native_resources/source_changed'
local changed,changed_error=pcall(fetch)
assert(not changed and changed_error=='native_candidate/source_changed')
remote_reason=nil
local same,account_error=pcall(Candidate.fetch,{}, {},book,chapter,body,position,workspace,'account-b')
assert(not same and account_error=='native_candidate/session_changed')
for _,reason in ipairs({'rate_limited','auth_expired','service_rejected','session_changed','source_changed'}) do
    source_reason=reason
    local ok,err=pcall(fetch)
    assert(not ok and err==(reason=='rate_limited' and 'download_read/rate_limited' or 'native_candidate/'..reason),reason)
end
source_reason=nil;remote_reason='rate_limited'
local ok,err=pcall(fetch);assert(not ok and err=='download_read/rate_limited')
remote_reason=nil
ok,err=pcall(fetch);assert(not ok and err=='native_candidate/storage','must not overwrite existing staged asset')
os.remove(result.assets[1].path);os.remove(root)
print('PASS: native candidate proof, resources, fallback, stop conditions and staging')
