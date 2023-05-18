package main

import "core:math/rand"
import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:c/libc"
import "core:strings"
import "core:log"

@(private="file")
r: rand.Rand

sandbox_init :: proc() {
    rand.init_as_system(&r)
}

@(private="file")
IMAGE_TAG :: "odin-playground:latest"

@(private="file")
MAX_SECONDS :: 5
@(private="file")
MAX_MEMORY  :: "256mb"
@(private="file")
MAX_CPU :: "1"

Sandbox_Error :: enum {
    None,
    TimeoutExceeded, // TODO: detect timeout.
    MemoryExceeded,  // TODO: detect memory limit.
    CPUExceeded,     // TODO: add cpu limit and detect.
    FileSystem,
}

Sandbox_Mode :: enum {
    Assemble,
    Execute,
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

// Executes the given code in the sandbox.
// Returns the combined output of stdout and stderr.
sandbox_execute :: proc(code: []byte, mode: Sandbox_Mode, asm_opts: Maybe(Assemble_Opts), allocator := context.allocator) -> (output: string, rerr: Sandbox_Error) {
    file := temp_file(&r, allocator)
    dir := filepath.dir(file, allocator)

    if err := os.make_directory(dir, 0o777); err != 0 {
        log.errorf("could not create temp directory %q: %s", dir, err)
        rerr = .FileSystem
        return
    }
    defer os.remove(dir)

    fh, err := os.open(file, os.O_WRONLY|os.O_CREATE, 0o777)
    if err != os.ERROR_NONE {
        log.errorf("could not create source file: %s", err)
        rerr = .FileSystem
        return
    }
    defer os.close(fh)

    _, werr := os.write(fh, code)
    if werr != os.ERROR_NONE {
        log.errorf("could not write code %q to %q", code, file)
        rerr = .FileSystem
        return
    }
    defer os.remove(file)

    // REALLY hacky, but for some reason the modes applied above don't actually do anything.
    libc.system(strings.clone_to_cstring(fmt.tprintf("chmod -R 777 %s", dir)))

    out := strings.concatenate([]string{file, ".out"}, allocator)

    container_cmd: string
    switch mode {
    case .Assemble:
        opts := asm_opts.(Assemble_Opts)
        t, b, o := target_string(opts.target), build_mode_string(opts.build_mode), optimization_string(opts.optimization)
        out: string
        switch opts.build_mode {
        case .Assembly: out = "playground.S"
        case .Llvm:     out = "playground.ll"
        }

        container_cmd = fmt.tprintf("odin build . -target:%s -build-mode:%s -o:%s && cat %s", t, b, o, out)
    case .Execute:
        container_cmd = fmt.tprintf("odin run .")
    }

    cmd := fmt.tprintf(
        "timeout --kill-after=1s --signal=SIGTERM %i docker run -v %s:/home/playground --init --network none --cpus=%s --memory %s --rm %s sh -c \"%s\" > %s 2>&1",
        MAX_SECONDS,
        dir,
        MAX_CPU,
        MAX_MEMORY,
        IMAGE_TAG,
        container_cmd,
        out,
    )
    log.debug(cmd)

    handle := libc.system(strings.clone_to_cstring(cmd, allocator))
    log.infof("system: %i", handle)

    res, ok := os.read_entire_file_from_filename(out, allocator)
    if !ok {
        rerr = .FileSystem
        return
    }
    os.remove(out)

    output = string(res)
    return
}

@(private="file")
RANDOM_CHOICES := []byte{
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
}

@(private="file")
TMP :: "/tmp/playground-"
@(private="file")
TMP_LEN :: len(TMP)
@(private="file")
RANDOM_LEN :: 16
@(private="file")
MAIN :: "/main.odin"
@(private="file")
MAIN_LEN :: len(MAIN)

@(private="file")
temp_file :: proc(r: ^rand.Rand, allocator := context.temp_allocator) -> string {
    u := make([]byte, TMP_LEN + RANDOM_LEN + MAIN_LEN, allocator)
    copy(u, TMP)

    for _, i in u[TMP_LEN:TMP_LEN+RANDOM_LEN] {
        u[i+TMP_LEN] = rand.choice(RANDOM_CHOICES, r)
    }

    copy(u[TMP_LEN+RANDOM_LEN:], MAIN)

    return string(u)
}
