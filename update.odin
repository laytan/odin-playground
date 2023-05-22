package main

import "core:log"
import "core:encoding/json"
import "core:strings"
import "core:bytes"
import "core:thread"
import "core:time"

import "pkg/odin-http/client"
import http "pkg/odin-http"

ODIN_VERSION_DETAILED := #config(ODIN_VERSION_DETAILED, "")
ODIN_VERSION_SHORT_SHA: string

GITHUB_AUTH_HEADER :: #config(GITHUB_AUTH_HEADER, "")
GITHUB_API_VERSION :: "2022-11-28"
GITHUB_ACCEPT_JSON :: "application/vnd.github+json"

CHECK_INTERVAL :: time.Minute * 5

@(init)
init :: proc() {
    i := strings.last_index_byte(ODIN_VERSION_DETAILED, ':')
    if i <= 0 {
        panic("You must compile with -define:ODIN_VERSION_DETAILED=\"$(odin version)\"")
    }

    ODIN_VERSION_SHORT_SHA = ODIN_VERSION_DETAILED[i+1:]

    if GITHUB_AUTH_HEADER == "" {
        panic("You must compile with -define:GITHUB_AUTH_HEADER=")
    }
}

GitHub_Commits_Response :: struct {
    commit: struct {
        sha: string,
    },
}

// Checks for updates on an interval,
// This proc leaks the thread but when this returns a recompile is triggered anyways.
odin_update_track :: proc() {
    thread.run(proc() {
        for {
            time.sleep(CHECK_INTERVAL)
            if odin_update_check() {
                break
            }
        }
    }, context)
}

// Keeps track of Odin updates and ping GitHub actions to redeploy
// when an update is made to Odin master branch.
odin_update_check :: proc() -> (triggered: bool) {
	req: client.Request
	client.request_init(&req, .Get)
	defer client.request_destroy(&req)

    req.headers["X-GitHub-Api-Version"] = GITHUB_API_VERSION
    req.headers["Accept"] = GITHUB_ACCEPT_JSON
    req.headers["Authorization"] = GITHUB_AUTH_HEADER

    res, err := client.request("https://api.github.com/repos/odin-lang/Odin/branches/master", &req)
    if err != nil {
        log.errorf("Could not get odin master commits: %s", err)
        return
    }

    if res.status != .Ok {
        log.errorf("Status: %s", res.status)
        client.response_destroy(&res)
        return
    }

    body, was_allocation, berr := client.response_body(&res)
    if berr != nil {
        log.errorf("Reading Github body: %s", berr)
        return
    }
    defer client.response_destroy(&res, body, was_allocation)

    if plain, ok := body.(http.Body_Plain); ok {
        commit: GitHub_Commits_Response
        if err := json.unmarshal_string(plain, &commit); err != nil {
            log.errorf("Unmarshal GitHub commits: %s", err)
            return
        }

        if !strings.has_prefix(commit.commit.sha, ODIN_VERSION_SHORT_SHA) {
            log.debug("Odin update detected, triggering GitHub action")
            triggered = true
            odin_update_trigger()
            return
        }

        log.debug("Odin has not been updated since compiling")
    }

    log.errorf("GitHub response body was not plain text?: %v", body)
    return
}

odin_update_trigger :: proc() {
    req: client.Request
    client.request_init(&req)
    defer client.request_destroy(&req)

    bytes.buffer_write_string(&req.body, `{"ref": "main"}`)

    req.headers["X-GitHub-Api-Version"] = GITHUB_API_VERSION
    req.headers["Accept"] = GITHUB_ACCEPT_JSON
    req.headers["Authorization"] = GITHUB_AUTH_HEADER

    res, err := client.request("https://api.github.com/repos/laytan/odin-playground/actions/workflows/update.yml/dispatches", &req)
    if err != nil {
        log.errorf("Update workflow dispatch failed: %s", err)
        return
    }
    defer client.response_destroy(&res)

    if res.status != .No_Content {
        log.errorf("Unexpected status code from workflow dispatch: %s", err)
    }
}
