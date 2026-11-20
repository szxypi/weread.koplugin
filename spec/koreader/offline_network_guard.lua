-- Linux test-process guard: block creation of IPv4/IPv6 sockets while allowing
-- Unix sockets needed by the X11 test display. Inherited by worker processes.
return function()
    local ffi=require('ffi')
    pcall(ffi.cdef,[[
        struct weread_sock_filter { unsigned short code; unsigned char jt, jf; unsigned int k; };
        struct weread_sock_fprog { unsigned short len; struct weread_sock_filter *filter; };
        int prctl(int option, ...);
        int socket(int domain, int type, int protocol);
        int close(int fd);
    ]])
    local socket_nr=ffi.arch=='arm64' and 198 or ffi.arch=='x64' and 41
    assert(socket_nr,'unsupported offline guard architecture')
    local instructions=ffi.new('struct weread_sock_filter[7]',{
        {0x20,0,0,0},          -- seccomp_data.nr
        {0x15,0,4,socket_nr},  -- only socket(2)
        {0x20,0,0,16},         -- first argument: address family
        {0x15,1,0,2},          -- AF_INET -> deny
        {0x15,0,1,10},         -- AF_INET6 -> deny
        {0x06,0,0,0x00050001}, -- EPERM
        {0x06,0,0,0x7fff0000}, -- allow
    })
    local program=ffi.new('struct weread_sock_fprog[1]')
    program[0].len=7;program[0].filter=instructions
    local zero=ffi.cast('unsigned long',0)
    assert(ffi.C.prctl(38,ffi.cast('unsigned long',1),zero,zero,zero)==0)
    assert(ffi.C.prctl(22,ffi.cast('unsigned long',2),ffi.cast('void *',program),zero,zero)==0)
    assert(ffi.C.socket(2,1,0)==-1 and ffi.errno()==1,'offline guard did not block IPv4')
    assert(ffi.C.socket(10,1,0)==-1 and ffi.errno()==1,'offline guard did not block IPv6')
    local unix=ffi.C.socket(1,1,0);assert(unix>=0);assert(ffi.C.close(unix)==0)
    return true
end
