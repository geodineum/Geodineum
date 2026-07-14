#!/usr/bin/env python3
"""Geodineum CLI banner — the iris mark as ANSI/braille terminal art.
Same twisted-hex-torus geometry as the SVG/gMath mark, top-down view."""
import math, sys

R, r, HEX_SIDES, TWIST = 3.2, 1.35, 6, 1.0
def torus(theta, phi):
    pt = phi + theta*TWIST
    return ((R+r*math.cos(pt))*math.cos(theta),
            (R+r*math.cos(pt))*math.sin(theta),
            r*math.sin(pt))

def render(cols=44, rows=22, segs=900, rings=26):
    # braille: each cell = 2 wide x 4 tall dot grid
    W, H = cols*2, rows*4
    dots = [[0]*W for _ in range(H)]
    depth = [[None]*W for _ in range(H)]
    pts = []
    for i in range(segs+1):                       # 6 ribs
        th = (i/segs)*2*math.pi
        for j in range(HEX_SIDES):
            pts.append(torus(th,(j/HEX_SIDES)*2*math.pi))
    for k in range(rings):                         # hex rings
        th=(k/rings)*2*math.pi
        ring=[torus(th,(j/HEX_SIDES)*2*math.pi) for j in range(HEX_SIDES)]
        ring.append(ring[0])
        for a,b in zip(ring,ring[1:]):
            for t in range(24):
                f=t/24; pts.append((a[0]+(b[0]-a[0])*f,a[1]+(b[1]-a[1])*f,a[2]+(b[2]-a[2])*f))
    xs=[p[0] for p in pts]; ys=[p[1] for p in pts]; zs=[p[2] for p in pts]
    minx,maxx,miny,maxy=min(xs),max(xs),min(ys),max(ys)
    zmin,zmax=min(zs),max(zs); zr=(zmax-zmin) or 1
    pad=0.08
    def sx(x): return int((x-minx)/(maxx-minx)*(W-1-2*W*pad)+W*pad)
    def sy(y): return int((y-miny)/(maxy-miny)*(H-1-2*H*pad)+H*pad)
    for x,y,z in pts:
        px,py=sx(x),sy(y)
        if 0<=px<W and 0<=py<H:
            dots[py][px]=1
            d=(z-zmin)/zr
            if depth[py][px] is None or d>depth[py][px]: depth[py][px]=d
    # braille assembly (U+2800 + bit pattern), gold gradient by depth
    OFF=[(0,0,0x01),(0,1,0x02),(0,2,0x04),(1,0,0x08),
         (1,1,0x10),(1,2,0x20),(0,3,0x40),(1,3,0x80)]
    def gold(d):                                   # #8a6f3c -> #e3c887
        lo=(0x8a,0x6f,0x3c); hi=(0xe3,0xc8,0x87)
        return tuple(int(lo[i]+(hi[i]-lo[i])*d) for i in range(3))
    out=[]
    for cy in range(rows):
        line=[]
        for cx in range(cols):
            bits=0; ds=[]
            for dx,dy,bit in OFF:
                X,Y=cx*2+dx,cy*4+dy
                if dots[Y][X]:
                    bits|=bit
                    if depth[Y][X] is not None: ds.append(depth[Y][X])
            if bits:
                rr_,gg,bb=gold(sum(ds)/len(ds) if ds else .5)
                line.append(f"\x1b[38;2;{rr_};{gg};{bb}m{chr(0x2800+bits)}")
            else:
                line.append(" ")
        out.append("".join(line)+"\x1b[0m")
    return "\n".join(out)

if __name__=="__main__":
    art=render()
    banner=("\n"+art+"\n\n"
        "  \x1b[38;2;227;200;135m G E O D I N E U M\x1b[0m\n"
        "  \x1b[2mThe deterministic constellation · gcli\x1b[0m\n")
    sys.stdout.write(banner)
    open("cli_banner.ans","w").write(banner)
