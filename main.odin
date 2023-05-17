package main

import "core:log"
import "core:encoding/json"
import "core:time"
import "core:fmt"
import "core:strconv"

import http "pkg/odin-http"

store: Store

// TODO: rebuild docker image from time to time to update odin.

// TODO: println() should add newline on front-end too.

// TODO: friendly share id's (snowflake?).
main :: proc() {
	context.logger = log.create_console_logger()

	store_init(&store)
	defer store_destroy(&store)

	sandbox_init()

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	router: http.Router
	http.router_init(&router)

	http.route_get(&router, "/api/share/(%d+)", http.handler(handle_get_share))
	http.route_get(&router, "/", http.handler(handle_index))
	http.route_get(&router, "/%d+", http.handler(handle_index))
    http.route_get(&router, "/favicon.ico", http.handler(handle_favicon))
	http.route_get(&router, "(.*)", http.handler(handle_static))

	post_router: http.Router
	http.router_init(&post_router)

	http.route_post(&post_router, "/api/exec", http.handler(handle_exec))
	http.route_post(&post_router, "/api/assemble", http.handler(handle_assemble))
	http.route_post(&post_router, "/api/share", http.handler(handle_share))

	// Rate limit the post router.
	limit_message := "Processing code is only allowed 10 times per minute."
	post_handler := http.router_handler(&post_router)
	post_rate_limited := http.middleware_rate_limit(
		&post_handler,
		&http.Rate_Limit_Opts{
			window = time.Minute,
			max = 10,
			on_limit = http.on_limit_message(&limit_message),
		},
	)

	// Make all post requests from the main router go to the rate limited post router.
	http.route_post(&router, ".*", post_rate_limited)

	route_handler := http.router_handler(&router)
	with_logger := http.middleware_logger(&route_handler, &http.Logger_Opts{log_time = true})

	log.warnf("Server stopped: %v", http.listen_and_serve(&s, &with_logger))
}


handle_exec :: proc(req: ^http.Request, res: ^http.Response) {
	body, err := http.request_body(req, MAX_CODE_BYTES)
	if err != nil {
		res.status = http.body_error_status(err)
		return
	}

	input, ok := body.(http.Body_Plain)
	if !ok {
		res.status = .Bad_Request
		return
	}

	if len(input) == 0 {
		res.status = .Bad_Request
		return
	}

	out, serr := sandbox_execute(transmute([]byte)input, .Execute, nil, req.allocator)
	respond_sandbox_result(res, out, serr)
}

Share_Json :: struct {
	code: string,
	opts: struct {
		optimization: string,
		target:       string,
		build_mode:   string,
	},
}

handle_assemble :: proc(req: ^http.Request, res: ^http.Response) {
    share_req, opts, ok := parse_share_json(req, res)
    if !ok do return

	if len(share_req.code) == 0 {
		res.status = .Bad_Request
		return
	}

	out, serr := sandbox_execute(transmute([]byte)share_req.code, .Assemble, opts, req.allocator)
	respond_sandbox_result(res, out, serr)
}

handle_share :: proc(req: ^http.Request, res: ^http.Response) {
    share_req, opts, ok := parse_share_json(req, res)
    if !ok do return

	if len(share_req.code) == 0 {
		res.status = .Bad_Request
		return
	}

	share := Share{
		code = share_req.code,
		opts = opts,
	}
	id, store_err, err_msg := store_create_share(&store, &share)
	switch store_err {
	case .None:
		http.respond_plain(res, fmt.tprintf("/%i", id))
	case .Invalid:
		http.respond_plain(res, err_msg)
		res.status = .Unprocessable_Content
	case .Out_Of_Memory, .Not_Found, .Logic, .Other, .Network:
		res.status = .Internal_Server_Error
		log.errorf("creating share error: %s: %s", store_err, err_msg)
	}
}

DAY_IN_SECONDS :: "604800"

index := #load("./static/index.html")
handle_index :: proc(req: ^http.Request, res: ^http.Response) {
	res.headers["Cache-Control"] = "public, max-age=" + DAY_IN_SECONDS

    // Load file every time in debug mode.
    when ODIN_DEBUG {
	    http.respond_file(res, "./static/index.html", req.allocator)
    } else {
        http.respond_file_content(res, "index.html", index)
    }
}

favicon := #load("./static/favicon.ico")
handle_favicon :: proc(req: ^http.Request, res: ^http.Response) {
	res.headers["Cache-Control"] = "public, max-age=" + DAY_IN_SECONDS
	http.respond_file_content(res, "favicon.ico", favicon)
}

handle_static :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_dir(res, "/", "./static", req.url.path, req.allocator)
	if res.status == .NotFound || http.status_success(res.status) {
		res.headers["Cache-Control"] = "public, max-age=" + DAY_IN_SECONDS
	}
}

handle_get_share :: proc(req: ^http.Request, res: ^http.Response) {
	id_str := req.url_params[0]
	id := strconv.atoi(id_str)
	share, err, err_msg := store_get_share(i32(id))
	switch err {
	case .None:
		sr := Share_Json {
			code = share.code,
			opts = {
				optimization = optimization_string(share.opts.optimization),
				target = target_string(share.opts.target),
				build_mode = build_mode_string(share.opts.build_mode),
			},
		}
		http.respond_json(res, sr)
	case .Not_Found:
		res.status = .NotFound
	case .Invalid, .Network, .Other, .Logic, .Out_Of_Memory:
		log.errorf("retrieving share error: %s: %s", err, err_msg)
		res.status = .Internal_Server_Error
	}
}

MAX_CODE_BYTES :: 6000

respond_sandbox_result :: proc(res: ^http.Response, out: string, serr: Sandbox_Error) {
	switch serr {
	case .FileSystem:
		res.status = .Internal_Server_Error
	case .CPUExceeded, .MemoryExceeded, .TimeoutExceeded:
		res.status = .Bad_Request
	case .None:
		http.respond_plain(res, out)
	}
}

parse_share_json :: proc(req: ^http.Request, res: ^http.Response) -> (share_req: Share_Json, opts: Assemble_Opts, ok: bool) {
	body, err := http.request_body(req, MAX_CODE_BYTES)
	if err != nil {
		res.status = http.body_error_status(err)
		return
	}

	input, bok := body.(http.Body_Plain)
	if !bok {
		res.status = .Unprocessable_Content
		return
	}

	if err := json.unmarshal(transmute([]byte)input, &share_req); err != nil {
		http.respond_plain(res, fmt.tprintf("body is invalid: %s", err))
		res.status = .Unprocessable_Content
		return
	}

	opts.optimization, ok = optimization_from_string(share_req.opts.optimization)
	if !ok {
		res.status = .Unprocessable_Content
		return
	}

	opts.target, ok = target_from_string(share_req.opts.target)
	if !ok {
		res.status = .Unprocessable_Content
		return
	}

	opts.build_mode, ok = build_mode_from_string(share_req.opts.build_mode)
	if !ok {
		res.status = .Unprocessable_Content
		return
	}

    ok = true
    return
}
