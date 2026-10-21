//! A small software rasterizer: anti-aliased rectangles, rounded rectangles, circles, soft
//! shadows, bitmaps and text, drawn on the CPU into one RGBA buffer.
//!
//! Axiom has no GPU, so the game draws its whole frame itself and hands the engine one image.
//! Coordinates are logical pixels; the canvas multiplies them by its scale factor.

use ab_glyph::{Font, FontRef, PxScale, ScaleFont, VariableFont, point};

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

pub const fn rgb(r: u8, g: u8, b: u8) -> Rgba {
    Rgba { r, g, b, a: 255 }
}

pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Rgba {
    Rgba { r, g, b, a }
}

impl Rgba {
    pub fn mix(self, other: Rgba, t: f32) -> Rgba {
        let l = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * t).round() as u8;
        rgba(l(self.r, other.r), l(self.g, other.g), l(self.b, other.b), l(self.a, other.a))
    }
}

/// A rectangle in logical pixels.
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect { x, y, w, h }
    }

    pub fn contains(&self, px: f32, py: f32) -> bool {
        px >= self.x && py >= self.y && px < self.x + self.w && py < self.y + self.h
    }

    pub fn inset(&self, d: f32) -> Rect {
        Rect::new(self.x + d, self.y + d, self.w - 2.0 * d, self.h - 2.0 * d)
    }

    pub fn center(&self) -> (f32, f32) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }

    pub fn right(&self) -> f32 {
        self.x + self.w
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.h
    }
}

/// Coverage of a pixel whose center is `d` pixels outside an edge.
#[inline]
fn coverage(d: f32) -> f32 {
    (0.5 - d).clamp(0.0, 1.0)
}

fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Signed distance from `(px, py)` to a rounded box centred at the origin with half-size
/// `(hw, hh)` and corner radius `r`; negative inside.
#[inline]
pub fn sd_round_box(px: f32, py: f32, hw: f32, hh: f32, r: f32) -> f32 {
    let qx = px.abs() - hw + r;
    let qy = py.abs() - hh + r;
    let ox = qx.max(0.0);
    let oy = qy.max(0.0);
    (ox * ox + oy * oy).sqrt() + qx.max(qy).min(0.0) - r
}

/// An image with premultiplied alpha, at physical resolution: a piece, ready to blit.
#[derive(Clone)]
pub struct Bitmap {
    pub w: usize,
    pub h: usize,
    pub px: Vec<[f32; 4]>,
}

impl Bitmap {
    pub fn new(w: usize, h: usize) -> Bitmap {
        Bitmap { w, h, px: vec![[0.0; 4]; w * h] }
    }

    /// Paints `color` over pixel `i` with coverage `a`.
    #[inline]
    pub fn paint(&mut self, i: usize, color: Rgba, a: f32) {
        let a = a * color.a as f32 / 255.0;
        if a <= 0.0 {
            return;
        }
        let p = &mut self.px[i];
        let src = [color.r as f32 / 255.0 * a, color.g as f32 / 255.0 * a, color.b as f32 / 255.0 * a, a];
        for c in 0..4 {
            p[c] = src[c] + p[c] * (1.0 - a);
        }
    }
}

