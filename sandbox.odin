package main

import "core:math/rand"
import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:c/libc"
import "core:strings"
import "core:log"
import "pkg/snowflake"

@(private="file")
IMAGE_TAG :: "odin-playground:latest"

@(private="file")
MAX_SECONDS :: 5
@(private="file")
MAX_MEMORY  :: "256mb"
@(private="file")
MAX_CPU :: "1"

@(private="file")
ODIN := #config(ODIN, "odin")

Sandbox_Error :: enum {
    None,
    // TimeoutExceeded, // TODO: detect timeout.
    // MemoryExceeded,  // TODO: detect memory limit.
    // CPUExceeded,     // TODO: add cpu limit and detect.
    FileSystem,
    CompilerError, // Error, with code, can be shown to user.
}

Optimization :: enum {
    None,
    Minimal,
    Speed,
    Size,
}

Target :: enum {
    Darwin_AMD64,
    Darwin_ARM64,

    Essence_ARM64,

    Linux_I386,
    Linux_AMD64,
    Linux_ARM64,
    Linux_ARM32,

    Windows_I386,
    Windows_AMD64,

    FreeBSD_I386,
    FreeBSD_AMD64,
    OpenBSD_AMD64,

    WASI_WASM32,
    JS_WASM32,
    Freestanding_WASM32,

    Freestanding_AMD64_SYSV,
}

Build_Mode :: enum {
    Assembly,
    Llvm,
}

target_string :: proc(target: Target) -> string {
    switch target {
        case .Darwin_AMD64:            return "darwin_amd64"
        case .Darwin_ARM64:            return "darwin_arm64"

        case .Essence_ARM64:           return "essence_amd64"

        case .Linux_I386:              return "linux_i386"
        case .Linux_AMD64:             return "linux_amd64"
        case .Linux_ARM64:             return "linux_arm64"
        case .Linux_ARM32:             return "linux_arm32"

        case .Windows_I386:            return "windows_i386"
        case .Windows_AMD64:           return "windows_amd64"

        case .FreeBSD_I386:            return "freebsd_i386"
        case .FreeBSD_AMD64:           return "freebsd_amd64"
        case .OpenBSD_AMD64:           return "openbsd_amd64"

        case .WASI_WASM32:             return "wasi_wasm32"
        case .JS_WASM32:               return "js_wasm32"
        case .Freestanding_WASM32:     return "freestanding_wasm32"
        case .Freestanding_AMD64_SYSV: return "freestanding_amd64_sysv"
        case: panic("unreachable")
    }
}

target_from_string :: proc(str: string) -> (Target, bool) {
    for t in Target {
        if target_string(t) == str do return t, true
    }

    return .Linux_AMD64, false
}

optimization_string :: proc(o: Optimization) -> string {
    switch o {
        case .None:    return "none"
        case .Size:    return "size"
        case .Speed:   return "speed"
        case .Minimal: return "minimal"
        case:          return "none"
    }
}

optimization_from_string :: proc(str: string) -> (Optimization, bool) #optional_ok {
    for o in Optimization {
        if optimization_string(o) == str do return o, true
    }

    return .None, false
}

build_mode_string :: proc(m: Build_Mode) -> string {
    switch m {
    case .Llvm:     return "llvm"
    case .Assembly: return "asm"
    case:           return ""
    }
}

build_mode_from_string :: proc(m: string) -> (Build_Mode, bool) {
    switch m {
    case "asm":  return .Assembly, true
    case "llvm": return .Llvm, true
    case:        return nil, false
    }
}

Assemble_Opts :: struct {
    optimization: Optimization,
    target:       Target,
    build_mode:   Build_Mode,
}

prep_directory :: proc(code: []byte) -> (dir: string, main: string, ok: bool) {
    id := snowflake.base32(snowflake.generate())
    dir = string(id[:])
    main = strings.concatenate([]string{dir, "/main.odin"})

    if status := os.make_directory(dir); status != 0 {
        log.errorf("could not make directory: %s: %i", dir, status)
        return
    }
    defer if !ok do os.remove(dir)

    if !os.write_entire_file(main, code) {
        log.error("could not write file %q with the given code", main)
        return
    }

    ok = true
    return
}

sandbox_assemble :: proc(code: []byte, opts: Assemble_Opts) -> (output: string, rerr: Sandbox_Error) {
    context.allocator = context.temp_allocator

    dir, main, ok := prep_directory(code)
    if !ok {
        rerr = .FileSystem
        return
    }
    defer os.remove(dir)
    defer os.remove(main)

    ext := opts.build_mode == .Llvm ? ".ll" : ".S"
    out := strings.concatenate([]string{main[:len(main)-5], ext})
    defer os.remove(out)

    target, build_mode, optimization := target_string(opts.target), build_mode_string(opts.build_mode), optimization_string(opts.optimization)
    cmd := command_run(fmt.tprintf("%s build %s -out:%s -target:%s -build-mode:%s -o:%s", ODIN, dir, out, target, build_mode, optimization))
    defer command_destroy(&cmd)

    if command_success(&cmd) {
        bytes, ok := os.read_entire_file_from_filename(out)
        if !ok {
            log.errorf("could not read output: %q", out)
            rerr = .FileSystem
            return
        }

        return string(bytes), nil
    }

    return command_output(&cmd), .CompilerError
}

sandbox_execute :: proc(code: []byte) -> (output: string, rerr: Sandbox_Error) {
    context.allocator = context.temp_allocator

    dir, main, ok := prep_directory(code)
    if !ok {
        rerr = .FileSystem
        return
    }
    defer os.remove(dir)
    defer os.remove(main)

    out := main[:len(main)-5]
    build_cmd := command_run(fmt.tprintf("%s build %s -out:%s -o:none -extra-linker-flags:\"-static\"", ODIN, dir, out))
    defer command_destroy(&build_cmd)

    if !command_success(&build_cmd) {
        return command_output(&build_cmd), .CompilerError
    }

    run_cmd := command_run(fmt.tprintf("timeout --kill-after=1s --signal=SIGINT %i docker run --runtime=runsc -v %s:/home/playground --init --cpus=%s --memory %s --rm %s sh -c \"./main\"", MAX_SECONDS, dir, MAX_CPU, MAX_MEMORY, IMAGE_TAG))
    defer command_destroy(&run_cmd)

    return string(command_output(&run_cmd)), .None
}

Command :: struct {
    output_path: string,
    exit_code: int,
}

command_run :: proc(sh: string) -> (cmd: Command) {
    cmd.exit_code = 1

    rand_path := snowflake.base32(snowflake.generate())
    cmd.output_path = string(rand_path[:])

    cmd_to_run := strings.concatenate([]string{sh, " 1>", cmd.output_path, " 2>&1"})

    cmd.exit_code = int(libc.system(strings.clone_to_cstring(cmd_to_run)))

    log.infof("Command: %q with exit code: %i", cmd_to_run, cmd.exit_code)
    return
}

command_success :: proc(cmd: ^Command) -> bool {
    return cmd.exit_code == 0
}

command_output :: proc(cmd: ^Command) -> string {
    bytes, ok := os.read_entire_file_from_filename(cmd.output_path)
    if !ok {
        log.errorf("Could not read command output file: %s", cmd.output_path)
        return ""
    }

    return string(bytes)
}

command_destroy :: proc(cmd: ^Command) {
    os.remove(cmd.output_path)
}
