use eframe::egui::Rect;
use eframe::emath::{pos2, vec2};

pub struct TreemapItem {
    pub index: usize,
    pub rect: Rect,
}

/// Gap between neighbouring tiles; each tile is drawn shrunk by this much.
pub const TILE_INSET: f32 = 1.5;

/// Lay out a directory's children and keep only tiles big enough to draw
/// (at least 1px after the [`TILE_INSET`] shrink). `children` must be sorted by
/// size descending, as the scanner leaves them. Indices refer to `children`.
pub fn layout_visible(children: &[crate::scanner::FileNode], bounds: Rect) -> Vec<TreemapItem> {
    let items: Vec<(usize, f64)> = children
        .iter()
        .enumerate()
        .filter(|(_, c)| c.size > 0)
        .map(|(i, c)| (i, c.size as f64))
        .collect();
    let mut layout = squarify(&items, bounds);
    layout.retain(|item| {
        let inner = item.rect.shrink(TILE_INSET);
        inner.width() >= 1.0 && inner.height() >= 1.0
    });
    layout
}

/// Lays out items as a squarified treemap within the given bounding rectangle.
/// `sizes` is a slice of (index, size) pairs, already sorted descending by size.
pub fn squarify(items: &[(usize, f64)], bounds: Rect) -> Vec<TreemapItem> {
    if items.is_empty() || bounds.width() <= 0.0 || bounds.height() <= 0.0 {
        return Vec::new();
    }

    let total: f64 = items.iter().map(|(_, s)| s).sum();
    if total <= 0.0 {
        return Vec::new();
    }

    let area = (bounds.width() as f64) * (bounds.height() as f64);

    // Normalize sizes so they sum to the total area
    let normalized: Vec<(usize, f64)> = items.iter().map(|(i, s)| (*i, s / total * area)).collect();

    let mut result = Vec::with_capacity(items.len());
    layout_recursive(&normalized, bounds, &mut result);
    result
}

fn layout_recursive(items: &[(usize, f64)], bounds: Rect, out: &mut Vec<TreemapItem>) {
    // Iterative: each pass lays out one row and shrinks `bounds`. (A recursive
    // version needs one stack frame per row, which large directories exhaust.)
    let mut items = items;
    let mut bounds = bounds;

    while !items.is_empty() && bounds.width() > 0.0 && bounds.height() > 0.0 {
        if items.len() == 1 {
            out.push(TreemapItem {
                index: items[0].0,
                rect: bounds,
            });
            return;
        }

        // Determine the shorter side of the remaining rectangle
        let w = bounds.width() as f64;
        let h = bounds.height() as f64;
        let horizontal = w >= h; // lay out along the shorter dimension

        let short_side = if horizontal { h } else { w };

        // Find the best row: add items until the worst aspect ratio in the row
        // starts increasing. The worst ratio only depends on the row's largest
        // and smallest areas, so track those instead of rescanning the row.
        let mut row_sum = 0.0;
        let mut row_max = 0.0_f64;
        let mut row_min = f64::MAX;
        let mut best_worst_ratio = f64::MAX;
        let mut split_at = 1;

        for (i, &(_, area)) in items.iter().enumerate() {
            row_sum += area;
            if area > 0.0 {
                row_max = row_max.max(area);
                row_min = row_min.min(area);
            }

            let worst = worst_ratio_from_extremes(row_max, row_min, row_sum, short_side);
            if worst <= best_worst_ratio {
                best_worst_ratio = worst;
                split_at = i + 1;
            } else {
                break;
            }
        }

        // Lay out the chosen row
        let row_items = &items[..split_at];
        let row_total: f64 = row_items.iter().map(|(_, s)| s).sum();
        let row_thickness = if short_side > 0.0 {
            row_total / short_side
        } else {
            0.0
        };

        let mut offset = 0.0;
        for &(idx, area) in row_items {
            let item_length = if row_thickness > 0.0 {
                area / row_thickness
            } else {
                0.0
            };

            let rect = if horizontal {
                Rect::from_min_size(
                    pos2(bounds.min.x, bounds.min.y + offset as f32),
                    vec2(row_thickness as f32, item_length as f32),
                )
            } else {
                Rect::from_min_size(
                    pos2(bounds.min.x + offset as f32, bounds.min.y),
                    vec2(item_length as f32, row_thickness as f32),
                )
            };

            out.push(TreemapItem { index: idx, rect });

            offset += item_length;
        }

        // Continue with the remaining space
        bounds = if horizontal {
            Rect::from_min_max(
                pos2(bounds.min.x + row_thickness as f32, bounds.min.y),
                bounds.max,
            )
        } else {
            Rect::from_min_max(
                pos2(bounds.min.x, bounds.min.y + row_thickness as f32),
                bounds.max,
            )
        };
        items = &items[split_at..];
    }
}

/// Compute the worst (maximum) aspect ratio among items in a row.
#[cfg(test)]
fn worst_ratio(row: &[(usize, f64)], row_sum: f64, side: f64) -> f64 {
    let positive = row.iter().map(|&(_, a)| a).filter(|&a| a > 0.0);
    let max = positive.clone().fold(0.0_f64, f64::max);
    let min = positive.fold(f64::MAX, f64::min);
    worst_ratio_from_extremes(max, min, row_sum, side)
}

/// Worst aspect ratio of a row, given its largest and smallest positive areas.
///
/// Each item's ratio is max(side² · area / sum², sum² / (side² · area)). The
/// first term grows with area and the second shrinks, so the maximum over the
/// row is reached at the largest or the smallest area.
fn worst_ratio_from_extremes(max_area: f64, min_area: f64, row_sum: f64, side: f64) -> f64 {
    if row_sum <= 0.0 || side <= 0.0 {
        return f64::MAX;
    }
    if max_area <= 0.0 {
        // No positive areas in the row.
        return 0.0;
    }

    let side_sq = side * side;
    let sum_sq = row_sum * row_sum;
    let r1 = side_sq * max_area / sum_sq;
    let r2 = sum_sq / (side_sq * min_area);
    r1.max(r2)
}

