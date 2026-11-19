use eframe::egui::{Pos2, Rect};
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

/// One tile of a nested layout. Tiles are in depth-first order: a tile's
/// descendants are exactly `index + 1 .. subtree_end`.
#[derive(Clone, Copy, Debug)]
pub struct Tile {
    /// The tile's full cell; it is drawn shrunk by [`TILE_INSET`].
    pub rect: Rect,
    /// Index of this tile's node among its parent node's children.
    pub child: u32,
    /// Index of the enclosing tile, or -1 for children of the focused folder.
    pub parent: i32,
    /// One past the last descendant's index.
    pub subtree_end: u32,
    /// 0 for children of the focused folder, 1 for theirs, ...
    pub depth: u8,
    /// A directory drawn as a frame with a header and its children inside.
    pub shows_children: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NestedOptions {
    /// Levels of tiles drawn (1 = just the focused folder's children).
    pub max_depth: usize,
    /// Height of a nested folder's header strip, inside its frame.
    pub header: f32,
    /// Gap between a nested folder's frame and its children.
    pub inset: f32,
    /// A folder shows its children only when its cell is at least this big.
    pub min_nested_width: f32,
    pub min_nested_height: f32,
}

impl Default for NestedOptions {
    fn default() -> Self {
        NestedOptions {
            max_depth: 4,
            header: 18.0,
            inset: 2.0,
            min_nested_width: 56.0,
            min_nested_height: 44.0,
        }
    }
}

/// Squarified, nested layout of `focus`'s children (sorted by size, as the
/// scanner keeps them) in `bounds`. Folders big enough show their own
/// children inside a frame, down to `max_depth` levels. Like
/// [`layout_visible`], tiles under 1px are left out, and since children are
/// sorted, a folder's layout stops at its first row thinner than that.
pub fn layout_nested(
    focus: &crate::scanner::FileNode,
    bounds: Rect,
    options: &NestedOptions,
) -> Vec<Tile> {
    let mut tiles = Vec::with_capacity(focus.children.len().min(1 << 16) * 2);
    // One scratch buffer per depth, reused across folders.
    let mut scratch: Vec<Vec<Rect>> = Vec::new();
    nest(focus, bounds, 0, -1, options, &mut tiles, &mut scratch);
    tiles
}

fn nest(
    node: &crate::scanner::FileNode,
    bounds: Rect,
    depth: usize,
    parent: i32,
    options: &NestedOptions,
    tiles: &mut Vec<Tile>,
    scratch: &mut Vec<Vec<Rect>>,
) {
    if scratch.len() <= depth {
        scratch.push(Vec::new());
    }
    let mut rects = std::mem::take(&mut scratch[depth]);
    rects.clear();
    squarify_children(&node.children, bounds, &mut rects);

    for (i, &rect) in rects.iter().enumerate() {
        let frame = rect.shrink(TILE_INSET);
        if frame.width() < 1.0 || frame.height() < 1.0 {
            continue;
        }
        let child = &node.children[i];
        let index = tiles.len();
        let nests = child.is_dir
            && !child.children.is_empty()
            && depth + 1 < options.max_depth
            && rect.width() >= options.min_nested_width
            && rect.height() >= options.min_nested_height;
        tiles.push(Tile {
            rect,
            child: i as u32,
            parent,
            subtree_end: index as u32 + 1,
            depth: depth.min(u8::MAX as usize) as u8,
            shows_children: nests,
        });
        if nests {
            let inner = Rect::from_min_max(
                pos2(frame.min.x + options.inset, frame.min.y + options.header),
                pos2(frame.max.x - options.inset, frame.max.y - options.inset),
            );
            if inner.width() >= 1.0 && inner.height() >= 1.0 {
                nest(
                    child,
                    inner,
                    depth + 1,
                    index as i32,
                    options,
                    tiles,
                    scratch,
                );
            }
            tiles[index].subtree_end = tiles.len() as u32;
        }
    }
    scratch[depth] = rects;
}

/// Squarified rects for `children` (sorted largest first), one per child in
/// order, stopping at the first zero size or the first row thinner than 1px
/// (nothing after it could be drawn).
fn squarify_children(children: &[crate::scanner::FileNode], bounds: Rect, out: &mut Vec<Rect>) {
    let count = children.iter().take_while(|c| c.size > 0).count();
    let total: f64 = children[..count].iter().map(|c| c.size as f64).sum();
    if count == 0 || total <= 0.0 || bounds.width() <= 0.0 || bounds.height() <= 0.0 {
        return;
    }
    let scale = bounds.width() as f64 * bounds.height() as f64 / total;
    let area = |i: usize| children[i].size as f64 * scale;
    let (mut x, mut y) = (bounds.min.x as f64, bounds.min.y as f64);
    let (mut w, mut h) = (bounds.width() as f64, bounds.height() as f64);
    let mut start = 0;
    while start < count && w > 0.0 && h > 0.0 {
        if start == count - 1 {
            out.push(Rect::from_min_size(
                pos2(x as f32, y as f32),
                vec2(w as f32, h as f32),
            ));
            break;
        }
        let horizontal = w >= h;
        let side = if horizontal { h } else { w };
        let max_area = area(start);
        let mut row_sum = 0.0;
        let mut best = f64::MAX;
        let mut end = start;
        while end < count {
            let a = area(end);
            let sum = row_sum + a;
            let worst = worst_ratio_from_extremes(max_area, a, sum, side);
            if worst <= best {
                best = worst;
                row_sum = sum;
                end += 1;
            } else {
                break;
            }
        }
        let thickness = row_sum / side;
        if thickness < 1.0 {
            break;
        }
        let mut offset = 0.0;
        for i in start..end {
            let length = area(i) / thickness;
            out.push(if horizontal {
                Rect::from_min_size(
                    pos2(x as f32, (y + offset) as f32),
                    vec2(thickness as f32, length as f32),
                )
            } else {
                Rect::from_min_size(
                    pos2((x + offset) as f32, y as f32),
                    vec2(length as f32, thickness as f32),
                )
            });
            offset += length;
        }
        if horizontal {
            x += thickness;
            w -= thickness;
        } else {
            y += thickness;
            h -= thickness;
        }
        start = end;
    }
}

/// The node of every tile, in tile order: one pass, since each tile's
/// parent comes before it.
pub fn tile_nodes<'a>(
    tiles: &[Tile],
    focus: &'a crate::scanner::FileNode,
) -> Vec<&'a crate::scanner::FileNode> {
    let mut nodes: Vec<&crate::scanner::FileNode> = Vec::with_capacity(tiles.len());
    for tile in tiles {
        let parent = if tile.parent < 0 {
            focus
        } else {
            nodes[tile.parent as usize]
        };
        nodes.push(&parent.children[tile.child as usize]);
    }
    nodes
}

