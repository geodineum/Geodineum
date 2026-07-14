//! Geodineum mark — regenerated from the gIris twisted-hex-torus surface,
//! with every vertex computed in gMath Q64.64 fixed point (deterministic,
//! bit-identical across x86 / ARM / RISC-V). Build:
//!
//!   GMATH_PROFILE=embedded cargo run --release
//!
//! The 3-D surface points are the mathematical object and are produced entirely
//! in `FixedPoint`. The 2-D fit / painter-order / opacity is presentation only
//! (f64), and rounds to the same 2-decimal SVG coordinates as the reference.

use g_math::fixed_point::FixedPoint as F;

// ── exact gIris parameters (see gIris/assets/js/iris.js) ────────────────────
// R = 3.2, r = 1.35, HEX_SIDES = 6, TWIST = 1.0 — expressed as integer
// rationals so nothing enters the pipeline as a float literal.
fn r_major() -> F { F::from_int(32) / F::from_int(10) }   // 3.2
fn r_tube() -> F { F::from_int(135) / F::from_int(100) }  // 1.35
const HEX_SIDES: i32 = 6;
// TWIST = 1 ⇒ pt = phi + theta.

// τ derived from first principles: atan(1) = π/4, so τ = 8·atan(1).
// No π literal, no float seed — only integer inputs.
fn tau() -> F { F::from_int(8) * F::from_int(1).atan() }

fn fdiv(num: i32, den: i32) -> F { F::from_int(num) / F::from_int(den) }

/// A surface vertex, computed in Q64.64 then projected (yaw = 0, tilt = a).
fn vertex(theta: F, phi: F, sin_a: F, cos_a: F) -> (f64, f64, f64) {
    let pt = phi + theta; // + theta * TWIST, TWIST = 1
    let rr = r_major() + r_tube() * pt.cos();
    let x = rr * theta.cos();
    let y = rr * theta.sin();
    let z = r_tube() * pt.sin();
    // orthographic projection: yaw = 0, tilt about x by angle a
    let yv = y * cos_a - z * sin_a;
    let zv = y * sin_a + z * cos_a;
    (x.to_f64(), yv.to_f64(), zv.to_f64())
}

type Poly = Vec<(f64, f64, f64)>;

fn build(tilt_deg: i32, rings: i32, segs: i32) -> (Vec<Poly>, Vec<Poly>) {
    let tau = tau();
    let a = tau * fdiv(tilt_deg, 360);
    let (sin_a, cos_a) = (a.sin(), a.cos());
    let phi_of = |j: i32| tau * fdiv(j, HEX_SIDES);

    // 6 longitudinal ribs (the twisted edges)
    let mut ribs: Vec<Poly> = Vec::new();
    for j in 0..HEX_SIDES {
        let phi = phi_of(j);
        let mut rib: Poly = Vec::with_capacity((segs + 1) as usize);
        for i in 0..=segs {
            let theta = tau * fdiv(i, segs);
            rib.push(vertex(theta, phi, sin_a, cos_a));
        }
        ribs.push(rib);
    }
    // hex cross-section rings
    let mut ringpolys: Vec<Poly> = Vec::new();
    for k in 0..rings {
        let theta = tau * fdiv(k, rings);
        let mut poly: Poly = Vec::with_capacity((HEX_SIDES + 1) as usize);
        for j in 0..HEX_SIDES {
            poly.push(vertex(theta, phi_of(j), sin_a, cos_a));
        }
        poly.push(poly[0]);
        ringpolys.push(poly);
    }
    (ribs, ringpolys)
}

// ── presentation: fit + painter-order + depth opacity (mirrors gen.py svg2) ──
fn bounds(polys: &[Poly]) -> (f64, f64, f64, f64) {
    let mut minx = f64::MAX; let mut maxx = f64::MIN;
    let mut miny = f64::MAX; let mut maxy = f64::MIN;
    for poly in polys { for p in poly {
        minx = minx.min(p.0); maxx = maxx.max(p.0);
        miny = miny.min(p.1); maxy = maxy.max(p.1);
    }}
    (minx, maxx, miny, maxy)
}