/// Three weights of one variable font.
pub struct Fonts {
    faces: [FontRef<'static>; 3],
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Weight {
    Regular,
    Medium,
    Semibold,
}

impl Fonts {
    pub fn new(data: &'static [u8]) -> Fonts {
        let face = |weight: f32| {
            let mut f = FontRef::try_from_slice(data).expect("the embedded font parses");
            f.set_variation(b"wght", weight);
            f
        };
        Fonts { faces: [face(420.0), face(540.0), face(640.0)] }
    }

    fn face(&self, weight: Weight) -> &FontRef<'static> {
        &self.faces[weight as usize]
    }

    /// The scale at which the font's em is `size` physical pixels.
    fn scale(&self, weight: Weight, size: f32) -> PxScale {
        let f = self.face(weight);
        let em = f.units_per_em().unwrap_or(1000.0);
        PxScale::from(size * f.height_unscaled() / em)
    }

    /// The width of `text` at `size`, in the same units as `size`.
    pub fn width(&self, weight: Weight, size: f32, text: &str) -> f32 {
        // Measure at a fixed large size, so the result doesn't depend on rounding.
        let f = self.face(weight);
        let scaled = f.as_scaled(self.scale(weight, 100.0));
        let mut w = 0.0;
        let mut prev = None;
        for c in text.chars() {
            let id = f.glyph_id(c);
            if let Some(p) = prev {
                w += scaled.kern(p, id);
            }
            w += scaled.h_advance(id);
            prev = Some(id);
        }
        w * size / 100.0
    }
}

/// The frame being drawn: opaque RGB, at physical resolution.
pub struct Canvas {
    pub w: usize,
    pub h: usize,
    /// Physical pixels per logical pixel.
    pub scale: f32,
    pub px: Vec<[u8; 4]>,
}

impl Canvas {
    pub fn new(w: usize, h: usize, scale: f32) -> Canvas {
        Canvas { w, h, scale, px: vec![[0, 0, 0, 255]; w * h] }
    }

    pub fn resize(&mut self, w: usize, h: usize, scale: f32) {
        self.w = w;
        self.h = h;
        self.scale = scale;
        self.px.clear();
        self.px.resize(w * h, [0, 0, 0, 255]);
    }

    /// The bytes, as RGBA8.
    pub fn bytes(&self) -> &[u8] {
        // [u8; 4] has no padding, so the pixels are the bytes in order.
        unsafe { std::slice::from_raw_parts(self.px.as_ptr().cast(), self.px.len() * 4) }
    }

    #[inline]
    fn blend(&mut self, x: usize, y: usize, c: Rgba, a: f32) {
        let a = a * c.a as f32 * (1.0 / 255.0);
        if a <= 0.002 {
            return;
        }
        let p = &mut self.px[y * self.w + x];
        if a >= 0.998 {
            *p = [c.r, c.g, c.b, 255];
            return;
        }
        let mix = |d: u8, s: u8| (d as f32 + (s as f32 - d as f32) * a + 0.5) as u8;
        *p = [mix(p[0], c.r), mix(p[1], c.g), mix(p[2], c.b), 255];
    }

    /// The physical pixel span that `[a, b)` in logical pixels touches, clipped to `len`.
    fn span(&self, a: f32, b: f32, len: usize) -> (usize, usize) {
        let lo = (a * self.scale).floor().max(0.0) as usize;
        let hi = ((b * self.scale).ceil().max(0.0) as usize).min(len);
        (lo.min(len), hi)
    }

    pub fn clear(&mut self, c: Rgba) {
        self.px.fill([c.r, c.g, c.b, 255]);
    }

    pub fn fill_rect(&mut self, r: Rect, c: Rgba) {
        let s = self.scale;
        let (x0, y0, x1, y1) = (r.x * s, r.y * s, r.right() * s, r.bottom() * s);
        let (ix0, ix1) = self.span(r.x, r.right(), self.w);
        let (iy0, iy1) = self.span(r.y, r.bottom(), self.h);
        for y in iy0..iy1 {
            let cy = (y1.min(y as f32 + 1.0) - y0.max(y as f32)).clamp(0.0, 1.0);
            if cy >= 1.0 && c.a == 255 && ix1 > ix0 + 2 {
                // A whole row: blend its two end pixels, copy the colour between them.
                for x in [ix0, ix1 - 1] {
                    let cx = (x1.min(x as f32 + 1.0) - x0.max(x as f32)).clamp(0.0, 1.0);
                    self.blend(x, y, c, cx);
                }
                let row = y * self.w;
                self.px[row + ix0 + 1..row + ix1 - 1].fill([c.r, c.g, c.b, 255]);
                continue;
            }
            for x in ix0..ix1 {
                let cx = (x1.min(x as f32 + 1.0) - x0.max(x as f32)).clamp(0.0, 1.0);
                self.blend(x, y, c, cx * cy);
            }
        }
    }

    /// Runs `f` with each physical pixel of the logical rectangle `r` grown by `pad`, and the
    /// pixel centre in physical units relative to the rectangle's centre.
    fn each_pixel(&mut self, r: Rect, pad: f32, f: impl FnMut(&mut Canvas, usize, usize, f32, f32)) {
        self.each_edge_pixel(r, pad, f32::INFINITY, None, f);
    }