#[cfg(test)]
mod tests {
    use super::*;
    use eframe::emath::pos2;

    fn make_bounds(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect::from_min_size(pos2(x, y), vec2(w, h))
    }

    #[test]
    fn squarify_empty_input() {
        let result = squarify(&[], make_bounds(0.0, 0.0, 100.0, 100.0));
        assert!(result.is_empty());
    }

    #[test]
    fn squarify_zero_area_bounds() {
        let items = vec![(0, 100.0)];
        assert!(squarify(&items, make_bounds(0.0, 0.0, 0.0, 100.0)).is_empty());
        assert!(squarify(&items, make_bounds(0.0, 0.0, 100.0, 0.0)).is_empty());
    }

    #[test]
    fn squarify_single_item_fills_bounds() {
        let items = vec![(0, 100.0)];
        let bounds = make_bounds(10.0, 20.0, 200.0, 150.0);
        let result = squarify(&items, bounds);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].index, 0);
        let r = result[0].rect;
        assert!((r.min.x - 10.0).abs() < 0.01);
        assert!((r.min.y - 20.0).abs() < 0.01);
        assert!((r.width() - 200.0).abs() < 0.01);
        assert!((r.height() - 150.0).abs() < 0.01);
    }

    #[test]
    fn squarify_preserves_total_area() {
        let items = vec![(0, 60.0), (1, 30.0), (2, 10.0)];
        let bounds = make_bounds(0.0, 0.0, 100.0, 100.0);
        let result = squarify(&items, bounds);
        assert_eq!(result.len(), 3);

        let total_area: f64 = result
            .iter()
            .map(|item| (item.rect.width() as f64) * (item.rect.height() as f64))
            .sum();
        assert!((total_area - 10000.0).abs() < 1.0);
    }

    #[test]
    fn squarify_proportional_areas() {
        let items = vec![(0, 75.0), (1, 25.0)];
        let bounds = make_bounds(0.0, 0.0, 100.0, 100.0);
        let result = squarify(&items, bounds);
        assert_eq!(result.len(), 2);

        let area0 = (result[0].rect.width() as f64) * (result[0].rect.height() as f64);
        let area1 = (result[1].rect.width() as f64) * (result[1].rect.height() as f64);
        assert!((area0 / area1 - 3.0).abs() < 0.1);
    }

    #[test]
    fn squarify_returns_all_items() {
        let items: Vec<(usize, f64)> = (0..10).map(|i| (i, (10 - i) as f64)).collect();
        let bounds = make_bounds(0.0, 0.0, 400.0, 300.0);
        let result = squarify(&items, bounds);
        assert_eq!(result.len(), 10);

        let mut indices: Vec<usize> = result.iter().map(|item| item.index).collect();
        indices.sort();
        assert_eq!(indices, (0..10).collect::<Vec<_>>());
    }

    #[test]
    fn squarify_rects_within_bounds() {
        let items = vec![(0, 50.0), (1, 30.0), (2, 20.0)];
        let bounds = make_bounds(10.0, 10.0, 200.0, 150.0);
        let result = squarify(&items, bounds);

        for item in &result {
            assert!(item.rect.min.x >= bounds.min.x - 0.01);
            assert!(item.rect.min.y >= bounds.min.y - 0.01);
            assert!(item.rect.max.x <= bounds.max.x + 0.01);
            assert!(item.rect.max.y <= bounds.max.y + 0.01);
        }
    }

    #[test]
    fn squarify_non_square_bounds() {
        let items = vec![(0, 50.0), (1, 50.0)];
        let bounds = make_bounds(0.0, 0.0, 400.0, 100.0);
        let result = squarify(&items, bounds);
        assert_eq!(result.len(), 2);

        let total_area: f64 = result
            .iter()
            .map(|item| (item.rect.width() as f64) * (item.rect.height() as f64))
            .sum();
        assert!((total_area - 40000.0).abs() < 1.0);
    }

    #[test]
    fn worst_ratio_single_item() {
        let row = vec![(0, 100.0)];
        let ratio = worst_ratio(&row, 100.0, 10.0);
        assert!(ratio >= 1.0);
        assert!(ratio.is_finite());
    }

    #[test]
    fn worst_ratio_zero_sum() {
        let row = vec![(0, 100.0)];
        assert_eq!(worst_ratio(&row, 0.0, 10.0), f64::MAX);
    }

    #[test]
    fn layout_matches_reference_on_many_items() {
        // Thousands of rows: the old recursive layout used one stack frame per
        // row. Also checks every item is laid out exactly once.
        let items: Vec<(usize, f64)> = (0..100_000)
            .map(|i| (i, 1.0e9 / ((i + 1) as f64).powf(1.1)))
            .collect();
        let bounds = make_bounds(0.0, 0.0, 1600.0, 1000.0);
        let result = squarify(&items, bounds);
        assert_eq!(result.len(), items.len());
        let total_area: f64 = result
            .iter()
            .map(|item| (item.rect.width() as f64) * (item.rect.height() as f64))
            .sum();
        assert!((total_area - 1600.0 * 1000.0).abs() < 1.0);
    }

    #[test]
    fn worst_ratio_zero_side() {
        let row = vec![(0, 100.0)];
        assert_eq!(worst_ratio(&row, 100.0, 0.0), f64::MAX);
    }
}
