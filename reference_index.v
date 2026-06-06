module main

import compress.gzip
import math
import os

// "RINHA26I" = IVF-based index (v2). Replaces flat "RINHA26B".
const index_magic = 'RINHA26I'

// IVF hyperparameters (tunable without changing the binary format).
const ivf_k = 1024       // Voronoi cells (centroids)
const ivf_nprobe = 16    // cells probed per query
const kmeans_iters = 20  // K-Means training iterations
const kmeans_sample = 30000 // training sample size (deterministic)

// ReferenceIndex holds either a single-cell brute-force index (k=1, used
// for the small example files) or a full IVF index (k=1024, used in prod).
struct ReferenceIndex {
	k            int   // number of Voronoi cells
	count        int   // total reference vectors
	centroids    []i16 // k * vector_dims quantized centroids
	cell_sizes   []int // number of vectors per cell [k]
	cell_offsets []int // start row in vectors/labels for each cell [k]
	vectors      []i16 // count * vector_dims, grouped by cell
	labels       []u8  // count labels, grouped by cell
}

// decide runs the IVF approximate KNN (nprobe cells) and votes on fraud.
// Falls back to brute-force when k == 1 (example/test indexes).
fn (idx ReferenceIndex) decide(query []i16) FraudResponse {
	if idx.count == 0 {
		return default_response()
	}

	nprobe := if ivf_nprobe < idx.k { ivf_nprobe } else { idx.k }

	// --- 1. Find nprobe nearest centroids ---
	mut probe_cells := []int{len: nprobe}
	if idx.k == 1 {
		probe_cells[0] = 0
	} else {
		mut top_dists := []i64{len: nprobe, init: max_i64}
		mut top_cells := []int{len: nprobe}
		for c in 0 .. idx.k {
			c_base := c * vector_dims
			mut dist := i64(0)
			for dim in 0 .. vector_dims {
				diff := i64(idx.centroids[c_base + dim]) - i64(query[dim])
				dist += diff * diff
			}
			if dist < top_dists[nprobe - 1] {
				mut pos := nprobe - 1
				for pos > 0 && dist < top_dists[pos - 1] {
					top_dists[pos] = top_dists[pos - 1]
					top_cells[pos] = top_cells[pos - 1]
					pos--
				}
				top_dists[pos] = dist
				top_cells[pos] = c
			}
		}
		probe_cells = top_cells.clone()
	}

	// --- 2. KNN top-5 within the probed cells ---
	mut top5_dist := [i64(max_i64), max_i64, max_i64, max_i64, max_i64]
	mut top5_label := [u8(0), 0, 0, 0, 0]
	for cell_id in probe_cells {
		cell_start := idx.cell_offsets[cell_id]
		cell_count := idx.cell_sizes[cell_id]
		for row in 0 .. cell_count {
			g := cell_start + row
			g_base := g * vector_dims
			mut dist := i64(0)
			for dim in 0 .. vector_dims {
				diff := i64(idx.vectors[g_base + dim]) - i64(query[dim])
				dist += diff * diff
			}
			if dist < top5_dist[4] {
				mut pos := 4
				for pos > 0 && dist < top5_dist[pos - 1] {
					top5_dist[pos] = top5_dist[pos - 1]
					top5_label[pos] = top5_label[pos - 1]
					pos--
				}
				top5_dist[pos] = dist
				top5_label[pos] = idx.labels[g]
			}
		}
	}

	mut frauds := 0
	for label in top5_label {
		if label == 1 {
			frauds++
		}
	}
	score := f64(frauds) / 5.0
	return FraudResponse{
		approved:    score < 0.6
		fraud_score: score
	}
}

// ─── Pre-processing ───────────────────────────────────────────────────────────

fn preprocess_references(input string, output string) ! {
	eprintln('reading ${input}')
	raw := os.read_bytes(input)!
	data := if input.ends_with('.gz') {
		eprintln('decompressing gzip')
		gzip.decompress(raw, gzip.DecompressParams{})!
	} else {
		raw
	}
	eprintln('parsing references')
	flat := parse_references_json(data)!
	eprintln('building IVF index: K=${ivf_k}, nprobe=${ivf_nprobe}, n=${flat.count}')
	index := build_ivf_index(flat)
	eprintln('writing ${output}')
	write_reference_index(index, output)!
	eprintln('done: ${index.count} vectors in ${index.k} cells')
}

