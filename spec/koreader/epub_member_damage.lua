-- Repack synthetic content with a sound ZIP directory. Omit the selected
-- member or change its stored bytes without updating the entry checksum.
return function(source,target,member,omit)
    local Archiver=require('ffi/archiver')
    local zip,writer=Archiver.Reader:new(),Archiver.Writer:new{}
    assert(zip:open(source));assert(writer:open(target,'epub'));assert(writer:setZipCompression('store'))
    local body
    for entry in zip:iterate() do
        if entry.mode=='file' then
            local bytes=assert(zip:extractToMemory(entry.path))
            if entry.path==member then body=bytes end
            if not omit or entry.path~=member then assert(writer:addFileFromMemory(entry.path,bytes,os.time())) end
        end
    end
    zip:close();writer:close();assert(body and #body>0)
    if not omit then
        local source_file=assert(io.open(target,'rb'))
        local bytes=assert(source_file:read('*a'));assert(source_file:close())
        local at=assert(bytes:find(body,1,true))
        assert(not bytes:find(body,at+1,true))
        local target_file=assert(io.open(target,'wb'))
        assert(target_file:write(bytes:sub(1,at-1)..'!'..bytes:sub(at+1)));assert(target_file:close())
    end
    assert(require('weread.lib.source_archive').epub_container_readable(target),
        'fixture damaged the ZIP directory or container')
end
