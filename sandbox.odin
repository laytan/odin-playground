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
MAX_MEMORY  :: "126mb" // NOTE: can probably be lower?
@(private="file")
MAX_CPU :: "1"         // TODO: can this be fractions?

@(private="file")
ODIN := #config(ODIN, "odin") // Use if odin is not in the path.

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

// Creates a directory with a snowflake as its name, with a main.odin file containing the given code.
prep_directory :: proc(code: []byte) -> (dir: string, main: string, ok: bool) {
    id := snowflake.base32(snowflake.generate())
    dir = string(id[:])
    main = strings.concatenate([]string{dir, "/main.odin"})

    if status := os.make_directory(dir); status != 0 {
        log.errorf("could not make directory: %s: %i", dir, status)
        return
    }
    defer if !ok do rmdir(dir)

    if !os.write_entire_file(main, code) {
        log.error("could not write file %q with the given code", main)
        return
    }

    ok = true
    return
}

// TODO: this probably breaks when we get a lot of traffic and should be a queued system.
sandbox_assemble :: proc(code: []byte, opts: Assemble_Opts) -> (output: string, rerr: Sandbox_Error) {
    // If we ever use this from not within a request handler, we need to do actual memory management ;).
    context.allocator = context.temp_allocator

    dir, main, ok := prep_directory(code)
    if !ok {
        rerr = .FileSystem
        return
    }
    defer rmdir(dir)
    defer os.remove(main)

    ext := opts.build_mode == .Llvm ? ".ll" : ".S"
    out := strings.concatenate([]string{main[:len(main)-5], ext})
    defer os.remove(out)

    target, build_mode, optimization := target_string(opts.target), build_mode_string(opts.build_mode), optimization_string(opts.optimization)

    // This is safe to do on the host machine because Odin does not have arbitrary compile time code execution.
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

// TODO: this probably breaks when we get a lot of traffic and should be a queued system.
sandbox_execute :: proc(code: []byte) -> (output: string, rerr: Sandbox_Error) {
    // If we ever use this from not within a request handler, we need to do actual memory management ;).
    context.allocator = context.temp_allocator

    dir, main, ok := prep_directory(code)
    if !ok {
        rerr = .FileSystem
        return
    }
    defer rmdir(dir)
    defer os.remove(main)

    out := main[:len(main)-5]
    defer os.remove(out)

    // Build the given code into a static binary, this is safe to do on the host machine because Odin does not have arbitrary
    // compile time code execution, because of this, the container does not need any means to build code,
    // it just executes the binary, keeping the container very small.
    build_cmd := command_run(fmt.tprintf("%s build %s -out:%s -o:none -extra-linker-flags:\"-static\"", ODIN, dir, out))
    defer command_destroy(&build_cmd)

    if !command_success(&build_cmd) {
        return command_output(&build_cmd), .CompilerError
    }

    // Volumes need to be absolute.
    volume_path, err := os.absolute_path_from_relative(dir)
    if err != 0 {
        log.errorf("could not get absolute path for %q", dir)
        rerr = .FileSystem
        return
    }

    // Explanation for the parts of this command:
    // - "timeout --kill-after=1s --signal=SIGINT %i"
    //   Uses the unix timeout command to kill the 'docker run' process after MAX_SECONDS with a SIGINT, if it does not then quit after 1s, it sends a KILL signal.
    // - "--runtime=runsc"
    //   Makes docker use the runsc (aka gVisor) runtime, this is a sandboxed kernel runtime (default docker shares the kernel).
    // - "-v %s:/home/playground"
    //   Puts the temporary directory contents in the /home/playground directory of the container.
    // - "--init"
    //   Makes the entrypoint in the container an initialization script from Docker which listens for signals (needed for timeout to work).
    // - "--cpus %s --memory %s"
    //   Limit the memory and cpu usage of the container.
    // - "--network none"
    //   Disable networking.
    // - "--rm"
    //   Remove the container when it exits.
    // - "sh -c "./main""
    //   The command that is ran in the container, this executes the ./main binary which was copied using the volume.
    run_cmd := command_run(fmt.tprintf("timeout --kill-after=1s --signal=SIGINT %i docker run --runtime=runsc -v %s:/home/playground --init --cpus=%s --memory %s --network none --rm %s sh -c \"./main\"", MAX_SECONDS, volume_path, MAX_CPU, MAX_MEMORY, IMAGE_TAG))
    defer command_destroy(&run_cmd)

    return string(command_output(&run_cmd)), .None
}

rmdir :: proc(path: string) {
    when ODIN_OS == .Linux {
        if err := os.remove_directory(path); err != os.ERROR_NONE {
            log.errorf("error removing directory %q: %s", path, err)
        }
    } else {
        if !os.remove(path) {
            log.errorf("error removing directory %q", path)
        }
    }
}
