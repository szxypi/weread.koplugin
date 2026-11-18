package.path='./?.lua;'..package.path
local Isolation=require('weread.lib.translation_record_isolation')
local paths={}
local hashes={['/source.epub']='one',['/copy.epub']='two'}
local stats={}
local settings={getSidecarDir=function(_self,path,mode)
    return paths[path..':'..mode] or path..':'..mode
end}
local util={partialMD5=function(path) return hashes[path] end}
local lfs={attributes=function(path) return stats[path] end}
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function check() return Isolation.check('/source.epub','/copy.epub',settings,util,lfs) end
expect(check(),'independent records rejected')
hashes['/copy.epub']='one';expect(not check(),'equal sampled content hash accepted');hashes['/copy.epub']='two'
hashes['/copy.epub']=nil;expect(not check(),'unreadable copy hash accepted');hashes['/copy.epub']='two'
paths['/copy.epub:hash']='/source.epub:doc';expect(not check(),'cross-location record path accepted');paths={}
stats['/source.epub:dir']={dev=1,ino=9};stats['/copy.epub:doc']={dev=1,ino=9}
expect(not check(),'aliased sidecar directories accepted');stats={}
expect(not Isolation.check('/source.epub','/source.epub',settings,util,lfs),'same file path accepted')
local bad={getSidecarDir=function() error('unavailable') end}
expect(not Isolation.check('/source.epub','/copy.epub',bad,util,lfs),'sidecar lookup failure accepted')
print('translation_record_isolation_spec: '..checks..' checks')
