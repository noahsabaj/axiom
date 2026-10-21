//! The chess pieces, drawn as layered vector shapes and rasterized into bitmaps.
//!
//! Each piece is a stack of layers in a unit square, y pointing down. A layer is a union of
//! shapes, filled and outlined; later layers paint over earlier ones, which draws the lines
//! between a piece's parts.

use crate::canvas::{Bitmap, rgb, rgba, sd_round_box};
use chess::rules::{Color, Kind};

#[derive(Clone)]
enum Shape {
    Circle { x: f32, y: f32, r: f32 },
    /// A box by centre and half-size, with rounded corners.
    Box { x: f32, y: f32, hw: f32, hh: f32, r: f32 },
    /// A polygon, its corners rounded by `round`.
    Poly { pts: Vec<(f32, f32)>, round: f32 },
    /// A line with round ends.
    Line { a: (f32, f32), b: (f32, f32), r: f32 },
}

impl Shape {
    fn distance(&self, px: f32, py: f32) -> f32 {
        match self {
            Shape::Circle { x, y, r } => ((px - x).powi(2) + (py - y).powi(2)).sqrt() - r,
            Shape::Box { x, y, hw, hh, r } => sd_round_box(px - x, py - y, *hw, *hh, *r),
            Shape::Poly { pts, round } => sd_polygon(px, py, pts) - round,
            Shape::Line { a, b, r } => {
                let (wx, wy) = (px - a.0, py - a.1);
                let (ex, ey) = (b.0 - a.0, b.1 - a.1);
                let t = ((wx * ex + wy * ey) / (ex * ex + ey * ey)).clamp(0.0, 1.0);
                ((wx - ex * t).powi(2) + (wy - ey * t).powi(2)).sqrt() - r
            }
        }
    }

    fn bounds(&self) -> (f32, f32, f32, f32) {
        match self {
            Shape::Circle { x, y, r } => (x - r, y - r, x + r, y + r),
            Shape::Box { x, y, hw, hh, .. } => (x - hw, y - hh, x + hw, y + hh),
            Shape::Poly { pts, round } => pts.iter().fold((1.0f32, 1.0f32, 0.0f32, 0.0f32), |b, p| {
                (b.0.min(p.0 - round), b.1.min(p.1 - round), b.2.max(p.0 + round), b.3.max(p.1 + round))
            }),
            Shape::Line { a, b, r } => (a.0.min(b.0) - r, a.1.min(b.1) - r, a.0.max(b.0) + r, a.1.max(b.1) + r),
        }
    }
}

/// Signed distance to a polygon: negative inside.
fn sd_polygon(px: f32, py: f32, v: &[(f32, f32)]) -> f32 {
    let n = v.len();
    let mut d = (px - v[0].0).powi(2) + (py - v[0].1).powi(2);
    let mut s = 1.0;
    let mut j = n - 1;
    for i in 0..n {
        let (ex, ey) = (v[j].0 - v[i].0, v[j].1 - v[i].1);
        let (wx, wy) = (px - v[i].0, py - v[i].1);
        let t = ((wx * ex + wy * ey) / (ex * ex + ey * ey)).clamp(0.0, 1.0);
        let (bx, by) = (wx - ex * t, wy - ey * t);
        d = d.min(bx * bx + by * by);
        let c1 = py >= v[i].1;
        let c2 = py < v[j].1;
        let c3 = ex * wy > ey * wx;
        if (c1 && c2 && c3) || (!c1 && !c2 && !c3) {
            s = -s;
        }
        j = i;
    }
    s * d.sqrt()
}

#[derive(Clone, Copy, PartialEq)]
enum Paint {
    /// The piece's body colour, outlined.
    Body,
    /// The outline colour alone, for details such as an eye.
    Ink,
}

struct Layer {
    shapes: Vec<Shape>,
    paint: Paint,
}

fn layer(paint: Paint, shapes: Vec<Shape>) -> Layer {
    Layer { shapes, paint }
}

fn circle(x: f32, y: f32, r: f32) -> Shape {
    Shape::Circle { x, y, r }
}

fn rbox(x: f32, y: f32, hw: f32, hh: f32, r: f32) -> Shape {
    Shape::Box { x, y, hw, hh, r }
}

fn poly(round: f32, pts: &[(f32, f32)]) -> Shape {
    Shape::Poly { pts: pts.to_vec(), round }
}

