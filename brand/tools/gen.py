#!/usr/bin/env python3
"""Geodineum mark — the gIris twisted hex torus, distilled to a flat vector mark.
Exact geometry from gIris/assets/js/iris.js. Emits SVG + a PNG preview."""
import math, argparse
from PIL import Image, ImageDraw

# ---- exact gIris parameters ------------------------------------------------
R, r      = 3.2, 1.35     # major radius, tube cross-section
HEX_SIDES = 6
TWIST     = 1.0           # full rotations of hex cross-section per revolution

def torus_point(theta, phi):
    pt = phi + theta * TWIST
    x = (R + r*math.cos(pt)) * math.cos(theta)
    y = (R + r*math.cos(pt)) * math.sin(theta)
    z =  r * math.sin(pt)
    return (x, y, z)

def project(p, tilt_deg, yaw_deg):
    x, y, z = p
    ya = math.radians(yaw_deg)                      # spin about z (in-plane)
    x, y = x*math.cos(ya) - y*math.sin(ya), x*math.sin(ya) + y*math.cos(ya)
    a = math.radians(tilt_deg)                      # tilt about x
    yv = y*math.cos(a) - z*math.sin(a)
    zv = y*math.sin(a) + z*math.cos(a)
    return (x, yv, zv)                              # ortho: screen=(x,yv), depth=zv

def build(tilt, yaw, rings, tube_segs):
    thetas = [ (i/tube_segs)*2*math.pi for i in range(tube_segs+1) ]
    # 6 longitudinal ribs (the twisted edges)
    ribs = []
    for j in range(HEX_SIDES):
        phi = (j/HEX_SIDES)*2*math.pi
        ribs.append([ project(torus_point(t, phi), tilt, yaw) for t in thetas ])
    # hex cross-section rings, sampled
    ringpolys = []
    for k in range(rings):
        t = (k/rings)*2*math.pi
        poly = [ project(torus_point(t, (j/HEX_SIDES)*2*math.pi), tilt, yaw)
                 for j in range(HEX_SIDES) ]
        poly.append(poly[0])
        ringpolys.append(poly)
    return ribs, ringpolys

def bounds(polys):
    xs = [p[0] for poly in polys for p in poly]; ys = [p[1] for poly in polys for p in poly]
    return min(xs), max(xs), min(ys), max(ys)

def fit(polys, size, pad):
    minx,maxx,miny,maxy = bounds(polys)
    w,h = maxx-minx, maxy-miny; s = (size-2*pad)/max(w,h)
    ox = (size-(w*s))/2 - minx*s; oy = (size-(h*s))/2 - miny*s
    def T(p): return (p[0]*s+ox, p[1]*s+oy, p[2])
    return [[T(p) for p in poly] for poly in polys], s

GOLD, GOLD_HI, GOLD_LO = "#c5a059", "#e3c887", "#8a6f3c"

def depth_norm(polys):
    zs = [p[2] for poly in polys for p in poly]; return min(zs), max(zs)

def svg(ribs, rings, size=512):
    allp = ribs+rings
    fitted,_ = fit(allp, size, size*0.11)
    fr, fring = fitted[:len(ribs)], fitted[len(ribs):]
    zmin,zmax = depth_norm(fitted); zr = (zmax-zmin) or 1
    def op(poly): return 0.30 + 0.70*((sum(p[2] for p in poly)/len(poly)-zmin)/zr)
    # painter: sort all strokes back->front
    strokes = []
    for poly in fring:
        strokes.append((op(poly), poly, 1.1, GOLD, "ring"))
    for poly in fr:
        strokes.append((op(poly), poly, 2.4, GOLD_HI, "rib"))
    strokes.sort(key=lambda s: s[0])
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" fill="none">']
    for o,poly,wdt,col,_ in strokes:
        d = "M " + " L ".join(f"{p[0]:.2f} {p[1]:.2f}" for p in poly)
        out.append(f'<path d="{d}" stroke="{col}" stroke-width="{wdt:.2f}" '
                   f'stroke-opacity="{o:.3f}" stroke-linecap="round" stroke-linejoin="round"/>')
    out.append("</svg>")
    return "\n".join(out)

