// Super simple wrapper for executing shell commands.
//
// Does not currently clean up any allocated memory because it is only being used
// during sandbox, which is using the temp_allocator, so no need.
package main

import "core:strings"
import "core:c/libc"
import "core:log"
import "core:os"

import "pkg/snowflake"

Command :: struct {
    output_path: string,
    exit_code: int,
}

command_run :: proc(sh: string) -> (cmd: Command) {
    cmd.exit_code = 1

    rand_path := snowflake.base32(snowflake.generate())
    cmd.output_path = string(rand_path[:])

    // Wraps the command with IO redirections to the output file, so all stdout and stderr will go there
    // instead of to the current stderr and stdout which is what system() does.
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
