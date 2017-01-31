#include "build.h"

namespace hagrid {

static __constant__ ivec3 grid_dims;
static __constant__ vec3  grid_min;
static __constant__ vec3  cell_size;
static __constant__ int   grid_shift;

/// Gets the component of the given vector on the specified axis
template <int axis, typename T>
__device__ T get(const tvec3<T>& v) {
    if (axis == 0) return v.x;
    else if (axis == 1) return v.y;
    else return v.z;
}

/// Returns true if an overlap with a neighboring cell is possible
template <int axis, bool dir>
__device__ bool overlap_possible(const Cell& cell) {
    if (dir)
        return get<axis>(cell.max) < get<axis>(grid_dims);
    else
        return get<axis>(cell.min) > 0;
}

/// Finds a value in a sorted range of references, returns its index or -1 if not present
__device__ __forceinline__ int bisection(const int* p, int c, int e) {
    int a = 0, b = c - 1;
    while (a <= b) {
        const int m = (a + b) / 2;
        const int f = p[m];
        if (f == e) return m;
        a = (f < e) ? m + 1 : a;
        b = (f > e) ? m - 1 : b;
    }
    return -1;
}

/// Determines if the given range of references is a subset of the other
__device__ __forceinline__ bool is_subset(const int* __restrict__ p0, int c0, const int* __restrict__ p1, int c1) {
    if (c1 > c0) return false;
    if (c1 == 0) return true;

    int i = 0, j = 0;

    do {
        const int a = p0[i];
        const int b = p1[j];
        if (b < a) return false;
        j += (a == b);
        i++;
    } while (i < c0 & j < c1);

    return j == c1;
}

/// Finds the maximum overlap possible for one cell
template <int axis, bool dir, bool subset_only, typename Primitive>
__device__ int find_overlap(const Entry* __restrict__ entries,
                            const int* __restrict__ refs,
                            const Primitive* prims,
                            const Cell* cells,
                            const Cell& cell) {
    constexpr int axis1 = (axis + 1) % 3;
    constexpr int axis2 = (axis + 2) % 3;

    int d = 0;
    if (overlap_possible<axis, dir>(cell)) {
        d = dir ? get<axis>(grid_dims) : -get<axis>(grid_dims);

        int k1, k2 = get<axis2>(grid_dims);
        int i = get<axis1>(cell.min);
        int j = get<axis2>(cell.min);
        while (true) {
            ivec3 next_cell;
            if (axis == 0) next_cell = ivec3(dir ? cell.max.x : cell.min.x - 1, i, j);
            if (axis == 1) next_cell = ivec3(j, dir ? cell.max.y : cell.min.y - 1, i);
            if (axis == 2) next_cell = ivec3(i, j, dir ? cell.max.z : cell.min.z - 1);

            auto next = load_cell(cells + lookup_entry(entries, grid_shift, grid_dims >> grid_shift, next_cell));
            if (subset_only) {
                if (is_subset(refs + cell.begin, cell.end - cell.begin,
                              refs + next.begin, next.end - next.begin)) {
                    d = dir
                        ? min(d, get<axis>(next.max) - get<axis>(cell.max))
                        : max(d, get<axis>(next.min) - get<axis>(cell.min));
                } else {
                    d = 0;
                }
            } else {
                auto min_bb = grid_min + vec3(cell.min) * cell_size;
                auto max_bb = grid_min + vec3(cell.max) * cell_size;

                d = dir
                    ? min(d, get<axis>(next.max) - get<axis>(cell.max))
                    : max(d, get<axis>(next.min) - get<axis>(cell.min));

                int first_ref = cell.begin;
                for (int p = next.begin; p < next.end; p++) {
                    auto ref = refs[p];
                    auto found = bisection(refs + first_ref, cell.end - first_ref, ref);
                    first_ref = found + 1 + first_ref;
                    // If the reference is not in the cell we try to expand
                    if (found < 0) {
                        auto prim = load_prim(prims + ref);
                        auto cur = dir ? max_bb : min_bb;
                        auto left = d, right = dir ? 1 : -1;
                        // Using bisection, find the offset by which we can overlap the neighbour
                        while (dir ? (left >= right) : (left <= right)) {
                            auto m = (left + right) / 2;
                            if (axis == 0) cur.x = grid_min.x + cell_size.x * ((dir ? cell.max.x : cell.min.x) + m);
                            if (axis == 1) cur.y = grid_min.y + cell_size.y * ((dir ? cell.max.y : cell.min.y) + m);
                            if (axis == 2) cur.z = grid_min.z + cell_size.z * ((dir ? cell.max.z : cell.min.z) + m);
                            if (intersect_prim_box(prim, dir ? BBox(min_bb, cur) : BBox(cur, max_bb))) {
                                left = m + (dir ? -1 : 1);
                            } else {
                                right = m + (dir ? 1 : -1);
                            }
                        }
                        d = left;
                        if (d == 0) break;
                    }
                }
            }

            if (d == 0) break;

            k1 = get<axis1>(next.max) - i;
            k2 = min(k2, get<axis2>(next.max) - j);

            i += k1;
            if (i >= get<axis1>(cell.max)) {
                i = get<axis1>(cell.min);
                j += k2;
                k2 = get<axis2>(grid_dims);
                if (j >= get<axis2>(cell.max)) {
                    break;
                }
            }
        }
    }

    return d;
}

template <int axis, bool subset_only, typename Primitive>
__global__ void overlap_step(const Entry* __restrict__ entries,
                             const int* __restrict__ refs,
                             const Primitive* prims,
                             const Cell* __restrict__ cells,
                             Cell* __restrict__ new_cells,
                             int* __restrict__ cell_flags,
                             int num_cells) {
    int id = threadIdx.x + blockDim.x * blockIdx.x;
    if (id >= num_cells || (cell_flags[id] & (1 << axis)) == 0)
        return;

    auto cell = load_cell(cells + id);
    auto ov1 = find_overlap<axis, false, subset_only>(entries, refs, prims, cells, cell);
    auto ov2 = find_overlap<axis, true,  subset_only>(entries, refs, prims, cells, cell);
    auto k = ov2 - ov1 ? 1 : 0;

    if (axis == 0) {
        cell.min.x += ov1;
        cell.max.x += ov2;
    }

    if (axis == 1) {
        cell.min.y += ov1;
        cell.max.y += ov2;
    }

    if (axis == 2) {
        cell.min.z += ov1;
        cell.max.z += ov2;
    }

    // If the cell has not been expanded, we will not process it next time
    cell_flags[id] = (k << axis) | (cell_flags[id] & ~(1 << axis));

    store_cell(new_cells + id, cell);
}

template <bool subset_only, typename Primitive>
void expansion_iter(Grid& grid, const Primitive* prims, Cell*& new_cells, int* cell_flags) {
    overlap_step<0, subset_only><<<round_div(grid.num_cells, 64), 64>>>(grid.entries, grid.ref_ids, prims, grid.cells, new_cells, cell_flags, grid.num_cells);
    std::swap(new_cells, grid.cells);
    overlap_step<1, subset_only><<<round_div(grid.num_cells, 64), 64>>>(grid.entries, grid.ref_ids, prims, grid.cells, new_cells, cell_flags, grid.num_cells);
    std::swap(new_cells, grid.cells);
    overlap_step<2, subset_only><<<round_div(grid.num_cells, 64), 64>>>(grid.entries, grid.ref_ids, prims, grid.cells, new_cells, cell_flags, grid.num_cells);
    std::swap(new_cells, grid.cells);
}

template <typename Primitive>
void expand(MemManager& mem, Grid& grid, const Primitive* prims, int iters) {
    auto new_cells  = mem.alloc<Cell>(grid.num_cells);
    auto cell_flags = mem.alloc<int>(grid.num_cells);
    mem.one(cell_flags, grid.num_cells);

    auto extents = grid.bbox.extents();
    auto dims = grid.dims << grid.shift;
    auto cell_size = extents / vec3(dims);

    set_global(hagrid::grid_dims,  &dims);
    set_global(hagrid::grid_min,   &grid.bbox.min);
    set_global(hagrid::cell_size,  &cell_size);
    set_global(hagrid::grid_shift, &grid.shift);

    for (int i = 0; i < iters - 1; i++)
        expansion_iter<true>(grid, prims, new_cells, cell_flags);
    expansion_iter<false>(grid, prims, new_cells, cell_flags);

    mem.free(cell_flags);
    mem.free(new_cells);
}

void expand_grid(MemManager& mem, Grid& grid, const Tri* tris, int iters) { expand(mem, grid, tris, iters); }

} // namespace hagrid