fn fit(polys: &[Poly], size: f64, pad: f64) -> Vec<Poly> {
    let (minx, maxx, miny, maxy) = bounds(polys);
    let (w, h) = (maxx - minx, maxy - miny);
    let s = (size - 2.0 * pad) / w.max(h);
    let ox = (size - w * s) / 2.0 - minx * s;
    let oy = (size - h * s) / 2.0 - miny * s;
    polys.iter().map(|poly| {
        poly.iter().map(|p| (p.0 * s + ox, p.1 * s + oy, p.2)).collect()
    }).collect()
}

fn depth_range(polys: &[Poly]) -> (f64, f64) {
    let mut zmin = f64::MAX; let mut zmax = f64::MIN;
    for poly in polys { for p in poly { zmin = zmin.min(p.2); zmax = zmax.max(p.2); } }
    (zmin, zmax)
}

struct Stroke { op: f64, poly: Poly, w: f64, col: &'static str }

fn svg(ribs: &[Poly], rings: &[Poly], size: f64, rib_w: f64, ring_w: f64,
       rib_col: &'static str, ring_col: &'static str, ring_floor: f64) -> String {
    let mut all: Vec<Poly> = Vec::new();
    all.extend_from_slice(ribs);
    all.extend_from_slice(rings);
    let fitted = fit(&all, size, size * 0.11);
    let (fr, fring) = fitted.split_at(ribs.len());
    let (zmin, zmax) = depth_range(&fitted);
    let zr = if zmax - zmin == 0.0 { 1.0 } else { zmax - zmin };
    let op = |poly: &Poly, floor: f64| {
        let mean_z: f64 = poly.iter().map(|p| p.2).sum::<f64>() / poly.len() as f64;
        floor + (1.0 - floor) * ((mean_z - zmin) / zr)
    };
    let mut strokes: Vec<Stroke> = Vec::new();
    for poly in fring { strokes.push(Stroke { op: op(poly, ring_floor), poly: poly.clone(), w: ring_w, col: ring_col }); }
    for poly in fr { strokes.push(Stroke { op: op(poly, 0.55), poly: poly.clone(), w: rib_w, col: rib_col }); }
    strokes.sort_by(|a, b| a.op.partial_cmp(&b.op).unwrap());

    let mut out = format!("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {} {}\" fill=\"none\">", size as i32, size as i32);
    for s in &strokes {
        let d: String = s.poly.iter().enumerate().map(|(i, p)| {
            format!("{}{:.2} {:.2}", if i == 0 { "M " } else { " L " }, p.0, p.1)
        }).collect();
        out.push_str(&format!(
            "\n<path d=\"{}\" stroke=\"{}\" stroke-width=\"{:.2}\" stroke-opacity=\"{:.3}\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>",
            d, s.col, s.w, s.op));
    }
    out.push_str("\n</svg>");
    out
}

struct Mark { name: &'static str, tilt: i32, rings: i32, segs: i32, rib_w: f64, ring_w: f64, ring_floor: f64 }

fn main() {
    const RIB_COL: &str = "#e3c887";
    const RING_COL: &str = "#b7924e";
    const SIZE: f64 = 512.0;

    let marks = [
        Mark { name: "iris_full",  tilt: 0,  rings: 24, segs: 240, rib_w: 3.20, ring_w: 1.00, ring_floor: 0.28 },
        Mark { name: "iris_glyph", tilt: 0,  rings: 12, segs: 180, rib_w: 5.00, ring_w: 2.20, ring_floor: 0.45 },
        Mark { name: "iris_dim",   tilt: 16, rings: 22, segs: 240, rib_w: 3.20, ring_w: 1.00, ring_floor: 0.28 },
    ];

    for m in &marks {
        let (ribs, rings) = build(m.tilt, m.rings, m.segs);
        let colored = svg(&ribs, &rings, SIZE, m.rib_w, m.ring_w, RIB_COL, RING_COL, m.ring_floor);
        let current = colored.replace(RIB_COL, "currentColor").replace(RING_COL, "currentColor");
        let dir = std::env::var("OUT_DIR_MARK").unwrap_or_else(|_| ".".into());
        std::fs::write(format!("{}/{}.svg", dir, m.name), &colored).unwrap();
        std::fs::write(format!("{}/{}_currentcolor.svg", dir, m.name), &current).unwrap();
        println!("wrote {}.svg + {}_currentcolor.svg", m.name, m.name);
    }
}
