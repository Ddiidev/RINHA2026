module main

import json
import os

fn approx_quant(q i16, expected f64, tolerance f64) bool {
	got := f64(q) / quant_scale
	return got >= expected - tolerance && got <= expected + tolerance
}

fn test_vectorize_doc_legit_example() {
	raw := '{"id":"tx-1329056812","transaction":{"amount":41.12,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":82.24,"tx_count_24h":3,"known_merchants":["MERC-003","MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5411","avg_amount":60.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.23},"last_transaction":null}'
	payload := json.decode(FraudRequest, raw)!
	v := vectorize(payload)!
	assert approx_quant(v[0], 0.0041, 0.0001)
	assert approx_quant(v[1], 0.1667, 0.0001)
	assert approx_quant(v[2], 0.05, 0.0001)
	assert approx_quant(v[3], 0.7826, 0.0001)
	assert approx_quant(v[4], 0.3333, 0.0001)
	assert v[5] == missing_quant
	assert v[6] == missing_quant
	assert approx_quant(v[7], 0.0292, 0.0001)
	assert approx_quant(v[8], 0.15, 0.0001)
	assert approx_quant(v[9], 0.0, 0.0001)
	assert approx_quant(v[10], 1.0, 0.0001)
	assert approx_quant(v[11], 0.0, 0.0001)
	assert approx_quant(v[12], 0.15, 0.0001)
	assert approx_quant(v[13], 0.006, 0.0001)
}

fn test_reference_index_round_trip() {
	tmp_bin := 'data/example-test.bin'
	index := load_example_index('resources/example-references.json')!
	assert index.count > 0
	write_reference_index(index, tmp_bin)!
	index2 := load_reference_index(tmp_bin)!
	assert index2.count == index.count
	assert index2.labels == index.labels
	assert index2.vectors.len == index.vectors.len
	os.rm(tmp_bin) or {}
}
