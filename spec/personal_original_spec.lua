package.path='./?.lua;'..package.path
local files,account,profiles,fail_save,drop_save,changed
package.preload['weread.lib.personal_upload']=function() return {
    capture=function(path) return files[path] end,
    matches=function(input) local file=files[input.path];return file and file.identity.ino==input.identity.ino and not changed or false end,
} end
package.preload['weread.lib.read_access']=function() return {display_book_id=function(id) return type(id)=='string' and id:match('^CB_%w+$') and id or nil end} end
package.preload['weread.lib.content']=function() return {book_resolved_dir=function(settings,id,book) return book.cache_dir or settings.cache_dir..'/'..id end} end
local M=require('weread.lib.personal_original')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture()
    account='one';profiles={one={},two={}};files={};fail_save=false;drop_save=false;changed=false
    local host={settings={cache_dir='/cache',get=function(_self,key,default) if key=='books' then return {['7']={cache_dir='/custom/book',cached_file='/other/cached.pdf'}} end;return default end},
        library_db={accountKey=function() return account end,
            putProfileState=function(_self,key,value) if fail_save then error('private') end;if not drop_save then profiles[account][key]=value end;return true end,
            getProfileState=function(_self,key) return profiles[account][key] end,
            deleteProfileStateIf=function(_self,key,expected)
                local value=profiles[account][key]
                if not value or value.path~=expected.path or value.identity.ino~=expected.identity.ino then return false end
                profiles[account][key]=nil;return true
            end}}
    local info={mode='file',dev=3,ino=4,size=10,modification=100,change=100}
    local input={path='/documents/a.PDF',name='a.PDF',identity=info};files[input.path]=input
    return host,input
end
expect(M.arm('/documents/original.pdf') and M.take('/documents/original.pdf'),'local-only open intent not passed to reader')
expect(not M.take('/documents/original.pdf'),'local-only open intent reused')
expect(M.arm('/documents/original.pdf') and not M.take('/documents/other.pdf'),'open intent applied to a different file')
expect(M.take('/documents/original.pdf'),'unrelated reader discarded the intended local-only handoff')
expect(M.arm('/documents/original.pdf'),'cannot prepare cancellation');M.disarm('/documents/original.pdf')
expect(not M.take('/documents/original.pdf'),'cancelled open intent was reused')
local clock=os.time;rawset(os,'time',function() return 100 end);expect(M.arm('/documents/original.pdf'),'cannot prepare timeout')
rawset(os,'time',function() return 131 end);expect(not M.take('/documents/original.pdf'),'expired open intent was reused');rawset(os,'time',clock)
local host,input=fixture()
expect(M.remember(host,'CB_a',input),'confirmed PDF not associated')
expect(M.resolve(host,'CB_a')==input.path,'same-account original did not resolve')
account='two';expect(not M.resolve(host,'CB_a'),'different account saw original')
account='one';changed=true;expect(not M.resolve(host,'CB_a'),'changed file accepted');changed=false
files[input.path]=nil;expect(not M.resolve(host,'CB_a'),'missing file accepted');files[input.path]=input
expect(not M.remember(host,'invalid-id',input),'invalid identity accepted')
for _,path in ipairs({'/cache/a.pdf','/custom/book/a.pdf','/other/cached.pdf'}) do
    local bad={path=path,name='a.pdf',identity=input.identity};files[path]=bad
    expect(not M.remember(host,'CB_bad',bad),'WeRead cache path accepted')
end
local text={path='/documents/a.txt',name='a.txt',identity=input.identity};files[text.path]=text
expect(not M.remember(host,'CB_text',text),'non-PDF association accepted')
fail_save=true;expect(not M.remember(host,'CB_save',input),'failed metadata write claimed success')
fail_save=false;drop_save=true;expect(not M.remember(host,'CB_lost',input),'missing readback claimed a saved association')
local old=M.snapshot(host,'CB_a');expect(old and old.path==input.path,'association snapshot unavailable')
profiles.one['personal_original_pdf:CB_a']={path='/documents/new.pdf',identity={ino=9}}
expect(not M.forget(host,'CB_a',old) and profiles.one['personal_original_pdf:CB_a'].path=='/documents/new.pdf','stale removal deleted changed association')
local latest=M.snapshot(host,'CB_a');expect(M.forget(host,'CB_a',latest) and not M.snapshot(host,'CB_a') and files[input.path],'unlink did not keep local file')
profiles.one['personal_original_pdf:CB_corrupt']={path='/documents/other.pdf',identity={}}
expect(not M.resolve(host,'CB_corrupt'),'damaged association opened')
print('PASS: local PDF association ('..checks..' checks)')