fn line(a: (f32, f32), b: (f32, f32), r: f32) -> Shape {
    Shape::Line { a, b, r }
}

/// The plinth every piece stands on.
fn base(hw: f32) -> Layer {
    layer(Paint::Body, vec![rbox(0.5, 0.835, hw, 0.05, 0.03)])
}

fn layers(kind: Kind) -> Vec<Layer> {
    match kind {
        Kind::Pawn => vec![
            layer(Paint::Body, vec![poly(0.012, &[(0.355, 0.80), (0.645, 0.80), (0.565, 0.54), (0.435, 0.54)])]),
            base(0.22),
            layer(Paint::Body, vec![rbox(0.5, 0.535, 0.115, 0.027, 0.02)]),
            layer(Paint::Body, vec![circle(0.5, 0.385, 0.125)]),
        ],
        Kind::Rook => vec![
            layer(Paint::Body, vec![poly(0.01, &[(0.33, 0.80), (0.67, 0.80), (0.625, 0.42), (0.375, 0.42)])]),
            base(0.25),
            layer(Paint::Body, vec![rbox(0.5, 0.735, 0.2, 0.03, 0.015)]),
            layer(
                Paint::Body,
                vec![
                    rbox(0.5, 0.37, 0.19, 0.06, 0.015),
                    rbox(0.335, 0.27, 0.055, 0.06, 0.012),
                    rbox(0.5, 0.27, 0.055, 0.06, 0.012),
                    rbox(0.665, 0.27, 0.055, 0.06, 0.012),
                ],
            ),
        ],
        Kind::Knight => vec![
            layer(
                Paint::Body,
                vec![poly(
                    0.012,
                    &[
                        (0.31, 0.80),
                        (0.72, 0.80),
                        (0.74, 0.62),
                        (0.715, 0.46),
                        (0.66, 0.33),
                        (0.585, 0.235),
                        (0.565, 0.13),
                        (0.505, 0.195),
                        (0.40, 0.215),
                        (0.30, 0.30),
                        (0.215, 0.43),
                        (0.195, 0.50),
                        (0.235, 0.545),
                        (0.30, 0.53),
                        (0.40, 0.475),
                        (0.445, 0.52),
                        (0.37, 0.62),
                    ],
                )],
            ),
            base(0.25),
            // The mane, a line down the back of the neck.
            layer(Paint::Ink, vec![line((0.60, 0.27), (0.665, 0.42), 0.012), line((0.665, 0.42), (0.685, 0.62), 0.012)]),
            layer(Paint::Ink, vec![circle(0.40, 0.32, 0.028)]),
            layer(Paint::Ink, vec![circle(0.245, 0.47, 0.014)]),
        ],
        Kind::Bishop => vec![
            layer(Paint::Body, vec![poly(0.012, &[(0.375, 0.80), (0.625, 0.80), (0.56, 0.58), (0.44, 0.58)])]),
            base(0.23),
            layer(Paint::Body, vec![rbox(0.5, 0.575, 0.125, 0.028, 0.02)]),
            layer(
                Paint::Body,
                vec![poly(
                    0.02,
                    &[(0.40, 0.53), (0.60, 0.53), (0.645, 0.43), (0.615, 0.33), (0.5, 0.215), (0.385, 0.33), (0.355, 0.43)],
                )],
            ),
            layer(Paint::Body, vec![circle(0.5, 0.175, 0.04)]),
            layer(Paint::Ink, vec![line((0.535, 0.34), (0.59, 0.4), 0.016)]),
        ],
        Kind::Queen => vec![
            layer(
                Paint::Body,
                vec![poly(
                    0.012,
                    &[
                        (0.30, 0.79),
                        (0.70, 0.79),
                        (0.80, 0.33),
                        (0.70, 0.53),
                        (0.655, 0.27),
                        (0.575, 0.51),
                        (0.5, 0.22),
                        (0.425, 0.51),
                        (0.345, 0.27),
                        (0.30, 0.53),
                        (0.20, 0.33),
                    ],
                )],
            ),
            layer(
                Paint::Body,
                vec![
                    circle(0.195, 0.31, 0.045),
                    circle(0.345, 0.245, 0.045),
                    circle(0.5, 0.195, 0.045),
                    circle(0.655, 0.245, 0.045),
                    circle(0.805, 0.31, 0.045),
                ],
            ),
            base(0.26),
            layer(Paint::Body, vec![rbox(0.5, 0.73, 0.215, 0.03, 0.015)]),
        ],
        Kind::King => vec![
            layer(
                Paint::Body,
                vec![poly(
                    0.025,
                    &[(0.31, 0.79), (0.69, 0.79), (0.77, 0.50), (0.70, 0.40), (0.60, 0.40), (0.5, 0.47), (0.40, 0.40), (0.30, 0.40), (0.23, 0.50)],
                )],
            ),
            layer(Paint::Body, vec![rbox(0.5, 0.395, 0.06, 0.08, 0.03)]),
            layer(Paint::Body, vec![rbox(0.5, 0.215, 0.025, 0.1, 0.012), rbox(0.5, 0.2, 0.085, 0.025, 0.012)]),
            base(0.26),
            layer(Paint::Body, vec![rbox(0.5, 0.73, 0.21, 0.03, 0.015)]),
        ],
    }
}

