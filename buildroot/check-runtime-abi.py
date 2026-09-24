#!/usr/bin/env python3
import re,sys
for path in sys.argv[1:]:
    data=open(path,'rb').read()
    def maxv(prefix):
        vals=set(re.findall(prefix+rb'_[0-9.]+',data))
        def key(x): return [int(n) for n in x.decode().split('_',1)[1].split('.')]
        return max(vals,key=key).decode() if vals else 'none'
    print(path)
    for p in (b'GLIBC',b'GLIBCXX',b'CXXABI'): print(' ',p.decode(),maxv(p))