def preview_png(ribs, rings, path, size=512, bg=(6,5,4,255)):
    SS=3; S=size*SS
    fitted,_ = fit(ribs+rings, size, size*0.11)
    fr, fring = fitted[:len(ribs)], fitted[len(ribs):]
    zmin,zmax = depth_norm(fitted); zr=(zmax-zmin) or 1
    def op(poly): return 0.30 + 0.70*((sum(p[2] for p in poly)/len(poly)-zmin)/zr)
    img = Image.new("RGBA",(S,S),bg); d = ImageDraw.Draw(img,"RGBA")
    def hx(c): c=c.lstrip('#'); return tuple(int(c[i:i+2],16) for i in (0,2,4))
    strokes=[]
    for poly in fring: strokes.append((op(poly),poly,1.1,hx(GOLD)))
    for poly in fr:    strokes.append((op(poly),poly,2.4,hx(GOLD_HI)))
    strokes.sort(key=lambda s:s[0])
    for o,poly,wdt,col in strokes:
        pts=[(p[0]*SS,p[1]*SS) for p in poly]
        d.line(pts, fill=col+(int(o*255),), width=max(1,int(wdt*SS)), joint="curve")
    img.resize((size,size),Image.LANCZOS).save(path)

def svg2(ribs,rings,size,rib_w,ring_w,rib_col,ring_col,ring_floor):
    allp=ribs+rings; fitted,_=fit(allp,size,size*0.11)
    fr,fring=fitted[:len(ribs)],fitted[len(ribs):]
    zmin,zmax=depth_norm(fitted); zr=(zmax-zmin) or 1
    def op(poly,floor): return floor+(1-floor)*((sum(p[2] for p in poly)/len(poly)-zmin)/zr)
    strokes=[(op(p,ring_floor),p,ring_w,ring_col) for p in fring]+[(op(p,0.55),p,rib_w,rib_col) for p in fr]
    strokes.sort(key=lambda s:s[0])
    out=[f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" fill="none">']
    for o,poly,w,col in strokes:
        d="M "+" L ".join(f"{p[0]:.2f} {p[1]:.2f}" for p in poly)
        out.append(f'<path d="{d}" stroke="{col}" stroke-width="{w:.2f}" stroke-opacity="{o:.3f}" stroke-linecap="round" stroke-linejoin="round"/>')
    out.append("</svg>"); return "\n".join(out)

def preview2(ribs,rings,path,size,rib_w,ring_w,rib_col,ring_col,ring_floor,bg):
    SS=3;S=size*SS; fitted,_=fit(ribs+rings,size,size*0.11)
    fr,fring=fitted[:len(ribs)],fitted[len(ribs):]
    zmin,zmax=depth_norm(fitted); zr=(zmax-zmin) or 1
    def op(poly,floor): return floor+(1-floor)*((sum(p[2] for p in poly)/len(poly)-zmin)/zr)
    def hx(c):c=c.lstrip('#');return tuple(int(c[i:i+2],16) for i in (0,2,4))
    img=Image.new("RGBA",(S,S),bg);d=ImageDraw.Draw(img,"RGBA")
    strokes=[(op(p,ring_floor),p,ring_w,hx(ring_col)) for p in fring]+[(op(p,0.55),p,rib_w,hx(rib_col)) for p in fr]
    strokes.sort(key=lambda s:s[0])
    for o,poly,w,col in strokes:
        d.line([(p[0]*SS,p[1]*SS) for p in poly],fill=col+(int(o*255),),width=max(1,int(w*SS)),joint="curve")
    img.resize((size,size),Image.LANCZOS).save(path)

if __name__=="__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument("--tilt",type=float,default=0); ap.add_argument("--yaw",type=float,default=0)
    ap.add_argument("--rings",type=int,default=24); ap.add_argument("--segs",type=int,default=240)
    ap.add_argument("--ribw",type=float,default=3.0); ap.add_argument("--ringw",type=float,default=1.0)
    ap.add_argument("--ribcol",default="#e3c887"); ap.add_argument("--ringcol",default="#b7924e")
    ap.add_argument("--ringfloor",type=float,default=0.28)
    ap.add_argument("--out",default="mark")
    a=ap.parse_args()
    ribs,rings=build(a.tilt,a.yaw,a.rings,a.segs)
    open(a.out+".svg","w").write(svg2(ribs,rings,512,a.ribw,a.ringw,a.ribcol,a.ringcol,a.ringfloor))
    preview2(ribs,rings,a.out+"_dark.png",512,a.ribw,a.ringw,a.ribcol,a.ringcol,a.ringfloor,(6,5,4,255))
    preview2(ribs,rings,a.out+"_lite.png",512,a.ribw,a.ringw,"#8a6f3c","#a07f42",a.ringfloor,(247,245,242,255))
    print("wrote",a.out)