/// Renders a piece into a `size`-pixel square bitmap.
pub fn render(kind: Kind, color: Color, size: usize) -> Bitmap {
    let (body, ink, accent) = match color {
        Color::White => (rgb(252, 252, 250), rgb(38, 40, 46), rgb(252, 252, 250)),
        Color::Black => (rgb(58, 60, 68), rgb(18, 19, 23), rgba(255, 255, 255, 40)),
    };
    let outline = 0.034;
    let mut bm = Bitmap::new(size, size);
    let s = size as f32;
    let px = 1.0 / s;

    // A soft shadow on the square under the piece.
    for y in 0..size {
        for x in 0..size {
            let (u, v) = ((x as f32 + 0.5) * px, (y as f32 + 0.5) * px);
            let d = (((u - 0.5) / 0.30).powi(2) + ((v - 0.875) / 0.06).powi(2)).sqrt();
            let a = (1.0 - d).clamp(0.0, 1.0).powi(2) * 0.22;
            bm.paint(y * size + x, rgb(0, 0, 0), a);
        }
    }

    for l in layers(kind) {
        let (x0, y0, x1, y1) = l.shapes.iter().map(Shape::bounds).fold((1.0f32, 1.0f32, 0.0f32, 0.0f32), |a, b| {
            (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3))
        });
        let pad = outline + 2.0 * px;
        let ix0 = ((x0 - pad) * s).floor().max(0.0) as usize;
        let iy0 = ((y0 - pad) * s).floor().max(0.0) as usize;
        let ix1 = (((x1 + pad) * s).ceil() as usize).min(size);
        let iy1 = (((y1 + pad) * s).ceil() as usize).min(size);
        for y in iy0..iy1 {
            for x in ix0..ix1 {
                let (u, v) = ((x as f32 + 0.5) * px, (y as f32 + 0.5) * px);
                let d = l.shapes.iter().map(|sh| sh.distance(u, v)).fold(f32::MAX, f32::min);
                let i = y * size + x;
                match l.paint {
                    Paint::Body => {
                        // The outline straddles the shape's edge; the body fills what's inside.
                        let outer = (0.5 - (d - outline / 2.0) * s).clamp(0.0, 1.0);
                        let inner = (0.5 - (d + outline / 2.0) * s).clamp(0.0, 1.0);
                        bm.paint(i, ink, outer);
                        bm.paint(i, body, inner);
                        if color == Color::Black {
                            // A faint rim of light just inside the outline.
                            let rim = (0.5 - (d + outline / 2.0) * s).clamp(0.0, 1.0)
                                * (0.5 + (d + outline * 1.4) * s).clamp(0.0, 1.0);
                            bm.paint(i, accent, rim);
                        }
                    }
                    Paint::Ink => bm.paint(i, ink, (0.5 - d * s).clamp(0.0, 1.0)),
                }
            }
        }
    }
    bm
}

/// The rendered pieces at one size: index by colour, then kind.
pub struct PieceSet {
    pub size: usize,
    bitmaps: Vec<Bitmap>,
}

impl PieceSet {
    pub fn new(size: usize) -> PieceSet {
        let mut bitmaps = Vec::with_capacity(12);
        for color in [Color::White, Color::Black] {
            for kind in [Kind::Pawn, Kind::Knight, Kind::Bishop, Kind::Rook, Kind::Queen, Kind::King] {
                bitmaps.push(render(kind, color, size));
            }
        }
        PieceSet { size, bitmaps }
    }

    pub fn get(&self, color: Color, kind: Kind) -> &Bitmap {
        &self.bitmaps[color.index() * 6 + kind as usize]
    }
}
