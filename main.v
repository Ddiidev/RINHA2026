module main

import json
import net.http
import os
import time

struct ApiHandler {
	index ReferenceIndex
}

fn (mut handler ApiHandler) handle(req http.Request) http.Response {
	path := req.url.all_before('?')
	if req.method == .get && path == '/ready' {
		if handler.index.count == 0 {
			return text_response(.service_unavailable, 'loading')
		}
		return text_response(.ok, 'ok')
	}
	if req.method == .post && path == '/fraud-score' {
		payload := json.decode(FraudRequest, req.data) or {
			return fraud_response(default_response())
		}
		query := vectorize(payload) or { return fraud_response(default_response()) }
		return fraud_response(handler.index.decide(query))
	}
	return text_response(.not_found, 'not found')
}

fn fraud_response(response FraudResponse) http.Response {
	return json_response(.ok, json.encode(response))
}

fn json_response(status http.Status, body string) http.Response {
	mut res := http.Response{
		body:   body
		header: http.new_header_from_map({
			.content_type: 'application/json'
		})
	}
	res.set_status(status)
	return res
}

fn text_response(status http.Status, body string) http.Response {
	mut res := http.Response{
		body:   body
		header: http.new_header_from_map({
			.content_type: 'text/plain'
		})
	}
	res.set_status(status)
	return res
}

fn main() {
	args := os.args
	if args.len > 1 && args[1] == 'preprocess' {
		input := if args.len > 2 { args[2] } else { 'resources/references.json.gz' }
		output := if args.len > 3 { args[3] } else { 'data/references.bin' }
		preprocess_references(input, output) or {
			eprintln('preprocess failed: ${err}')
			exit(1)
		}
		return
	}

	port := resolve_port(args)
	index_path := resolve_index_path()
	eprintln('loading index from ${index_path}')
	index := load_reference_index(index_path) or {
		eprintln('could not load ${index_path}: ${err}')
		eprintln('falling back to resources/example-references.json')
		load_example_index('resources/example-references.json') or {
			eprintln('could not load example index: ${err}')
			ReferenceIndex{}
		}
	}
	if index.count == 0 {
		eprintln('no reference index loaded; /ready will return 503')
	}
	mut server := &http.Server{
		addr:                    '0.0.0.0:${port}'
		handler:                 ApiHandler{
			index: index
		}
		read_timeout:            2 * time.second
		write_timeout:           2 * time.second
		accept_timeout:          500 * time.millisecond
		worker_num:              1
		max_keep_alive_requests: 200
		show_startup_message:    false
	}
	server.listen_and_serve()
}

fn resolve_port(args []string) int {
	if args.len > 2 && args[1] == 'serve' {
		return args[2].int()
	}
	env_port := os.getenv('PORT')
	if env_port != '' {
		return env_port.int()
	}
	return 8080
}

fn resolve_index_path() string {
	from_env := os.getenv('RINHA_REFERENCES_BIN')
	if from_env != '' {
		return from_env
	}
	if os.exists('data/references.bin') {
		return 'data/references.bin'
	}
	return '/app/data/references.bin'
}
