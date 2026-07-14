# Geodineum — Brand

The mark is not drawn. It is the deterministic output of a parametric surface —
the same six-fold twisted-hex-torus the gIris interface renders in 3-D — with
every vertex computed in gMath Q64.64 fixed point. Deterministic input,
deterministic mark: bit-identical on any architecture. See `PROVENANCE.txt`.

## Contents

| Path | What |
|---|---|
| `iris_full.svg` | Guilloché hero mark — large formats, print. |
| `iris_glyph.svg` | Bold reduction — app icon, favicon, avatar. |
| `iris_dim.svg` | Tilted aperture — motion / loaders. |
| `iris_*_currentcolor.svg` | Recolourable variants (inherit `currentColor`). |
| `png/` | Raster previews at 32–512 px, on dark and light grounds. |
| `brandsheet.html` | The full visual-identity sheet. |
| `gmath_gen/` | Rust generator — regenerates the marks from first principles. |
| `PROVENANCE.txt` | Exact inputs, surface equations, crate version, verification. |
| `tools/` | The prototype generators (`gen.py`, `banner_build.py`). |

The CLI session banner (braille tiers) lives in `../assets/cli/`.

## Regenerate

```bash
cd gmath_gen
GMATH_PROFILE=embedded cargo run --release   # bit-identical to the shipped SVGs
```

## Palette

Gold `#c5a059`, highlight `#e3c887`, bronze-on-light `#8a6f3c`, constellation-black `#060504`.

---

Visual identity for the Geodineum ecosystem. Built by Niels Erik Toren.
