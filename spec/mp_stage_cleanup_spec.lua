package.path='./?.lua;'..package.path
local state
package.preload['libs/libkoreader-lfs']=function() return {
    symlinkattributes=function(path) if path=='/parent/article-0123456789abcdef.html' then return state.info end end,
    rmdir=function() return true end} end
local Versions=require('weread.lib.mp_cache_versions')
Versions.resolve=function() return state.selected,state.reason end
local Stage=require('weread.lib.mp_download_stage')
local old_remove=os.remove;rawset(os,'remove',function(path) state.removed=path;return true end)
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    state={info={mode='file',dev=1,ino=2,size=40,modification=1}}
    return setmetatable({root='/root',key=string.rep('a',64),parent='/parent',directory='/generation',
        lfs=require('libs/libkoreader-lfs'),
        version_name='article-0123456789abcdef.html',published=state.info,
        owns=function() return true end,images_owned=function() return false end,
        release_lease=function(_self,remove) state.lease_remove=remove end},Stage)
end
local job=fixture();state.reason='invalid';job:cleanup()
expect(not state.removed and state.lease_remove==false,'unreadable selector deleted a possibly selected complete body')
job=fixture();state.selected='/parent/'..job.version_name;state.reason='current';job:cleanup()
expect(not state.removed and state.lease_remove==true,'selected complete body was removed')
for _i,reason in ipairs({'current','none'}) do
    job=fixture();state.selected=reason=='current' and '/parent/other.html' or nil;state.reason=reason;job:cleanup()
    expect(state.removed=='/parent/'..job.version_name and state.lease_remove==true,'known unselected failed copy was not cleaned')
end
job=fixture();state.reason='none';state.info={mode='file',dev=1,ino=3,size=40,modification=1};job:cleanup()
expect(not state.removed,'cleanup deleted a replacement body')
job=fixture();job.committed=true;state.reason='invalid';job:cleanup()
expect(not state.removed and state.lease_remove==true,'committed copy was treated as failed work')
rawset(os,'remove',old_remove)
print('PASS: completed article retention when selector readback is unknown ('..checks..' checks)')
