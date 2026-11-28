"""Read the one captured archive from a private Linux tmpfs workspace."""
import base64,os,stat,sys
from pathlib import Path

from native_time_bundle_native_record import archive_details_bytes


def require_tmpfs(root):
    if (sys.platform!='linux' or root.is_symlink() or not root.resolve(strict=True).is_relative_to(Path('/dev/shm').resolve(strict=True))
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        raise ValueError('cb_remote_archive/root')


def read(plan,root,source):
    root=Path(root);source=Path(source)
    try:
        require_tmpfs(root);info=root.stat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077
                or source!=root/'source.epub'):raise ValueError()
        fd=os.open(source,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_NONBLOCK',0)|getattr(os,'O_CLOEXEC',0))
        with os.fdopen(fd,'rb') as stream:
            file_info=os.fstat(stream.fileno())
            if (not stat.S_ISREG(file_info.st_mode) or file_info.st_uid!=os.geteuid()
                    or file_info.st_mode&0o077 or not 0<file_info.st_size<=2*1024*1024):raise ValueError()
            data=stream.read(2*1024*1024+1)
            if len(data)!=file_info.st_size:raise ValueError()
        archive_details_bytes(plan,data)
        return data
    except (OSError,ValueError):raise ValueError('cb_remote_archive/invalid') from None


class Relay:
    """Attach one archive to a claim; recheck it before forwarding approval."""
    def __init__(self,plan,root,source):
        self.plan,self.root,self.source=plan,Path(root),Path(source);self.pending=None;self.used=False
    def prepare(self,event):
        if (self.used or self.pending is not None or not isinstance(event,dict)
                or set(event)!={'kind','body','selection','record'} or event['kind']!='claim'):
            raise ValueError('cb_remote_archive/order')
        self.pending=read(self.plan,self.root,self.source);self.used=True
        return dict(event,archive_base64=base64.b64encode(self.pending).decode('ascii'))
    def recheck(self):
        if self.pending is None:raise ValueError('cb_remote_archive/order')
        previous=self.pending;self.pending=None
        if read(self.plan,self.root,self.source)!=previous:raise ValueError('cb_remote_archive/changed')
        return True