/// Child indices leading from the focused folder to tile `index`.
pub fn tile_path(tiles: &[Tile], index: usize) -> Vec<usize> {
    let mut path = Vec::new();
    let mut current = index as i32;
    while current >= 0 {
        let tile = &tiles[current as usize];
        path.push(tile.child as usize);
        current = tile.parent;
    }
    path.reverse();
    path
}

/// The deepest tile containing `point`, or `None`.
pub fn hit_test(tiles: &[Tile], point: Pos2) -> Option<usize> {
    let mut found = None;
    let mut i = 0;
    let mut end = tiles.len();
    while i < end {
        let tile = &tiles[i];
        if contains(tile.rect, point) {
            found = Some(i);
            end = tile.subtree_end as usize;
            i += 1;
        } else {
            i = tile.subtree_end as usize;
        }
    }
    found
}

fn contains(rect: Rect, p: Pos2) -> bool {
    p.x >= rect.min.x && p.x < rect.max.x && p.y >= rect.min.y && p.y < rect.max.y
}

fn is_ancestor(tiles: &[Tile], ancestor: usize, index: usize) -> bool {
    let mut current = index as i32;
    while current >= 0 {
        if current as usize == ancestor {
            return true;
        }
        current = tiles[current as usize].parent;
    }
    false
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

/// The tile an arrow key moves the selection to: probe just past the
/// selected tile's edge, take the tile there at the selection's depth, and
/// keep going while that is the selection or one of its ancestors (a header
/// strip or gap). Crossing another folder's frame looks for a tile at the
/// same depth inside it. `None` at the edge of the map.
pub fn move_selection(
    tiles: &[Tile],
    bounds: Rect,
    index: usize,
    direction: Direction,
) -> Option<usize> {
    let tile = tiles[index];
    let r = tile.rect;
    let (mut probe, step) = match direction {
        Direction::Left => (pos2(r.min.x - 0.5, r.center().y), vec2(-1.0, 0.0)),
        Direction::Right => (pos2(r.max.x + 0.5, r.center().y), vec2(1.0, 0.0)),
        Direction::Up => (pos2(r.center().x, r.min.y - 0.5), vec2(0.0, -1.0)),
        Direction::Down => (pos2(r.center().x, r.max.y + 0.5), vec2(0.0, 1.0)),
    };
    // A shallower folder frame crossed on the way, used if no tile at the
    // selection's depth turns up beyond it.
    let mut fallback: Option<usize> = None;
    while contains(bounds, probe) {
        if let Some(mut hit) = hit_test(tiles, probe) {
            while tiles[hit].depth > tile.depth && tiles[hit].parent >= 0 {
                hit = tiles[hit].parent as usize;
            }
            if !is_ancestor(tiles, hit, index) {
                if let Some(candidate) = fallback {
                    if !is_ancestor(tiles, candidate, hit) {
                        // Left that folder without finding anything inside.
                        return Some(candidate);
                    }
                }
                if tiles[hit].depth == tile.depth || !tiles[hit].shows_children {
                    return Some(hit);
                }
                // The header or frame of another folder: look inside it.
                if fallback.is_none() {
                    fallback = Some(hit);
                }
            } else if let Some(candidate) = fallback {
                return Some(candidate);
            }
        } else if let Some(candidate) = fallback {
            return Some(candidate);
        }
        probe += step;
    }
    fallback
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

    fn file(name: &str, size: u64) -> crate::scanner::FileNode {
        crate::scanner::FileNode::new(name.into(), size, Vec::new(), false)
    }

    fn dir(name: &str, children: Vec<crate::scanner::FileNode>) -> crate::scanner::FileNode {
        let size = children.iter().map(|c| c.size).sum();
        crate::scanner::FileNode::new(name.into(), size, children, true)
    }

    fn nested_tree() -> crate::scanner::FileNode {
        dir(
            "root",
            vec![
                dir(
                    "big",
                    vec![
                        file("a", 400),
                        file("b", 200),
                        dir("inner", vec![file("c", 100)]),
                    ],
                ),
                file("d", 200),
                file("e", 100),
            ],
        )
    }

    #[test]
    fn nested_layout_is_depth_first_with_subtree_ranges() {
        let root = nested_tree();
        let bounds = make_bounds(0.0, 0.0, 800.0, 600.0);
        let tiles = layout_nested(&root, bounds, &NestedOptions::default());
        let nodes = tile_nodes(&tiles, &root);
        let names: Vec<&str> = nodes.iter().map(|n| n.name.as_str()).collect();
        assert_eq!(names, ["big", "a", "b", "inner", "c", "d", "e"]);
        assert!(tiles[0].shows_children);
        assert_eq!(tiles[0].subtree_end, 5);
        assert_eq!(tiles[3].parent, 0);
        assert_eq!(tiles[4].depth, 2);
        assert_eq!(tile_path(&tiles, 4), vec![0, 2, 0]);
        // Children sit inside their folder's frame, below its header.
        let frame = tiles[0].rect.shrink(TILE_INSET);
        for t in &tiles[1..5] {
            assert!(t.rect.min.y >= frame.min.y + NestedOptions::default().header - 0.01);
            assert!(frame.expand(0.01).contains_rect(t.rect));
        }
    }

    #[test]
    fn depth_one_is_flat() {
        let root = nested_tree();
        let options = NestedOptions {
            max_depth: 1,
            ..NestedOptions::default()
        };
        let tiles = layout_nested(&root, make_bounds(0.0, 0.0, 800.0, 600.0), &options);
        assert_eq!(tiles.len(), 3);
        assert!(tiles.iter().all(|t| !t.shows_children && t.depth == 0));
    }

    #[test]
    fn hit_test_finds_the_deepest_tile() {
        let root = nested_tree();
        let tiles = layout_nested(
            &root,
            make_bounds(0.0, 0.0, 800.0, 600.0),
            &NestedOptions::default(),
        );
        // Inside "c", nested in "inner" in "big".
        let c = tiles[4].rect.center();
        assert_eq!(hit_test(&tiles, c), Some(4));
        // On "big"'s header strip: the folder itself.
        let header = pos2(tiles[0].rect.center().x, tiles[0].rect.min.y + 8.0);
        assert_eq!(hit_test(&tiles, header), Some(0));
        assert_eq!(hit_test(&tiles, pos2(-5.0, 5.0)), None);
    }

    #[test]
    fn arrows_move_between_neighbours_at_the_same_depth() {
        let root = nested_tree();
        let bounds = make_bounds(0.0, 0.0, 800.0, 600.0);
        let tiles = layout_nested(&root, bounds, &NestedOptions::default());
        let names: Vec<&str> = tile_nodes(&tiles, &root)
            .iter()
            .map(|n| n.name.as_str())
            .collect();
        // From each top-level tile, every move lands on another top-level
        // tile or nowhere; it never stays put.
        for i in [0usize, 5, 6] {
            for d in [
                Direction::Left,
                Direction::Right,
                Direction::Up,
                Direction::Down,
            ] {
                if let Some(j) = move_selection(&tiles, bounds, i, d) {
                    assert_ne!(j, i, "{} {d:?}", names[i]);
                    assert_eq!(tiles[j].depth, 0, "{} {d:?} -> {}", names[i], names[j]);
                }
            }
        }
        // Inside a folder, moves reach the folder's other children.
        let a = 1;
        let reachable: Vec<usize> = [
            Direction::Left,
            Direction::Right,
            Direction::Up,
            Direction::Down,
        ]
        .into_iter()
        .filter_map(|d| move_selection(&tiles, bounds, a, d))
        .collect();
        assert!(reachable
            .iter()
            .any(|&j| names[j] == "b" || names[j] == "inner"));
    }

    #[test]
    fn worst_ratio_zero_side() {
        let row = vec![(0, 100.0)];
        assert_eq!(worst_ratio(&row, 100.0, 0.0), f64::MAX);
    }
}
