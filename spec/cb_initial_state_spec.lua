local State=require('weread.lib.cb_initial_state')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local id='CB_SyntheticFirst'
local function raw(extra)
    local node={bookId=id,progress=0,chapterUid=0,chapterOffset=0}
    for key,value in pairs(extra or {}) do node[key]=value end
    return {book=node}
end
local base=assert(State.from(raw(),id))
expect(State.none(base),'explicit no-chapter response was not recognized')
expect(not base.index_present and not base.summary_present and not base.updated_present,'missing fields invented')
expect(State.matches(raw(),base),'same observation was rejected')
expect(not State.from(raw(),'1234'),'numeric book accepted by imported state')
expect(not State.from(raw(),'CB_Other'),'foreign book accepted')
local full=assert(State.from(raw{chapterIdx=0,summary='',updateTime=11},id))
expect(full.index_present and full.summary_present and full.updated_present and full.updated_at==11,'explicit fields lost')
expect(not State.equal(base,full),'field presence differences ignored')
expect(State.equal(full,assert(State.from(raw{chapterIdx=0,summary='',updatedAt=11},id))),'equivalent timestamp aliases differ')
expect(not State.matches(raw{chapterIdx=0,summary='',updateTime=12},full),'changed update time accepted')
local cases={
    {chapterUid=1},{chapterOffset=1},{progress=1},{chapterIdx=1},
    {summary='not empty'},{chapterTitle='not empty'},{summary='',chapterTitle='conflict'},
    {updateTime=2,updatedAt=3},{chapterOffset=-1},{chapterUid=false},
}
for _,change in ipairs(cases) do expect(not State.from(raw(change),id),'invalid state accepted') end
local missing=raw();missing.book.chapterOffset=nil
expect(not State.from(missing,id),'missing offset accepted')
missing=raw();missing.book.chapterUid=nil
expect(not State.from(missing,id),'missing chapter accepted')
local altered={};for key,value in pairs(base) do altered[key]=value end
altered.unexpected=true
expect(not State.none(altered),'extra state field accepted')
expect(not State.equal(base,nil),'invalid state comparison accepted')
print('cb_initial_state_spec: '..checks..' checks')