// build_ivf_index trains K-Means on a sample, then assigns all vectors to
// cells and packs them into contiguous memory grouped by cell.
fn build_ivf_index(flat ReferenceIndex) ReferenceIndex {
	n := flat.count
	k := if ivf_k < n { ivf_k } else { n }

	// Training sample: deterministic, evenly spaced.
	sample_size := if kmeans_sample < n { kmeans_sample } else { n }
	step := if sample_size < n { n / sample_size } else { 1 }
	eprintln('  K-Means: K=${k}, sample_size=${sample_size}, step=${step}')

	// ── Init centroids: k evenly-spaced sample vectors ──
	mut centroids_f := []f64{len: k * vector_dims}
	for c in 0 .. k {
		sample_row := (c * sample_size / k) * step
		src_base := sample_row * vector_dims
		c_base := c * vector_dims
		for dim in 0 .. vector_dims {
			centroids_f[c_base + dim] = f64(flat.vectors[src_base + dim])
		}
	}

	mut assignments := []int{len: sample_size}

	// ── K-Means iterations ──
	for iter in 0 .. kmeans_iters {
		mut changed := 0
		// Assignment step
		for s in 0 .. sample_size {
			src_base := (s * step) * vector_dims
			mut best_dist := f64(1e30)
			mut best_c := 0
			for c in 0 .. k {
				c_base := c * vector_dims
				mut dist := 0.0
				for dim in 0 .. vector_dims {
					diff := f64(flat.vectors[src_base + dim]) - centroids_f[c_base + dim]
					dist += diff * diff
				}
				if dist < best_dist {
					best_dist = dist
					best_c = c
				}
			}
			if assignments[s] != best_c {
				assignments[s] = best_c
				changed++
			}
		}
		eprintln('  iter ${iter + 1}/${kmeans_iters}: ${changed} reassignments')
		if changed == 0 {
			break
		}
		// Update step: recompute centroids as cluster means
		mut sums := []f64{len: k * vector_dims}
		mut counts := []int{len: k}
		for s in 0 .. sample_size {
			c := assignments[s]
			src_base := (s * step) * vector_dims
			c_base := c * vector_dims
			for dim in 0 .. vector_dims {
				sums[c_base + dim] += f64(flat.vectors[src_base + dim])
			}
			counts[c]++
		}
		for c in 0 .. k {
			if counts[c] == 0 {
				continue
			}
			c_base := c * vector_dims
			cnt := f64(counts[c])
			for dim in 0 .. vector_dims {
				centroids_f[c_base + dim] = sums[c_base + dim] / cnt
			}
		}
	}

	// Quantize final centroids to i16 (same domain as vectors)
	mut centroids_q := []i16{len: k * vector_dims}
	for i in 0 .. k * vector_dims {
		v := centroids_f[i]
		centroids_q[i] = if v > 32767.0 {
			i16(32767)
		} else if v < -32768.0 {
			i16(-32768)
		} else {
			i16(int(v))
		}
	}

	// ── Assign ALL n vectors to their nearest centroid ──
	eprintln('  assigning all ${n} vectors to cells...')
	mut cell_assignments := []int{len: n}
	mut cell_counts := []int{len: k}
	for row in 0 .. n {
		if row % 100000 == 0 && row > 0 {
			eprintln('  ... ${row}/${n}')
		}
		row_base := row * vector_dims
		mut best_dist := i64(max_i64)
		mut best_c := 0
		for c in 0 .. k {
			c_base := c * vector_dims
			mut dist := i64(0)
			for dim in 0 .. vector_dims {
				diff := i64(flat.vectors[row_base + dim]) - i64(centroids_q[c_base + dim])
				dist += diff * diff
			}
			if dist < best_dist {
				best_dist = dist
				best_c = c
			}
		}
		cell_assignments[row] = best_c
		cell_counts[best_c]++
	}
	eprintln('  assignment complete')

	// ── Compute cell offsets ──
	mut cell_offsets := []int{len: k}
	mut off := 0
	for c in 0 .. k {
		cell_offsets[c] = off
		off += cell_counts[c]
	}

	// ── Pack vectors and labels grouped by cell ──
	mut packed_vectors := []i16{len: n * vector_dims}
	mut packed_labels := []u8{len: n}
	mut fill_pos := []int{len: k} // per-cell write cursor

	for row in 0 .. n {
		c := cell_assignments[row]
		dst_row := cell_offsets[c] + fill_pos[c]
		fill_pos[c]++
		src_base := row * vector_dims
		dst_base := dst_row * vector_dims
		for dim in 0 .. vector_dims {
			packed_vectors[dst_base + dim] = flat.vectors[src_base + dim]
		}
		packed_labels[dst_row] = flat.labels[row]
	}

	return ReferenceIndex{
		k:            k
		count:        n
		centroids:    centroids_q
		cell_sizes:   cell_counts
		cell_offsets: cell_offsets
		vectors:      packed_vectors
		labels:       packed_labels
	}
}

