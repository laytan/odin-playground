package main

import "core:log"
import "core:encoding/json"
import "core:time"
import "core:fmt"
import "core:net"

import http "pkg/odin-http"
import "pkg/snowflake"

port := #config(PORT, 8080)

store: Store

// TODO: update odin every time a commit is don on master of odin repo.
// TODO: long output causes flexbox to shift, fix it.
main :: proc() {
    when ODIN_DEBUG {
        context.logger = log.create_console_logger()
    } else {
        context.logger = log.create_console_logger(log.Level.Info)
    }

    log.info("Hello, World!")

    odin_update_track()

	store_init(&store)
	defer store_destroy(&store)

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	router: http.Router
	http.router_init(&router)

	http.route_get(&router, "/api/share/(%w+)", http.handler(handle_get_share))
	http.route_get(&router, "/", http.handler(handle_index))
	http.route_get(&router, "/%w+", http.handler(handle_index))
    http.route_get(&router, "/favicon.ico", http.handler(handle_favicon))

	post_router: http.Router
	http.router_init(&post_router)

	http.route_post(&post_router, "/api/exec", http.handler(handle_exec))
	http.route_post(&post_router, "/api/assemble", http.handler(handle_assemble))
	http.route_post(&post_router, "/api/share", http.handler(handle_share))

	// Rate limit the post router.
	limit_message := "Processing code is only allowed 6 times per minute."
	post_handler := http.router_handler(&post_router)
	post_rate_limited := http.middleware_rate_limit(
		&post_handler,
		&http.Rate_Limit_Opts{
			window = time.Minute,
			max = 6,
			on_limit = http.on_limit_message(&limit_message),
		},
	)

	// Make all post requests from the main router go to the rate limited post router.
	http.route_post(&router, ".*", post_rate_limited)

	route_handler := http.router_handler(&router)

    // TODO: nicer time logged.
	with_logger := http.middleware_logger(&route_handler, &http.Logger_Opts{log_time = true})

	log.warnf("Server stopped: %v", http.listen_and_serve(&s, &with_logger, net.Endpoint{
        address = net.IP4_Any,
        port = port,
    }))
}

handle_exec :: proc(req: ^http.Request, res: ^http.Response) {
	body, _, err := http.request_body(req, MAX_CODE_BYTES)
	if err != nil {
        #partial switch err {
        case .Too_Long: http.respond_plain(res, "Too much code")
        case:           http.respond_plain(res, fmt.tprintf("Could not read body: %s", err))
        }
		res.status = http.body_error_status(err)
		return
	}

	input, ok := body.(http.Body_Plain)
	if !ok {
        http.respond_plain(res, "Code should be sent in plain text")
		res.status = .Bad_Request
		return
	}

	if len(input) == 0 {
        http.respond_plain(res, "Empty input, write some code")
		res.status = .Unprocessable_Content
		return
	}

	out, serr := sandbox_execute(transmute([]byte)input)
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
        http.respond_plain(res, "Empty input, write some code")
		res.status = .Unprocessable_Content
		return
	}

	out, serr := sandbox_assemble(transmute([]byte)share_req.code, opts)
	respond_sandbox_result(res, out, serr)
}

handle_share :: proc(req: ^http.Request, res: ^http.Response) {
    share_req, opts, ok := parse_share_json(req, res)
    if !ok do return

	if len(share_req.code) == 0 {
        http.respond_plain(res, "Empty input, write some code")
		res.status = .Unprocessable_Content
		return
	}

	share := Share{
		code = share_req.code,
		opts = opts,
	}
	id, store_err, err_msg := store_create_share(&store, &share)
	switch store_err {
	case .None:
        id_str := snowflake.base32(id)
		http.respond_plain(res, fmt.tprintf("/%s", id_str))
	case .Invalid:
		http.respond_plain(res, err_msg)
		res.status = .Unprocessable_Content
	case .Out_Of_Memory, .Not_Found, .Logic, .Other, .Network:
        http.respond_plain(res, "Could not create share because of an internal server error")
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

handle_get_share :: proc(req: ^http.Request, res: ^http.Response) {
	id_str := req.url_params[0]
    id, ok := snowflake.from_base32(transmute([]byte)id_str)
    if !ok {
        http.respond_plain(res, fmt.tprintf("%q is not in a valid share format", id_str))
        res.status = .NotFound
        return
    }

	share, err, err_msg := store_get_share(id)
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

MAX_CODE_BYTES :: 12000

respond_sandbox_result :: proc(res: ^http.Response, out: string, serr: Sandbox_Error) {
	switch serr {
	case .FileSystem:
        http.respond_plain(res, "Unexpected error interacting with the file system")
        log.error("Sandbox filesystem error")
		res.status = .Internal_Server_Error
  //   case .CPUExceeded:
  //       http.respond_plain(res, "Maximum CPU usage exceeded")
		// res.status = .Bad_Request
  //   case .MemoryExceeded:
  //       http.respond_plain(res, "Maximum memory usage exceeded")
		// res.status = .Bad_Request
  //   case .TimeoutExceeded:
  //       http.respond_plain(res, "Maximum time exceeded")
		// res.status = .Bad_Request
    case .CompilerError:
        http.respond_plain(res, fmt.tprintf("Code compilation failed: %s", out))
        res.status = .Bad_Request
	case .None:
		http.respond_plain(res, out)
	}
}

parse_share_json :: proc(req: ^http.Request, res: ^http.Response) -> (share_req: Share_Json, opts: Assemble_Opts, ok: bool) {
	body, _, err := http.request_body(req, MAX_CODE_BYTES)
	if err != nil {
		res.status = http.body_error_status(err)
		return
	}

	input, bok := body.(http.Body_Plain)
	if !bok {
        http.respond_plain(res, "Code should be sent as plain text")
		res.status = .Unprocessable_Content
		return
	}

	if err := json.unmarshal(transmute([]byte)input, &share_req); err != nil {
		http.respond_plain(res, fmt.tprintf("Could not decode JSON body: %s", err))
		res.status = .Unprocessable_Content
		return
	}

	opts.optimization, ok = optimization_from_string(share_req.opts.optimization)
	if !ok {
        http.respond_plain(res, fmt.tprintf("%q is an invalid optimization setting", share_req.opts.optimization))
		res.status = .Unprocessable_Content
		return
	}

	opts.target, ok = target_from_string(share_req.opts.target)
	if !ok {
        http.respond_plain(res, fmt.tprintf("%q is an invalid target setting", share_req.opts.target))
		res.status = .Unprocessable_Content
		return
	}

	opts.build_mode, ok = build_mode_from_string(share_req.opts.build_mode)
	if !ok {
        http.respond_plain(res, fmt.tprintf("%q is an invalid build mode setting", share_req.opts.build_mode))
		res.status = .Unprocessable_Content
		return
	}

    ok = true
    return
}
