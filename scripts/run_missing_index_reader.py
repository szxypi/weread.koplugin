#!/usr/bin/env python3
"""Full synthetic native-reader flow with only the Web chapter index omitted."""
from urllib.parse import urlsplit
from native_reader_fixture import NativeReaderServer
import run_native_reader_position as runner


class MissingIndexServer(NativeReaderServer):
    def route(self,method,target,data):
        result=super().route(method,target,data);url=urlsplit(target)
        if url.hostname=='weread.qq.com' and url.path=='/web/book/getProgress':
            result[1]['book'].pop('chapterIdx',None)
        return result


def main(argv=None):
    original=runner.NativeReaderServer
    try:
        runner.NativeReaderServer=MissingIndexServer
        return runner.main(argv)
    finally:runner.NativeReaderServer=original


if __name__=='__main__':raise SystemExit(main())
