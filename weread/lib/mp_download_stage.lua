-- One exclusive generation per attempt. The parent alone publishes article.html.
local Identity=require('weread.lib.mp_cache_identity')
local Output=require('weread.lib.notes_export_file')
local Crypto=require('weread.lib.crypto')
local Versions=require('weread.lib.mp_cache_versions')
local M={MAX_HTML=4*1024*1024,MAX_IMAGE=32*1024*1024,MAX_IMAGES=256,MAX_TOTAL=64*1024*1024}
M.__index=M
local serial=0
local function same(a,b)
    return a and b and a.mode==b.mode and a.dev==b.dev and a.ino==b.ino
end
local function unchanged(a,b)
    return not a and not b or same(a,b) and a.size==b.size and a.modification==b.modification
end
local function create_locked(root,key,options,path,unleased,holder)
    local lfs=require('libs/libkoreader-lfs')
    local snapshot=Versions.capture(root,key);if not snapshot then return nil end
    -- Once a selector exists, subsequent downloads must preserve its version too.
    local preserve=options and options.preserve or snapshot.selector.name~=nil
    if preserve then local entries=Versions.list(root,key);if not entries or #entries>=Versions.MAX_VERSIONS then return nil end end
    local previous=lfs.symlinkattributes(path)
    if previous and previous.mode~='file' then return nil end
    local parent=path:match('^(.*)/[^/]+$')
    local owner=lfs.symlinkattributes(parent)
    for _i=1,32 do
        serial=serial+1
        local nonce=Crypto.sha256_hex(key..os.time()..os.clock()..tostring({})..serial):sub(1,16)
        local name='.mp-pending-'..nonce
        local directory=parent..'/'..name
        if lfs.mkdir(directory) then
            local ffi=require('ffi');require('ffi/posix_h')
            pcall(ffi.cdef,'int chmod(const char *path, unsigned int mode);')
            ffi.C.chmod(directory,448) -- 0700; FAT may ignore permissions.
            local job=setmetatable({root=root,key=key,path=path,parent=parent,parent_identity=owner,
                previous=previous,directory=directory,identity=lfs.symlinkattributes(directory),lfs=lfs,
                version_snapshot=snapshot,preserve=preserve,version_name='article-'..nonce..'.html',
                generation='.weread-mp-'..key..'-assets-'..nonce},M)
            holder.job=job
            if not lfs.mkdir(directory..'/images') then job:cleanup();return nil end
            job.images_identity=lfs.symlinkattributes(directory..'/images')
            local created,output=pcall(Output.create,directory,'body','html')
            job.output=created and output or nil
            if not job.output then job:cleanup();return nil end
            if not unleased then
                job.lease=require('weread.lib.mp_download_recovery').create(job,nonce)
                if not job.lease then job:cleanup();return nil end
            end
            return job
        end
    end
end
function M.create(root,key,options)
    local cleanup=require('weread.lib.mp_cache_cleanup')
    if cleanup.locked(root,key) then return nil end
    local path=Identity.prepare(root,key);if not path then return nil end
    local gate,reason=cleanup.acquire(root,key)
    if not gate and reason~='unsupported' then return nil end
    local holder={}
    local ok,job=pcall(create_locked,root,key,options,path,not gate,holder)
    if not ok and holder.job then pcall(holder.job.cleanup,holder.job) end
    if gate then gate:release() end
    return ok and job or nil
end
function M:owns()
    return same(self.parent_identity,self.lfs.symlinkattributes(self.parent))
        and same(self.identity,self.lfs.symlinkattributes(self.directory))
        and self.lfs.symlinkattributes(self.root..'/mp-articles','mode')=='directory'
end
function M:images_owned()
    return self:owns() and same(self.images_identity,self.lfs.symlinkattributes(self.directory..'/images'))
end
function M:same_target(other)
    return type(other)=='table' and self.path==other.path and same(self.parent_identity,other.parent_identity)
        and unchanged(self.previous,other.previous) and self.preserve==other.preserve
        and self.version_snapshot.path==other.version_snapshot.path
        and unchanged(self.version_snapshot.info,other.version_snapshot.info)
        and self.version_snapshot.selector.raw==other.version_snapshot.selector.raw
