-- Scoped Kindle firewall rules. A locked, durable intent allows the next
-- process to remove only this share's tagged rules after an interruption.
local Lease=require('weread.lib.file_lease')
local M={}
local function exit_code(command)
    local a,_,c=os.execute(command..' >/dev/null 2>&1')
    if a==true then return 0 end
    if type(a)=='number' then return a>255 and math.floor(a/256) or a end
    return type(c)=='number' and c or 2
end
local function valid(port,tag)
    return type(port)=='number' and port%1==0 and port>=1 and port<=65535
        and type(tag)=='string' and #tag==16 and tag:match('^[a-f0-9]+$')~=nil
end
local function command(action,direction,port,tag)
    local field=direction=='INPUT' and '--dport' or '--sport'
    local state=direction=='INPUT' and 'NEW,ESTABLISHED' or 'ESTABLISHED'
    return string.format('iptables -%s %s -p tcp %s %d -m conntrack --ctstate %s -m comment --comment weread_%s -j ACCEPT',
        action,direction,field,port,state,tag)
end
local function execute(run,cmd)
    local ok,result=pcall(run,cmd)
    return ok and type(result)=='number' and result or 2
end
local function sync(root)
    local ok,util=pcall(require,'ffi/util')
    if not ok or type(util.fsyncDirectory)~='function' then return false end
    local called,result=pcall(util.fsyncDirectory,root)
    return called and result==true
end
local function path(root)
    if type(root)~='string' or root=='' or #root>3000 or root:find('[%z%c]') then return nil end
    return root:gsub('/+$','')..'/excerpt-share-firewall.intent'
end
local function parse(raw)
    if type(raw)~='string' then return nil end
    local p,tag=raw:match('^v1:(%d+):([a-f0-9]+)\n$')
    p=tonumber(p)
    if valid(p,tag) then return p,tag end
end
local function remove_rules(lease,root,run)
    local port,tag=parse(lease:read(128))
    if not port then return false end
    for _,direction in ipairs({'INPUT','OUTPUT'}) do
        local checked=execute(run,command('C',direction,port,tag))
        if checked==0 then
            if execute(run,command('D',direction,port,tag))~=0 then return false end
        elseif checked~=1 then return false end
    end
    if not lease:remove() then return false end
    return sync(root)
end
function M.cleanup(root,run)
    local target=path(root);if not target then return false,'invalid_path' end
    local lease,reason=Lease.open(target)
    if not lease then return reason=='absent',reason end
    local ok=remove_rules(lease,root,run or exit_code)
    lease:release()
    return ok,ok and nil or 'cleanup_failed'
end
function M.acquire(root,port,tag,run)
    if not valid(port,tag) then return nil,'invalid_rule' end
    local target=path(root);if not target then return nil,'invalid_path' end
    run=run or exit_code
    local clean=M.cleanup(root,run);if not clean then return nil,'cleanup_failed' end
    local lease=Lease.open(target,{create=true,exclusive=true})
    if not lease then return nil,'busy' end
    if not lease:write(string.format('v1:%d:%s\n',port,tag)) or not sync(root) then
        lease:remove();lease:release();return nil,'intent_failed'
    end
    for _,direction in ipairs({'INPUT','OUTPUT'}) do
        if execute(run,command('A',direction,port,tag))~=0 then
            remove_rules(lease,root,run);lease:release();return nil,'open_failed'
        end
    end
    local closed=false
    return {release=function()
        if closed then return true end
        closed=true;local ok=remove_rules(lease,root,run);lease:release();return ok
    end}
end
return M
