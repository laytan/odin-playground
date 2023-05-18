package main

import "core:log"
import "core:c"
import "core:fmt"
import "core:strings"

import "mysql"

Store :: struct {
	c: ^mysql.MySQL,
}

Share :: struct {
    code:   string,
    opts:   Assemble_Opts,
}

Store_Err :: enum {
    None,
    Not_Found,
    Out_Of_Memory,
    Network, // Store connection error.
    Logic,   // Error in implementation.
    Invalid, // The result from the store is invalid, doesn't cast to the given type for example.
    Other,   // Unknown errors.
}

MAX_OPTIMIZATION_LENGTH :: 7
MAX_TARGET_LENGTH :: 23
MAX_BUILD_MODE :: 4

store_init :: proc(store: ^Store) -> (ok: bool) {
	store.c = mysql.init()
	if store.c == nil {
		log.error("could not initialize mysql, out of memory")
		return
	}

    host := #config(DB_HOST, "")
    if host == "" do panic("you must define DB_HOST")
    chost := strings.clone_to_cstring(host)

    uname := #config(DB_USERNAME, "")
    if uname == "" do panic("you must define DB_USERNAME")
    cuname := strings.clone_to_cstring(uname)

    password := #config(DB_PASSWORD, "")
    if password == "" do panic("you must define DB_PASSWORD")
    cpassword := strings.clone_to_cstring(password)

    dbname := #config(DB_NAME, "")
    if dbname == "" do panic("you must define DB_NAME")
    cdbname := strings.clone_to_cstring(dbname)

	if mysql.connect(store.c, chost, cuname, cpassword, cdbname) == nil {
		log.errorf("failed to connect to database, error: %s", mysql.error(store.c))
		return
	}

	return true
}

store_destroy :: proc(store: ^Store) {
	mysql.close(store.c)
}

store_create_share :: proc(store: ^Store, share: ^Share, allocator := context.temp_allocator) -> (id: i32, err: Store_Err, msg: string) {
	context.allocator = allocator

	stmt := mysql.stmt_init(store.c)
	if stmt == nil {
        err = .Out_Of_Memory
        msg = string(mysql.error(store.c))
		return
	}
	defer mysql.stmt_close(stmt)

	stmt_str: cstring = "INSERT INTO shares VALUES (NULL, ?, ?, ?, ?, NULL)"
	if mysql.stmt_prepare(stmt, stmt_str, u64(len(stmt_str))) != 0 {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_COMMANDS_OUT_OF_SYNC:                    err = .Logic
        case mysql.CR_OUT_OF_MEMORY:                           err = .Out_Of_Memory
        case mysql.CR_SERVER_GONE_ERROR, mysql.CR_SERVER_LOST: err = .Network
        }
        return
	}

	binds := make([]mysql.Bind, 4)
    binds[0], _ = mysql.bindp_text(share.code)
    binds[1], _ = mysql.bindp_var_char(optimization_string(share.opts.optimization))
    binds[2], _ = mysql.bindp_var_char(target_string(share.opts.target))
    binds[3], _ = mysql.bindp_var_char(build_mode_string(share.opts.build_mode))

	if mysql.stmt_bind_param(stmt, raw_data(binds)) {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_UNSUPPORTED_PARAM_TYPE: err = .Logic
        case mysql.CR_OUT_OF_MEMORY:          err = .Out_Of_Memory
        }
		return
	}

	if mysql.stmt_execute(stmt) != 0 {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_COMMANDS_OUT_OF_SYNC:                    err = .Logic
        case mysql.CR_OUT_OF_MEMORY:                           err = .Out_Of_Memory
        case mysql.CR_SERVER_GONE_ERROR, mysql.CR_SERVER_LOST: err = .Network
        }
		return
	}

	return i32(mysql.insert_id(store.c)), .None, ""
}