end
function M:close()
    if self.output then self.output:close() end
end
function M:release_lease(remove)
    if self.lease then
        if remove then self.lease:remove() end
        self.lease:release();self.lease=nil
    end
end
-- Call only after the child has stopped. Never follow a replaced directory or
-- remove a replacement body file. Unknown files are left for manual inspection.
function M:cleanup()
    self:close()
    if self.committed or self.published and Versions.points_to(self.root,self.key,self.version_name) then self:release_lease(true);return end
    if not self:owns() then self:release_lease(false);return end
    if self.published and unchanged(self.published,self.lfs.symlinkattributes(self.parent..'/'..self.version_name)) then
        os.remove(self.parent..'/'..self.version_name)
    end
    if self:images_owned() then
        local inspected=0
        for name in self.lfs.dir(self.directory..'/images') do
            inspected=inspected+1;if inspected>M.MAX_IMAGES*2+4 then break end
            if name:match('^img%-%d%d%d%d%.[a-z]+$') or name:match('^bitmap%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%.html$') then
                local path=self.directory..'/images/'..name
                if self.lfs.symlinkattributes(path,'mode')~='directory' then os.remove(path) end
            end
        end
        self.lfs.rmdir(self.directory..'/images')
    end
    if self.output then self.output:abort();self.output=nil end
    local removed=self.lfs.rmdir(self.directory)
    self:release_lease(removed or not self.lfs.symlinkattributes(self.directory))
end
local function integer(value,max)
    return type(value)=='number' and value>=0 and value<=max and value%1==0
end
function M:commit(result)
    if type(result)~='table' or result.ok~=true or not integer(result.bytes,M.MAX_HTML) or result.bytes<1
        or not integer(result.images,M.MAX_IMAGES) or not integer(result.image_bytes,M.MAX_TOTAL)
        or not self:images_owned() or not unchanged(self.previous,self.lfs.symlinkattributes(self.path))
        or not Versions.matches(self.version_snapshot) then return nil end
    local count,total=0,0
    for name in self.lfs.dir(self.directory..'/images') do
        if name~='.' and name~='..' then
            if not name:match('^img%-%d%d%d%d%.png$') and not name:match('^img%-%d%d%d%d%.jpg$')
                and not name:match('^img%-%d%d%d%d%.gif$') and not name:match('^img%-%d%d%d%d%.webp$') then return nil end
            local info=self.lfs.symlinkattributes(self.directory..'/images/'..name)
            if not info or info.mode~='file' or info.size<1 or info.size>M.MAX_IMAGE then return nil end
            count=count+1;total=total+info.size
            if count>M.MAX_IMAGES or total>M.MAX_TOTAL then return nil end
        end
    end
    if count~=result.images or total~=result.image_bytes or not self.output:sync()
        or not self.output:accept(result.bytes) then return nil end
    local file=io.open(self.output.path,'rb');if not file then return nil end
    local head=file:read(4096) or '';file:close()
    if not head:find(Identity.marker(self.key),1,true) then return nil end
    local destination=self.parent..'/'..self.generation
    if self.lfs.symlinkattributes(destination) then return nil end
    local target=self.preserve and self.parent..'/'..self.version_name or self.path
    if self.preserve and self.lfs.symlinkattributes(target) then return nil end
    local basename=self.output.path:match('[^/]+$')
    if not os.rename(self.directory,destination) then return nil end
    self.directory=destination;self.output.path=destination..'/'..basename
    if not self:owns() or not unchanged(self.previous,self.lfs.symlinkattributes(self.path))
        or not Versions.matches(self.version_snapshot) or not os.rename(self.output.path,target) then return nil end
    self.output=nil
    if self.preserve then
        self.published=self.lfs.symlinkattributes(target)
        if not Versions.publish(self.version_snapshot,self.version_name) then return nil end
    end
    self.committed=true
    self:release_lease(true)
    -- Retain prior generations: an already-open CRE document may still use them.
    return target
end
return M