    /// Like [`Canvas::each_pixel`], but pixels further than `hole` physical pixels inside every
    /// edge skip `f`: they are filled with `fill`, or left alone. Shapes are flat inside, so
    /// only their rims need the per-pixel work.
    fn each_edge_pixel(
        &mut self,
        r: Rect,
        pad: f32,
        hole: f32,
        fill: Option<Rgba>,
        mut f: impl FnMut(&mut Canvas, usize, usize, f32, f32),
    ) {
        let (ix0, ix1) = self.span(r.x - pad, r.right() + pad, self.w);
        let (iy0, iy1) = self.span(r.y - pad, r.bottom() + pad, self.h);
        let (cx, cy) = r.center();
        let (cx, cy) = (cx * self.scale, cy * self.scale);
        let (hw, hh) = (r.w * self.scale / 2.0 - hole, r.h * self.scale / 2.0 - hole);
        // The columns of the hole, when there is one.
        let inner = (hw > 0.0 && hh > 0.0).then(|| {
            let a = ((cx - hw).ceil().max(0.0) as usize).clamp(ix0, ix1);
            let b = ((cx + hw).floor().max(0.0) as usize).clamp(a, ix1);
            (a, b)
        });
        for y in iy0..iy1 {
            let py = y as f32 + 0.5 - cy;
            let (a, b) = match inner {
                Some(span) if py.abs() < hh => span,
                _ => (ix1, ix1),
            };
            for x in (ix0..a).chain(b..ix1) {
                f(self, x, y, x as f32 + 0.5 - cx, py);
            }
            if let Some(c) = fill {
                let row = y * self.w;
                for p in &mut self.px[row + a..row + b] {
                    *p = [c.r, c.g, c.b, 255];
                }
            }
        }
    }

    pub fn round_rect(&mut self, r: Rect, radius: f32, c: Rgba) {
        let s = self.scale;
        let (hw, hh, rad) = (r.w * s / 2.0, r.h * s / 2.0, (radius * s).min(r.w * s / 2.0).min(r.h * s / 2.0));
        let edge = |cv: &mut Canvas, x, y, px, py| cv.blend(x, y, c, coverage(sd_round_box(px, py, hw, hh, rad)));
        if c.a == 255 {
            self.each_edge_pixel(r, 1.0, rad + 1.0, Some(c), edge);
        } else {
            self.each_pixel(r, 1.0, edge);
        }
    }

    /// A soft shadow under an opaque rounded rectangle, `blur` logical pixels wide. Only its
    /// rim is drawn: the rectangle drawn over it hides the rest.
    pub fn shadow(&mut self, r: Rect, radius: f32, blur: f32, c: Rgba) {
        let s = self.scale;
        let (hw, hh, rad, b) = (r.w * s / 2.0, r.h * s / 2.0, radius * s, blur * s);
        self.each_edge_pixel(r, blur, rad + b + 1.0, None, |cv, x, y, px, py| {
            let d = sd_round_box(px, py, hw, hh, rad);
            cv.blend(x, y, c, 1.0 - smoothstep(-b, b, d));
        });
    }

    pub fn circle(&mut self, cx: f32, cy: f32, radius: f32, c: Rgba) {
        let r = Rect::new(cx - radius, cy - radius, radius * 2.0, radius * 2.0);
        let rad = radius * self.scale;
        self.each_pixel(r, 1.0, |cv, x, y, px, py| {
            cv.blend(x, y, c, coverage((px * px + py * py).sqrt() - rad));
        });
    }

    /// A circle's outline, `width` wide, inside its edge.
    pub fn ring(&mut self, cx: f32, cy: f32, radius: f32, width: f32, c: Rgba) {
        let r = Rect::new(cx - radius, cy - radius, radius * 2.0, radius * 2.0);
        let (rad, w) = (radius * self.scale, width * self.scale);
        self.each_pixel(r, 1.0, |cv, x, y, px, py| {
            let d = (px * px + py * py).sqrt() - rad;
            cv.blend(x, y, c, coverage(d) * coverage(-d - w));
        });
    }

