package.path='./?.lua;'..package.path
local calls,closed,valid,alter,member=0,0,true,false,true
package.loaded['weread.lib.native_read_access']={matches=function() return valid end}
package.loaded['weread.lib.native_position_protocol']={credentials=function(value) return value.valid==true end}
package.loaded['weread.lib.native_authorization']={new=function(_self,_client,options)
    assert(options.expected_vid=='123')
    return {_request=function(_request_self,stage,url,body,credentials)
        assert(options.is_current() and credentials.vid=='123');calls=calls+1
        if stage=='translation_member' then
            assert(url=='https://i.weread.qq.com/pay/memberCardSummary?pf=wechat_wx-2001-android-100-weread' and body==nil)
            return {isPaying=member}
        end
        if stage=='translation_book' then
            assert(url=='https://i.weread.qq.com/book/info?bookId=456' and body==nil)
            return {bookId='456',format='epub',version=7}
        end
        assert(stage=='translation_catalog' and url=='https://i.weread.qq.com/book/chapterInfos'
            and body.bookIds[1]=='456' and #body.bookIds==1 and body.synckeys[1]==0)
        return {data={{bookId='456',updated={{chapterUid=7,title='Chapter One',wordCount=1200,
            price=alter and calls>3 and 2 or 0,translateVersion=0}}}}}
    end,cancel=function() closed=closed+1 end}
end}
local Access=require('weread.lib.translation_generation_access')
local selected={credentials={vid='123',valid=true},scope={vid='123'}}
local options={is_current=function() return true end}
local value=assert(Access.inspect({}, {}, selected,'456',7,options))
assert(calls==6 and closed==1 and value.book_id=='456' and value.uid==7 and value.version==7
    and value.translate_version==0 and #value.catalog_sha256==64,'did not independently read both complete snapshots')
calls=0;alter=true;assert(not Access.inspect({}, {}, selected,'456',7,options),'changed second snapshot admitted')
alter=false;calls=0;member=false;assert(not Access.inspect({}, {}, selected,'456',7,options) and calls==1,
    'non-member continued to catalogue')
member=true;calls=0;valid=false;assert(not Access.inspect({}, {}, selected,'456',7,options) and calls==0,
    'changed session sent a read')
valid=true;calls=0;selected.renewal_pending=true
assert(not Access.inspect({}, {}, selected,'456',7,options) and calls==0,'pending renewal sent a read')
selected.renewal_pending=false;assert(not Access.inspect({}, {}, selected,'CB_1',7,options) and calls==0,'invalid book reached transport')
assert(not Access.inspect({}, {}, selected,'456',7,{is_current=function() return false end}) and calls==0,
    'changed reader sent a read')
print('PASS: native translation read-only access scope and fresh snapshots')
