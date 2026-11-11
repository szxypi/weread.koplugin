"""Closed synthetic source/highlight service, with no production forwarding."""
from copy import deepcopy
from urllib.parse import urlsplit
from mock_weread import MockServer
from selection_trial_mock import Server as SelectionServer,Opener,Web,credentials


class Server(SelectionServer):
    def route(self,method,target,data):
        p=urlsplit(target)
        if p.hostname=='i.weread.qq.com' and method=='POST' and p.path in ('/book/addBookmark','/book/removeBookmark'):
            if len(self.posts)>=2:self.trial_denied+=1;raise ValueError('native highlight write bound')
            if p.path=='/book/removeBookmark' and (self.mark is None or data!={'bookmarkIds':[self.mark['bookmarkId']]}):
                self.trial_denied+=1;raise ValueError('native highlight target')
            if self.case in ('no-create','no-delete'):
                self.control['selection_thought_mode']='no_change' if (p.path=='/book/addBookmark')==(self.case=='no-create') else 'plain'
            old=set(self.selection_marks);result=MockServer.route(self,method,target,data);self.posts.append(p.path)
            if p.path=='/book/addBookmark':
                added=set(self.selection_marks)-old
                self.mark=deepcopy(self.selection_marks[next(iter(added))]) if added else None
                self.chapter_added=True
                if self.case=='changed-original':self.old_mark['markText']='其他设备改动'
            elif self.case!='no-delete':self.mark=None
            return result
        return super().route(method,target,data)


__all__=['Server','Opener','Web','credentials']