    /// A soft round glow over the rectangle `r`, strongest in its middle.
    pub fn glow(&mut self, r: Rect, radius: f32, c: Rgba) {
        let rad = radius * self.scale;
        self.each_pixel(r, 0.0, |cv, x, y, px, py| {
            let t = ((px * px + py * py).sqrt() / rad).min(1.0);
            cv.blend(x, y, c, (1.0 - t * t).powf(1.5));
        });
    }

    /// Rounds the corners of a rectangle already drawn, by fading its corners into `bg`.
    pub fn round_corners(&mut self, r: Rect, radius: f32, bg: Rgba) {
        let s = self.scale;
        let (hw, hh, rad) = (r.w * s / 2.0, r.h * s / 2.0, radius * s);
        let (cx, cy) = r.center();
        for (qx, qy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let corner = Rect::new(r.x + qx * (r.w - radius), r.y + qy * (r.h - radius), radius, radius);
            let (ix0, ix1) = self.span(corner.x, corner.right(), self.w);
            let (iy0, iy1) = self.span(corner.y, corner.bottom(), self.h);
            for y in iy0..iy1 {
                for x in ix0..ix1 {
                    let d = sd_round_box(x as f32 + 0.5 - cx * s, y as f32 + 0.5 - cy * s, hw, hh, rad);
                    self.blend(x, y, bg, 1.0 - coverage(d));
                }
            }
        }
    }

    /// Draws a bitmap with its top-left corner at logical `(x, y)`, faded by `alpha`.
    pub fn blit(&mut self, bm: &Bitmap, x: f32, y: f32, alpha: f32) {
        let ox = (x * self.scale).round() as isize;
        let oy = (y * self.scale).round() as isize;
        for by in 0..bm.h {
            let py = oy + by as isize;
            if py < 0 || py >= self.h as isize {
                continue;
            }
            for bx in 0..bm.w {
                let px = ox + bx as isize;
                if px < 0 || px >= self.w as isize {
                    continue;
                }
                let s = bm.px[by * bm.w + bx];
                let a = s[3] * alpha;
                if a <= 0.002 {
                    continue;
                }
                let d = &mut self.px[py as usize * self.w + px as usize];
                for c in 0..3 {
                    let v = s[c] * alpha * 255.0 + d[c] as f32 * (1.0 - a);
                    d[c] = (v + 0.5).min(255.0) as u8;
                }
            }
        }
    }

    /// Draws `text` with its baseline's left end at logical `(x, baseline)`; returns its width.
    pub fn text(&mut self, fonts: &Fonts, weight: Weight, size: f32, x: f32, baseline: f32, c: Rgba, text: &str) -> f32 {
        let s = self.scale;
        let f = fonts.face(weight);
        let scale = fonts.scale(weight, size * s);
        let scaled = f.as_scaled(scale);
        let mut pen = x * s;
        let base = baseline * s;
        let mut prev = None;
        for ch in text.chars() {
            let id = f.glyph_id(ch);
            if let Some(p) = prev {
                pen += scaled.kern(p, id);
            }
            let glyph = id.with_scale_and_position(scale, point(pen, base));
            pen += scaled.h_advance(id);
            prev = Some(id);
            let Some(outline) = f.outline_glyph(glyph) else { continue };
            let b = outline.px_bounds();
            let (w, h) = (self.w as i32, self.h as i32);
            outline.draw(|gx, gy, cov| {
                let px = b.min.x as i32 + gx as i32;
                let py = b.min.y as i32 + gy as i32;
                if px >= 0 && py >= 0 && px < w && py < h {
                    self.blend(px as usize, py as usize, c, cov.min(1.0));
                }
            });
        }
        pen / s - x
    }

    /// Draws `text` centred on `cx`.
    pub fn text_centered(&mut self, fonts: &Fonts, weight: Weight, size: f32, cx: f32, baseline: f32, c: Rgba, text: &str) {
        let w = fonts.width(weight, size, text);
        self.text(fonts, weight, size, cx - w / 2.0, baseline, c, text);
    }
}
