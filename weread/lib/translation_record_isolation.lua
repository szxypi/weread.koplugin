-- KOReader may locate EPUB sidecars by path or sampled file hash. Refuse to
-- open a translated copy if any possible record location aliases its source.
local M={}
function M.check(source,target,settings,util,lfs)
    local ok,result=pcall(function()
        if type(source)~='string' or type(target)~='string' or source==target
            or source:find('[%z%c]') or target:find('[%z%c]') then return false end
        settings=settings or require('docsettings')
        util=util or require('util')
        lfs=lfs or require('libs/libkoreader-lfs')
        local first,second=util.partialMD5(source),util.partialMD5(target)
        if type(first)~='string' or first=='' or type(second)~='string' or second=='' or first==second then return false end
        local originals,copies={},{}
        for _,mode in ipairs({'doc','dir','hash'}) do
            local a,b=settings:getSidecarDir(source,mode),settings:getSidecarDir(target,mode)
            if type(a)~='string' or a=='' or type(b)~='string' or b=='' then return false end
            originals[#originals+1]=a;copies[#copies+1]=b
        end
        for _,a in ipairs(originals) do
            local info_a=lfs.attributes(a)
            for _,b in ipairs(copies) do
                if a==b then return false end
                local info_b=lfs.attributes(b)
                if info_a and info_b and info_a.dev~=nil and info_a.ino~=nil
                    and info_a.dev==info_b.dev and info_a.ino==info_b.ino then return false end
            end
        end
        return true
    end)
    return ok and result==true
end
return M
