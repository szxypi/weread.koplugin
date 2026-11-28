package.path='./?.lua;'..package.path
local cached={book_id='41',reviews={{reviewId='old'}}};local remote={book_id='41',reviews={{reviewId='new'}}}
local calls,fail=0,false
package.preload['weread.lib.my_cloud_marks_store']=function() return {new=function(_,library,client,variant)
    assert(library=='library' and client=='client' and variant=='thoughts')
    return {read=function(_,book) assert(book=='41');return cached end}
end} end
package.preload['weread.lib.my_cloud_thoughts']=function() return {fetch=function(client,book,selected)
    assert(client=='client' and book=='41' and selected.native.token=='test')
    calls=calls+1;if fail then error('unavailable') end;return remote
end} end
local Task=require('weread.lib.personal_mark_task')
local function load(access,online) return Task.load_thoughts('client','library','41',access,online) end
local value=load(nil,false);assert(value.snapshot==cached and not value.refreshed and calls==0)
value=load({token='test'},true);assert(value.snapshot==remote and value.refreshed and calls==1)
fail=true;value=load({token='test'},true);assert(value.snapshot==cached and not value.refreshed and calls==2)
value=load({token='test',renewal_pending=true},true);assert(value.snapshot==cached and not value.refreshed and calls==2)
cached=nil;value=load(nil,false);assert(value.snapshot==false and not value.refreshed and calls==2)
print('personal_thought_task_spec: cache, network, failure and offline passed')
