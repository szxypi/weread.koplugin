package.path='./?.lua;'..package.path
local Resume=require('weread.lib.unindexed_resume')
local Source=require('weread.lib.position_source')
local checks=0
local function expect(value,label) checks=checks+1;assert(value,label) end
local owner=string.rep('a',20)
local point={book_id='41',chapter_uid='22',file_id=string.rep('b',64),raw_sha256=string.rep('c',64),
    basis=Source.coordinate_basis('web_xhtml'),upload_verified=false}
local hint=assert(Resume.make(point,'41',owner,3))
expect(Resume.valid(hint,'41',owner,3),'valid local-only chapter was rejected')
expect(not Resume.valid(hint,'42',owner,3),'foreign book was accepted')
expect(not Resume.valid(hint,'41',string.rep('d',20),3),'foreign account was accepted')
expect(not Resume.valid(hint,'41',nil,3),'signed-out scope accepted an account-owned record')
expect(not Resume.valid(hint,'41',owner,4),'changed login session accepted an old selection')
local anonymous=assert(Resume.make(point,'41',nil,8))
expect(Resume.valid(anonymous,'41',nil,8) and not Resume.valid(anonymous,'41',owner,8),
    'signed-out selection crossed into an account')
hint.extra='unexpected';expect(not Resume.valid(hint,'41',owner,3),'unknown fields were accepted');hint.extra=nil
hint.chapter_uid=22;expect(not Resume.valid(hint,'41',owner,3),'noncanonical chapter identifier was accepted');hint.chapter_uid='22'
point.upload_verified=true;expect(not Resume.make(point,'41',owner,3),'cloud-authorized point was accepted');point.upload_verified=false
point.chapter_uid='0';expect(not Resume.make(point,'41',owner,3),'invalid chapter was accepted');point.chapter_uid='22'
point.raw_sha256='bad';expect(not Resume.make(point,'41',owner,3),'invalid source hash was accepted')
print(('unindexed_resume_spec: %d checks'):format(checks))
