-- Live preflight uses private memory pipes and an in-memory archive fixture.
require('jit').off()
require('ffi').log=function() end
require('setupkoenv')
G_reader_settings=require('luasettings'):wrap({})
G_defaults=require('luadefaults'):open()
package.loaded['weread.lib.logger']={info=function() end,warn=function() end,err=function() end,dbg=function() end}
package.path=assert(arg[1])..'/?.lua;'..package.path
local json=require('json')
local native_count,web_count=0,0
local good,result=pcall(function()
    local raw=assert(io.stdin:read(3*1024*1024+1));assert(#raw<=3*1024*1024)
    local input=json.decode(raw)
    local cookies=input.cookies
    local scope={vid=input.credentials.vid,epoch=1}
    local settings={get=function(_self,key,default) if key=='cookies' then return cookies end;return default end,
        merge_set_cookie=function(_self,value) cookies=require('weread.lib.cookie').merge_set_cookie(cookies,value) end,
        get_auth_scope=function() return scope end,auth_scope_matches=function(_self,value) return value==scope end}
    local store={read=function() return input.credentials,1,nil,false end}
    local client=require('weread.lib.client'):new(settings)
    local request=client.request
    client.request=function(self,options)
        if options.url:match('^https://i%.weread%.qq%.com/') then
            native_count=native_count+1;assert(native_count<=(input.task and 16 or 12) and options.skip_cookie)
            local base='https://i.weread.qq.com'
            if options.url==base..'/pay/memberCardSummary?pf=wechat_wx-2001-android-100-weread'
                or options.url==base..'/book/info?bookId='..input.book_id
                or input.task and (options.url==base..'/book/getProgress?bookId='..input.book_id or options.url==base..'/shelf/sync') then
                assert(options.method=='GET' and options.body==nil)
            else
                assert(options.url==base..'/book/chapterInfos' and options.method=='POST')
                local body=json.decode(options.body)
                assert(body.bookIds[1]==input.book_id and #body.bookIds==1 and body.synckeys[1]==0
                    and body.updateTimes[1]==0 and body.maxfreeIdx[1]==0)
            end
        else
            web_count=web_count+1;assert(web_count<=32 and options.url:match('^https://weread%.qq%.com/'))
            local reader=options.url:match('^https://weread%.qq%.com/web/reader/')
            local progress=options.url:match('^https://weread%.qq%.com/web/book/getProgress%?')
            local shelf=options.url=='https://weread.qq.com/web/shelf/sync'
            local catalog=options.url=='https://weread.qq.com/web/book/chapterInfos'
            local shard=options.url:match('^https://weread%.qq%.com/web/book/chapter/e_[0-3]$')
            assert((reader or input.task and (progress or shelf)) and options.method=='GET' and not options.body
                or (catalog or shard) and options.method=='POST')
        end
        return request(self,options)
    end
    local selected=assert(require('weread.lib.native_read_access').capture(settings,store))
    local Source=require('weread.lib.position_source')
    local Identity=require('weread.lib.book_file_identity')
    local Crypto=require('weread.lib.crypto')
    local book={book_id=input.book_id,bookVersion=input.version}
    local identity_raw=Identity.encode(book,{{chapterUid=input.uid}},Identity.capture(book),Crypto.sha256_hex(input.source))
    local identity=assert(Identity.decode(identity_raw))
    local source=assert(Source.capture(book,{chapterUid=input.uid},input.source,'web_xhtml'))
    local meta=assert(Source.bind(source,identity,'OEBPS/text/chapter.xhtml',Crypto.sha256_hex(input.source)))
    local values={[Identity.PATH]=identity_raw,[Source.meta_path(input.uid)]=meta,
        [Source.raw_path(source.raw_sha256)]=input.source,['OEBPS/text/chapter.xhtml']=input.source}
    package.loaded['weread.lib.source_archive']={read=function(_path,wanted)
        local entries={};for name in pairs(wanted) do assert(values[name]);entries[name]=values[name] end;return entries
    end}
    local target={book_id=input.book_id,chapter_uid=input.uid,path='/memory-fixture.epub',metadata=meta,file_id=identity.file_id}
    local options={is_current=function() return true end}
    local result,reason
    if input.task then
        local web=assert(require('weread.lib.read_access').capture(settings))
        result=require('weread.lib.translation_generation_task').run(client,settings,selected,web,target,{},options)
    else result,reason=require('weread.lib.translation_generation_source').inspect(client,settings,selected,target,options) end
    return {kind=result and result.kind or 'unavailable',reason=reason,native_reads=native_count,web_reads=web_count,cookies=cookies,
        mode_attempted=result and result.mode_attempted,generation_attempted=result and result.generation_attempted}

end)
io.write('\nTRANSLATION_SOURCE='..json.encode(good and result or {kind='error',native_reads=native_count,web_reads=web_count})..'\n')
io.flush();os.exit(good and 0 or 1)