store_get_share :: proc(id: i32, res_allocator := context.allocator, temp_allocator := context.temp_allocator) -> (share: Share, err: Store_Err, msg: string) {
    context.allocator = temp_allocator // Allocator to use for c bindings and temporary allocations in this proc.

	stmt := mysql.stmt_init(store.c)
	if stmt == nil {
        err = .Out_Of_Memory
        msg = string(mysql.error(store.c))
        return
	}
	defer mysql.stmt_close(stmt)

	stmt_str: cstring = "SELECT code, optimization, target, build_mode FROM shares WHERE id = ?"
	if mysql.stmt_prepare(stmt, stmt_str, u64(len(stmt_str))) != 0 {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_COMMANDS_OUT_OF_SYNC:                    err = .Logic
        case mysql.CR_OUT_OF_MEMORY:                           err = .Out_Of_Memory
        case mysql.CR_SERVER_GONE_ERROR, mysql.CR_SERVER_LOST: err = .Network
        }
        return
	}

	binds := make([]mysql.Bind, 1)
    cid := c.int(id)
    binds[0] = mysql.bindp_int(&cid)

	if mysql.stmt_bind_param(stmt, raw_data(binds)) {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_UNSUPPORTED_PARAM_TYPE: err = .Logic
        case mysql.CR_OUT_OF_MEMORY:          err = .Out_Of_Memory
        }
		return
	}

	if mysql.stmt_execute(stmt) != 0 {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_COMMANDS_OUT_OF_SYNC:                    err = .Logic
        case mysql.CR_OUT_OF_MEMORY:                           err = .Out_Of_Memory
        case mysql.CR_SERVER_GONE_ERROR, mysql.CR_SERVER_LOST: err = .Network
        }
		return
	}

	rbinds := make([]mysql.Bind, 4)

    // code_len gets set during stmt_fetch, we then fetch the actual data later.
    code_len: c.ulong
    rbinds[0] = mysql.bindr_text(nil, &code_len)

    opt_len: c.ulong
    opt_buf := make([]byte, MAX_OPTIMIZATION_LENGTH, res_allocator)
    rbinds[1] = mysql.bindr_var_char(opt_buf, &opt_len)

    target_len: c.ulong
    target_buf := make([]byte, MAX_TARGET_LENGTH, res_allocator)
    rbinds[2] = mysql.bindr_var_char(target_buf, &target_len)

    build_mode_len: c.ulong
    build_mode_buf := make([]byte, MAX_BUILD_MODE, res_allocator)
    rbinds[3] = mysql.bindr_var_char(build_mode_buf, &build_mode_len)

    if mysql.stmt_bind_result(stmt, raw_data(rbinds)) {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_UNSUPPORTED_PARAM_TYPE: err = .Logic
        case mysql.CR_OUT_OF_MEMORY:          err = .Out_Of_Memory
        }
		return
    }

    if mysql.stmt_store_result(stmt) != 0 {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_COMMANDS_OUT_OF_SYNC:                    err = .Logic
        case mysql.CR_OUT_OF_MEMORY:                           err = .Out_Of_Memory
        case mysql.CR_SERVER_GONE_ERROR, mysql.CR_SERVER_LOST: err = .Network
        }
		return
    }

    fetch_status := mysql.stmt_fetch(stmt)
    switch fetch_status {
    case mysql.NO_DATA:
        err = .Not_Found
        msg = "Not Found"
        return
    // TRUNCATED is expected because the code buffer is nil at this point (need to get length of it first).
    case mysql.DATA_TRUNCATED, 0: break
    case:
        msg = string(mysql.stmt_error(stmt))
        err = .Other
        return
    }

    // Fetch the code based on the length.
    code_buf := make([]byte, code_len, res_allocator)
    rbinds[0].buffer = raw_data(code_buf)
    rbinds[0].buffer_length = code_len
    if mysql.stmt_fetch_column(stmt, raw_data(rbinds), 0, 0) != 0 {
        err = .Other
        msg = string(mysql.stmt_error(stmt))
        switch mysql.stmt_errno(stmt) {
        case mysql.CR_COMMANDS_OUT_OF_SYNC: err = .Logic
        case mysql.CR_NO_DATA:              err = .Not_Found // I think this is when the code column is nil.
        }
        return
    }
    share.code = string(code_buf[:code_len])

    opt_str        := string(opt_buf[:opt_len])
    target_str     := string(target_buf[:target_len])
    build_mode_str := string(build_mode_buf[:build_mode_len])

    ok: bool
    share.opts.optimization, ok = optimization_from_string(opt_str)
    if !ok {
        msg = fmt.tprintf("%q is not a valid optimization", opt_str)
        err = .Invalid
        return
    }

    share.opts.target, ok = target_from_string(target_str)
    if !ok {
        msg = fmt.tprintf("%q is not a valid target", target_str)
        err = .Invalid
        return
    }

    share.opts.build_mode, ok = build_mode_from_string(build_mode_str)
    if !ok {
        msg = fmt.tprintf("%q is not a valid build mode", build_mode_str)
        err = .Invalid
        return
    }

    return share, .None, ""
}
