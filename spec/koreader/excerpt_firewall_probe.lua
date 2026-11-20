-- Simulated iptables only. Never changes host or device firewall rules.
require('setupkoenv')
local root=assert(debug.getinfo(1,'S').source:match('^@(.+)/spec/koreader/[^/]+$'))
package.path=root..'/?.lua;'..package.path
local Firewall=require('weread.lib.excerpt_firewall')
local Lease=require('weread.lib.file_lease')
root=assert(os.getenv('WEREAD_FIREWALL_TEST_DIR'))
local rules={unrelated=true}; local fail_add,fail_delete,fail_check=false,false,false
local function run(command)
    local action,direction=command:match('iptables %-(%u) (%u+)')
    local tag=command:match('%-%-comment (weread_[a-f0-9]+)')
    assert(action and direction and tag)
    local key=direction..tag
    if action=='A' then if fail_add and direction=='OUTPUT' then return 2 end;rules[key]=true;return 0 end
    if action=='C' then if fail_check then return 2 end;return rules[key] and 0 or 1 end
    if action=='D' then if fail_delete then return 2 end;rules[key]=nil;return 0 end
    error('unexpected command')
end
local tag='0123456789abcdef'
local held=assert(Firewall.acquire(root,12345,tag,run))
assert(not Firewall.acquire(root,12346,tag,run),'simultaneous lease accepted')
assert(held:release() and rules.unrelated and not rules.INPUTweread_0123456789abcdef)
fail_add=true;assert(not Firewall.acquire(root,12345,tag,run));fail_add=false
assert(not rules.INPUTweread_0123456789abcdef)
local lease=assert(Lease.open(root..'/excerpt-share-firewall.intent',{create=true,exclusive=true}))
assert(lease:write('v1:12345:'..tag..'\n'));lease:release()
rules.INPUTweread_0123456789abcdef=true;rules.OUTPUTweread_0123456789abcdef=true
fail_delete=true;assert(not Firewall.cleanup(root,run));fail_delete=false
fail_check=true;assert(not Firewall.cleanup(root,run));fail_check=false
assert(Firewall.cleanup(root,run));assert(rules.unrelated and not rules.INPUTweread_0123456789abcdef and not rules.OUTPUTweread_0123456789abcdef)
assert(not Firewall.acquire(root,12345,'bad',run))
print('WEREAD_FIREWALL=PASS')
os.exit(0)