// ─── I/O ─────────────────────────────────────────────────────────────────────

// Binary layout:
//   "RINHA26I"       8 bytes  magic
//   k                u32 LE   centroid count
//   count            u32 LE   total vector count
//   cell_sizes[0..k] u32 LE   (k entries)
//   centroids        i16[k * vector_dims]
//   vectors          i16[count * vector_dims]  (grouped by cell)
//   labels           u8[count]                 (grouped by cell)

fn write_reference_index(index ReferenceIndex, output string) ! {
	dir := os.dir(output)
	if dir != '.' && dir != '' {
		os.mkdir_all(dir, os.MkdirParams{})!
	}
	mut f := os.create(output)!
	// Magic
	f.write_string(index_magic)!
	// k and count
	mut hdr := []u8{len: 8}
	write_u32_le(mut hdr, 0, u32(index.k))
	write_u32_le(mut hdr, 4, u32(index.count))
	f.write(hdr)!
	// Cell sizes
	mut cs_buf := []u8{len: index.k * 4}
	for c in 0 .. index.k {
		write_u32_le(mut cs_buf, c * 4, u32(index.cell_sizes[c]))
	}
	f.write(cs_buf)!
	// Centroids (quantized i16)
	unsafe {
		f.write_full_buffer(index.centroids.data, usize(index.centroids.len * int(sizeof(i16))))!
	}
	// Vectors (contiguous, grouped by cell)
	unsafe {
		f.write_full_buffer(index.vectors.data, usize(index.vectors.len * int(sizeof(i16))))!
	}
	// Labels (grouped by cell)
	f.write(index.labels)!
	f.flush()
	f.close()
}

fn load_reference_index(path string) !ReferenceIndex {
	if !os.exists(path) {
		return error('index file not found')
	}
	mut f := os.open(path)!
	// Magic
	mut magic := []u8{len: index_magic.len}
	n_magic := f.read(mut magic)!
	if n_magic != index_magic.len || magic.bytestr() != index_magic {
		f.close()
		return error('unrecognized index format: ${magic.bytestr()} (expected ${index_magic})')
	}
	// k and count
	mut hdr := []u8{len: 8}
	if f.read(mut hdr)! != 8 {
		f.close()
		return error('truncated header')
	}
	k := int(read_u32_le(hdr, 0))
	count := int(read_u32_le(hdr, 4))
	// Cell sizes
	mut cs_buf := []u8{len: k * 4}
	if f.read(mut cs_buf)! != k * 4 {
		f.close()
		return error('truncated cell sizes')
	}
	mut cell_sizes := []int{len: k}
	for c in 0 .. k {
		cell_sizes[c] = int(read_u32_le(cs_buf, c * 4))
	}
	// Cell offsets (derived from sizes)
	mut cell_offsets := []int{len: k}
	mut off := 0
	for c in 0 .. k {
		cell_offsets[c] = off
		off += cell_sizes[c]
	}
	// Centroids
	mut centroids := []i16{len: k * vector_dims}
	unsafe {
		want_c := k * vector_dims * int(sizeof(i16))
		got_c := f.read_into_ptr(&u8(centroids.data), want_c)!
		if got_c != want_c {
			f.close()
			return error('truncated centroids')
		}
	}
	// Vectors
	mut vectors := []i16{len: count * vector_dims}
	unsafe {
		want_v := count * vector_dims * int(sizeof(i16))
		got_v := f.read_into_ptr(&u8(vectors.data), want_v)!
		if got_v != want_v {
			f.close()
			return error('truncated vectors')
		}
	}
	// Labels
	mut labels := []u8{len: count}
	if f.read(mut labels)! != count {
		f.close()
		return error('truncated labels')
	}
	f.close()
	return ReferenceIndex{
		k:            k
		count:        count
		centroids:    centroids
		cell_sizes:   cell_sizes
		cell_offsets: cell_offsets
		vectors:      vectors
		labels:       labels
	}
}

fn load_example_index(path string) !ReferenceIndex {
	data := os.read_bytes(path)!
	return parse_references_json(data)
}

