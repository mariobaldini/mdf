#!/usr/bin/env python3
"""Create independent PNG fixtures with Python's standard library only."""
from pathlib import Path
import binascii
import struct
import sys
import zlib

PASSES = [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]

def chunk(kind, data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',binascii.crc32(kind+data)&0xffffffff)

def paeth(a,b,c):
    p=a+b-c;d=[abs(p-a),abs(p-b),abs(p-c)]
    return [a,b,c][d.index(min(d))]

def fixture(kind, depth, interlace, transparency):
    width,height=19,17
    channels={0:1,2:3,3:1,4:2,6:4}[kind]
    mask=(1<<depth)-1
    palette_size=min(16,1<<depth) if kind==3 else 0
    def pixel(x,y):
        values=[((x*17+y*31+c*79)*257+x*13+y*7+c*89)&mask for c in range(channels)]
        if kind==3:return [(x+y*3)%palette_size]
        if y==0 and x<2 and kind in (0,2) and depth==16:
            values=([0x1234,0x5678,0x9abc][:channels])
            values[0]+=x # Equal high bytes; only one pixel matches 16-bit tRNS.
        elif y==0 and x<2 and kind==0:
            values=[mask-x] # Exercise a transparent sample at every low bit depth.
        elif y==0 and x<2 and kind==2:
            values=[17+x,96,175]
        return values
    raw=bytearray()
    for x0,y0,dx,dy in PASSES if interlace else [(0,0,1,1)]:
        xs=list(range(x0,width,dx));ys=list(range(y0,height,dy))
        if not xs or not ys:continue
        previous=bytes((len(xs)*channels*depth+7)//8)
        bpp=max(1,(channels*depth+7)//8)
        for row,y in enumerate(ys):
            values=[v for x in xs for v in pixel(x,y)]
            if depth==16:data=b''.join(struct.pack('>H',v) for v in values)
            elif depth==8:data=bytes(values)
            else:
                data=bytearray((len(values)*depth+7)//8)
                for i,v in enumerate(values):data[i*depth//8]|=v<<(8-depth-(i*depth%8))
                data=bytes(data)
            filter_type=row%5
            filtered=bytearray()
            for i,v in enumerate(data):
                a=data[i-bpp] if i>=bpp else 0;b=previous[i];c=previous[i-bpp] if i>=bpp else 0
                prediction=[0,a,b,(a+b)//2,paeth(a,b,c)][filter_type]
                filtered.append((v-prediction)&255)
            raw+=bytes([filter_type])+filtered;previous=data
    output=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,depth,kind,0,0,interlace))
    if kind==3:output+=chunk(b'PLTE',bytes(v for i in range(palette_size) for v in ((i*37)%256,(i*67)%256,(i*97)%256)))
    if transparency:
        trns=(bytes((i*43)%256 for i in range(max(1,palette_size-2))) if kind==3 else
              struct.pack('>H',0x1234 if depth==16 else mask) if kind==0 else
              struct.pack('>HHH',0x1234,0x5678,0x9abc) if depth==16 else struct.pack('>HHH',17,96,175))
        output+=chunk(b'tRNS',trns)
    return output+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')

def generate(directory):
    directory.mkdir(parents=True,exist_ok=True)
    count=0
    for kind,depths in [(0,[1,2,4,8,16]),(2,[8,16]),(3,[1,2,4,8]),(4,[8,16]),(6,[8,16])]:
        for depth in depths:
            for interlace in (0,1):
                for transparency in ((False,True) if kind in (0,2,3) else (False,)):
                    data=fixture(kind,depth,interlace,transparency)
                    (directory/f'png-{kind}-{depth}-{interlace}-{int(transparency)}.png').write_bytes(data);count+=1
    data=bytearray(fixture(6,8,0,False));data[29]^=1
    (directory/'bad-crc.bad').write_bytes(data)
    (directory/'huge-header.bad').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',0x7fffffff,0x7fffffff,16,6,0,0,0))+chunk(b'IEND',b''))
    print(f'Generated {count} PNG fixtures: all color types, bit depths, filters, Adam7 and transparency')

if __name__=='__main__':generate(Path(sys.argv[1]))
