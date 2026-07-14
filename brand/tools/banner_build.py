#!/usr/bin/env python3
"""Precompute the Geodineum CLI banner in three tiers from the iris geometry:
  truecolor (24-bit gold gradient), 256-color, and plain (no escapes).
Deterministic — same twisted-hex-torus as the SVG/gMath mark."""
import math

R, r, HEX_SIDES, TWIST = 3.2, 1.35, 6, 1.0
def torus(theta, phi):
    pt = phi + theta*TWIST
    return ((R+r*math.cos(pt))*math.cos(theta),
            (R+r*math.cos(pt))*math.sin(theta), r*math.sin(pt))

def grid(cols=44, rows=22, segs=900, rings=26):
    W,H = cols*2, rows*4
    dots=[[0]*W for _ in range(H)]; depth=[[None]*W for _ in range(H)]
    pts=[]
    for i in range(segs+1):
        th=(i/segs)*2*math.pi
        for j in range(HEX_SIDES): pts.append(torus(th,(j/HEX_SIDES)*2*math.pi))
    for k in range(rings):
        th=(k/rings)*2*math.pi
        ring=[torus(th,(j/HEX_SIDES)*2*math.pi) for j in range(HEX_SIDES)]; ring.append(ring[0])
        for a,b in zip(ring,ring[1:]):
            for t in range(24):
                f=t/24; pts.append((a[0]+(b[0]-a[0])*f,a[1]+(b[1]-a[1])*f,a[2]+(b[2]-a[2])*f))
    xs=[p[0] for p in pts]; ys=[p[1] for p in pts]; zs=[p[2] for p in pts]
    minx,maxx,miny,maxy=min(xs),max(xs),min(ys),max(ys); zmin,zmax=min(zs),max(zs); zr=(zmax-zmin) or 1
    pad=0.08
    for x,y,z in pts:
        px=int((x-minx)/(maxx-minx)*(W-1-2*W*pad)+W*pad)
        py=int((y-miny)/(maxy-miny)*(H-1-2*H*pad)+H*pad)
        if 0<=px<W and 0<=py<H:
            dots[py][px]=1; d=(z-zmin)/zr
            if depth[py][px] is None or d>depth[py][px]: depth[py][px]=d
    return dots,depth,cols,rows

OFF=[(0,0,0x01),(0,1,0x02),(0,2,0x04),(1,0,0x08),(1,1,0x10),(1,2,0x20),(0,3,0x40),(1,3,0x80)]
def cells(dots,depth,cols,rows):
    for cy in range(rows):
        row=[]
        for cx in range(cols):
            bits=0; ds=[]
            for dx,dy,bit in OFF:
                X,Y=cx*2+dx,cy*4+dy
                if dots[Y][X]:
                    bits|=bit
                    if depth[Y][X] is not None: ds.append(depth[Y][X])
            row.append((bits, sum(ds)/len(ds) if ds else 0.5))
        yield row

def gold24(d):
    lo=(0x8a,0x6f,0x3c); hi=(0xe3,0xc8,0x87)
    return tuple(int(lo[i]+(hi[i]-lo[i])*d) for i in range(3))
def gold256(d):                       # 5 gold steps in the 256-color cube
    steps=[136,172,178,214,220]; return steps[min(len(steps)-1,int(d*len(steps)))]

d,z,c,rw = grid()
tc=[]; c256=[]; plain=[]
for row in cells(d,z,c,rw):
    lt=[]; l2=[]; lp=[]
    for bits,dep in row:
        if bits:
            ch=chr(0x2800+bits)
            R_,G_,B_=gold24(dep); lt.append(f"\x1b[38;2;{R_};{G_};{B_}m{ch}")
            l2.append(f"\x1b[38;5;{gold256(dep)}m{ch}")
            lp.append(ch)
        else: lt.append(" "); l2.append(" "); lp.append(" ")
    tc.append("".join(lt)+"\x1b[0m"); c256.append("".join(l2)+"\x1b[0m"); plain.append("".join(lp))

def wrap(art,color):
    W="\x1b[38;2;227;200;135m" if color else ""; D="\x1b[2m" if color else ""; RS="\x1b[0m" if color else ""
    return ("\n"+"\n".join(art)+"\n\n"
        f"  {W} G E O D I N E U M{RS}\n"
        f"  {D}The deterministic constellation · gcli{RS}\n")

open("cli_banner_truecolor.ans","w").write(wrap(tc,True))
open("cli_banner_256.ans","w").write(wrap(c256,True))
open("cli_banner_plain.txt","w").write(wrap(plain,False))
print("wrote cli_banner_truecolor.ans / _256.ans / _plain.txt")