// parse_references_json parses a JSON reference file and returns a k=1
// (single-cell / brute-force) ReferenceIndex suitable for small datasets.
fn parse_references_json(data []u8) !ReferenceIndex {
	mut pos := 0
	mut vectors := []i16{cap: 1024}
	mut labels := []u8{cap: 1024}
	for {
		vector_key := find_sub(data, pos, '"vector"')
		if vector_key < 0 {
			break
		}
		mut i := find_byte(data, vector_key, `[`)!
		i++
		for _ in 0 .. vector_dims {
			value, next_i := parse_number(data, i)!
			vectors << quantize_value(value)
			i = skip_value_separator(data, next_i)
		}
		label_key := find_sub(data, i, '"label"')
		if label_key < 0 {
			return error('missing label')
		}
		colon := find_byte(data, label_key, `:`)!
		quote := find_byte(data, colon, `"`)!
		label_start := quote + 1
		labels << if starts_with_at(data, label_start, 'fraud') { u8(1) } else { u8(0) }
		pos = label_start + 5
	}
	if labels.len * vector_dims != vectors.len {
		return error('invalid parsed reference lengths')
	}
	count := labels.len
	// Single-cell index: centroid = first vector (or zero if empty)
	mut centroid := []i16{len: vector_dims}
	if count > 0 {
		for dim in 0 .. vector_dims {
			centroid[dim] = vectors[dim]
		}
	}
	mut cell_sizes := []int{len: 1}
	cell_sizes[0] = count
	mut cell_offsets := []int{len: 1}
	cell_offsets[0] = 0
	return ReferenceIndex{
		k:            1
		count:        count
		centroids:    centroid
		cell_sizes:   cell_sizes
		cell_offsets: cell_offsets
		vectors:      vectors
		labels:       labels
	}
}

// ─── Parsing helpers ──────────────────────────────────────────────────────────

fn parse_number(data []u8, start int) !(f64, int) {
	mut pos := skip_ws(data, start)
	mut sign := 1.0
	if pos < data.len && data[pos] == `-` {
		sign = -1.0
		pos++
	}
	mut value := 0.0
	mut seen_digit := false
	for pos < data.len && data[pos] >= `0` && data[pos] <= `9` {
		value = value * 10.0 + f64(data[pos] - `0`)
		pos++
		seen_digit = true
	}
	if pos < data.len && data[pos] == `.` {
		pos++
		mut scale := 0.1
		for pos < data.len && data[pos] >= `0` && data[pos] <= `9` {
			value += f64(data[pos] - `0`) * scale
			scale *= 0.1
			pos++
			seen_digit = true
		}
	}
	if !seen_digit {
		return error('expected number')
	}
	if pos < data.len && (data[pos] == `e` || data[pos] == `E`) {
		pos++
		mut exp_sign := 1
		if pos < data.len && data[pos] == `-` {
			exp_sign = -1
			pos++
		} else if pos < data.len && data[pos] == `+` {
			pos++
		}
		mut exp := 0
		for pos < data.len && data[pos] >= `0` && data[pos] <= `9` {
			exp = exp * 10 + int(data[pos] - `0`)
			pos++
		}
		value *= math.pow(10.0, f64(exp_sign * exp))
	}
	return sign * value, pos
}

fn skip_ws(data []u8, start int) int {
	mut pos := start
	for pos < data.len
		&& (data[pos] == ` ` || data[pos] == `\n` || data[pos] == `\r` || data[pos] == `\t`) {
		pos++
	}
	return pos
}

fn skip_value_separator(data []u8, start int) int {
	mut pos := start
	for pos < data.len {
		match data[pos] {
			` `, `\n`, `\r`, `\t`, `,`, `]` { pos++ }
			else { break }
		}
	}
	return pos
}

fn find_byte(data []u8, start int, needle u8) !int {
	for i in start .. data.len {
		if data[i] == needle {
			return i
		}
	}
	return error('byte not found')
}

fn find_sub(data []u8, start int, token string) int {
	if token.len == 0 || start >= data.len {
		return -1
	}
	limit := data.len - token.len
	for i in start .. limit + 1 {
		if data[i] != token[0] {
			continue
		}
		mut ok := true
		for j in 1 .. token.len {
			if data[i + j] != token[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

fn starts_with_at(data []u8, start int, token string) bool {
	if start + token.len > data.len {
		return false
	}
	for i in 0 .. token.len {
		if data[start + i] != token[i] {
			return false
		}
	}
	return true
}

fn read_u32_le(data []u8, pos int) u32 {
	return u32(data[pos]) | (u32(data[pos + 1]) << 8) | (u32(data[pos + 2]) << 16) | (u32(data[pos + 3]) << 24)
}

fn write_u32_le(mut data []u8, pos int, value u32) {
	data[pos] = u8(value & 0xff)
	data[pos + 1] = u8((value >> 8) & 0xff)
	data[pos + 2] = u8((value >> 16) & 0xff)
	data[pos + 3] = u8((value >> 24) & 0xff)
}
