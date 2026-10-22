#!/usr/bin/env python3
"""Create independent PNG fixtures with Python's standard library only."""
from pathlib import Path
import binascii
import struct
import sys
import zlib

PASSES = [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]
COLORS = [(0,0,0),(255,32,16),(16,224,48),(32,64,255)]

def gif_fixture(local, transparent, interlaced, animated):
    width,height=19,17
    palette=bytes(c for color in COLORS for c in color)
    header=b'GIF89a'+struct.pack('<HHBBB',width,height,0 if local else 0x81,0,0)
    if not local:header+=palette
    def frame(shift):
        control=b'!\xf9\x04'+bytes([int(transparent)])+b'\x00\x00\x00\x00'
        rows=([*range(0,height,8),*range(4,height,8),*range(2,height,4),*range(1,height,2)] if interlaced else range(height))
        # Reset between literals. All codes stay three bits wide, independent
        # of the decoder's dictionary-growth implementation.
        codes=[code for y in rows for x in range(width) for code in (4,(x+y*3+shift)%4)]+[5]
        packed=bytearray((len(codes)*3+7)//8)
        for i,code in enumerate(codes):
            for bit in range(3):packed[(i*3+bit)//8]|=((code>>bit)&1)<<((i*3+bit)%8)
        blocks=b''.join(bytes([len(packed[i:i+255])])+packed[i:i+255] for i in range(0,len(packed),255))+b'\x00'
        descriptor=b','+struct.pack('<HHHHB',0,0,width,height,(0x81 if local else 0)|(0x40 if interlaced else 0))
        return control+descriptor+(palette if local else b'')+b'\x02'+blocks
    expected=bytes(c for y in range(height) for x in range(width)
        for c in (*COLORS[(x+y*3)%4],0 if transparent and (x+y*3)%4==0 else 255))
    return header+frame(0)+(frame(1) if animated else b'')+b';',expected

def bmp_fixture(bits, top_down=False, core=False, masks=False, alpha=False, rle=False):
    width,height=19,17
    count=(1<<bits if core else min(4,1<<bits)) if bits<=8 else 0
    palette=(COLORS+[(i,i,i) for i in range(4,count)])[:count]
    raw=[];expected=[]
    for y in range(height):
        samples=[]
        for x in range(width):
            if bits<=8:
                value=((y%3)+1 if bits==8 else x%2+1) if rle else (x+y*3)%min(count,4)
                samples.append(value);color=palette[value];opacity=255
            elif bits==16:
                r,g,b=(31 if x&1 else 0),(63 if masks else 31) if y&1 else 0,(31 if (x+y)&1 else 0)
                value=(r<<(11 if masks else 10))|(g<<5)|b
                samples.extend(struct.pack('<H',value));color=(255 if r else 0,255 if g else 0,255 if b else 0);opacity=255
            else:
                color=((x*31+y*13)%256,(x*11+y*37)%256,(x*47+y*7)%256)
                opacity=128 if alpha and (x+y)%2 else 255
                samples.extend((color[2],color[1],color[0]))
                if bits==32:samples.append(opacity if alpha else 0)
            expected.extend((*color,opacity))
        if bits<8:
            row=bytearray((width*bits+7)//8)
            for x,value in enumerate(samples):row[x*bits//8]|=value<<(8-bits-x*bits%8)
        else:row=bytearray(samples)
        row+=bytes((-len(row))%4);raw.append(bytes(row))
    if rle:
        body=b''.join(bytes([width, ((y%3)+1) if bits==8 else 0x12,0,0]) for y in range(height-1,-1,-1))+b'\x00\x01'
    else:body=b''.join(raw if top_down else reversed(raw))
    compression=(1 if bits==8 else 2) if rle else (3 if masks or alpha else 0)
    header_size=12 if core else 108 if alpha else 40
    if core:header=struct.pack('<IHHHH',12,width,height,1,bits)
    else:header=struct.pack('<IiiHHIIiiII',header_size,width,-height if top_down else height,1,bits,compression,len(body),2835,2835,count,0)
    if alpha:header+=struct.pack('<IIIII',0x00ff0000,0x0000ff00,0x000000ff,0xff000000,0x73524742)+bytes(48)
    elif masks:header+=struct.pack('<III',0xf800,0x07e0,0x001f)
    palette_bytes=bytes(c for color in palette for c in ((color[2],color[1],color[0]) if core else (color[2],color[1],color[0],0)))
    offset=14+len(header)+len(palette_bytes)
    return b'BM'+struct.pack('<IHHI',offset+len(body),0,0,offset)+header+palette_bytes+body,bytes(expected)

def legacy_fixtures(directory):
    cases=[]
    for local in (False,True):
        for transparent in (False,True):
            for interlaced in (False,True):
                for animated in (False,True):
                    cases.append((f'gif-{int(local)}-{int(transparent)}-{int(interlaced)}-{int(animated)}.gif',gif_fixture(local,transparent,interlaced,animated)))
    for bits in (1,4,8,16,24,32):
        for top_down in (False,True):cases.append((f'bmp-{bits}-{int(top_down)}.bmp',bmp_fixture(bits,top_down)))
    for bits in (1,4,8,24):cases.append((f'bmp-core-{bits}.bmp',bmp_fixture(bits,core=True)))
    for top_down in (False,True):cases.append((f'bmp-565-{int(top_down)}.bmp',bmp_fixture(16,top_down,masks=True)))
    cases.append(('bmp-alpha.bmp',bmp_fixture(32,alpha=True)))
    for bits in (4,8):cases.append((f'bmp-rle-{bits}.bmp',bmp_fixture(bits,rle=True)))
    manifest=[]
    for name,(encoded,expected) in cases:
        (directory/name).write_bytes(encoded)
        (directory/(name+'.rgba')).write_bytes(expected)
        manifest.append(f'{name}\t19\t17\n')
    (directory/'legacy.tsv').write_text(''.join(manifest))
    huge_gif=bytearray(cases[0][1][0]);struct.pack_into('<HH',huge_gif,6,65535,65535)
    (directory/'huge-gif.bad').write_bytes(huge_gif)
    huge_bmp=bytearray(bmp_fixture(24)[0]);struct.pack_into('<ii',huge_bmp,18,0x7fffffff,0x7fffffff)
    (directory/'huge-bmp.bad').write_bytes(huge_bmp)
    return len(cases)

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
    legacy=legacy_fixtures(directory)
    print(f'Generated {count} PNG fixtures: all color types, bit depths, filters, Adam7 and transparency')
    print(f'Generated {legacy} GIF/BMP fixtures: first frames, palettes, transparency, interlace, row order, bitfields and RLE')

if __name__=='__main__':generate(Path(sys.argv[1]))
