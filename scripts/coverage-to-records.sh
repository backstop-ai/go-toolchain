#!/bin/sh
# go-toolchain coverage convert script (SPEC-042 REQ-007/CLM-021; ISSUE-045).
# PARSE-ONLY: reads the PRODUCER's enriched Go `-coverprofile` on stdin and emits
# per-FILE coverage-records JSON on stdout — NOT SARIF. It runs SANDBOXED (a deny-all
# sandbox-exec profile) and therefore has NO toolchain or project access: it runs NO
# `go` command and reads NO go.mod. All the Go/toolchain knowledge it needs arrives as
# PLAIN-TEXT comment lines the un-sandboxed producer (scripts/coverage-produce.sh)
# folded into the profile: `#backstop-module <M>` and `#backstop-gofile <import-path>`.
# The producer/convert split is what keeps this convert toolchain-free (ISSUE-045).
#
# Go profile line shape:  path:startLine.col,endLine.col numStmt count
# Per FILE: total   = sum(numStmt) over the file's blocks
#           covered = sum(numStmt) over blocks whose count > 0
# A file whose blocks are all 0-statement aggregates to total==0 (the N/A cell) —
# never coerced to a 0% value. Every file present in the profile is `measured: true`,
# and a record is emitted for measured-and-PASSING files too (not only shortfalls),
# so the consumer can distinguish measured-and-passed from not-measured. Metric is
# stamped "statement" (Go's -coverprofile granularity).
#
# REPO-RELATIVE PATHS (ISSUE-045 CLM-005): Go's -coverprofile ALWAYS names files by
# their full module import path (e.g. github.com/bmanson/backstop-core/embed.go),
# never repo-relative. This convert PARSES the producer's `#backstop-module` line and
# strips the "<module>/" import-path prefix so the emitted record `path` is repo-
# relative (embed.go, pkg/pack/engine/registry.go, ...) — the contract the language-
# neutral gate consumer relies on for EXACT path matching, especially root-package
# files whose gate-scope path is a bare basename and cannot be reconciled by a suffix
# scan without colliding with same-basename nested files. A path lacking the prefix
# (or an absent module line) passes through unchanged.
#
# ZERO-STATEMENT N/A RECORDS (ISSUE-045 case-1, CLM-001): a Go source file with zero
# measurable statements (types/consts/interfaces only, e.g. fieldcontract.go) yields
# ZERO lines in a -coverprofile, so it is simply ABSENT from the profile — the
# language-neutral gate would then flag it `coverage_unmeasured` (nothing measured).
# It is NOT unmeasured, it is UN-MEASURABLE-by-construction (N/A). `go test
# -coverprofile` instruments EVERY statement of a package under test, so a MEASURED
# package emits a block for every statement-bearing file; the ONLY files absent from a
# measured package's profile entries are zero-statement files. So this convert emits a
# total:0 N/A record for exactly those: a producer-listed `#backstop-gofile` that
# (a) is ABSENT from the profile AND (b) belongs to a package that HAS >=1 profile
# entry (was measured). An untested-with-statements file already appears in the profile
# (total>0/covered=0) and stays flagged below-threshold; a file in an UNMEASURED
# package (no profile entries) gets NO total:0 record and correctly fires
# coverage_unmeasured. The gate's EXISTING `Total==0 => N/A` guard then handles the
# emitted records with no gate change and no cross-language unsoundness (a gate-side
# "no record in a measured directory => N/A" proxy is UNSOUND across languages — an
# lcov producer OMITS an untested-but-has-statements file — which is why this
# language-specific distinction lives HERE in the pack, not in the gate).
#
# Implemented in POSIX awk (no gawk-only features) so it runs under the macOS system
# awk inside the sandbox. A converter banner on stderr exercises clean-stdout capture.
echo "go-toolchain coverage-to-records: aggregating per-file statement coverage" >&2

awk '
  function esc(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\") out = out "\\\\"
      else if (c == "\"") out = out "\\\""
      else if (c == tab) out = out "\\t"
      else if (c == cr) out = out "\\r"
      else if (c == ff) out = out "\\f"
      else if (c == vt) out = out "\\u000b"
      else out = out c
    }
    return out
  }
  function has_forbidden(s, path_value,   i, c, code) {
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      for (code = 1; code < 32; code++) {
        if (c != sprintf("%c", code)) continue
        if (!path_value && (code == 9 || code == 11 || code == 12 || code == 13)) break
        return 1
      }
    }
    return 0
  }
  function valid_path(path,   count, i, part) {
    if (path == "" || substr(path, 1, 1) == "/" || substr(path, length(path), 1) == "/" || has_forbidden(path, 1)) return 0
    count = split(path, parts, "/")
    for (i = 1; i <= count; i++) {
      part = parts[i]
      if (part == "" || part == "." || part == "..") return 0
    }
    return 1
  }
  function valid_reason(reason,   substantive) {
    if (reason == "" || has_forbidden(reason, 0)) return 0
    substantive = reason
    gsub(/ /, "", substantive)
    gsub(tab, "", substantive)
    gsub(cr, "", substantive)
    gsub(ff, "", substantive)
    gsub(vt, "", substantive)
    return substantive != ""
  }
  # pkgdir returns the package import path of a module-qualified file path (everything
  # before the final "/").
  function pkgdir(p,   i) { i = length(p); while (i > 0 && substr(p, i, 1) != "/") i--; return (i > 0) ? substr(p, 1, i - 1) : "" }
  # strip removes the "<module>/" import-path prefix to yield a repo-relative path; a
  # path that does not carry the prefix is returned unchanged.
  function strip(p,   pfx) { if (module == "") return p; pfx = module "/"; if (index(p, pfx) == 1) return substr(p, length(pfx) + 1); return p }
  # Producer-provided enrichment: the module path and the package .go file list.
  /^#backstop-module / { module = $2; next }
  /^#backstop-gofile / { gofiles[++gn] = $2; next }
  # A CONSUMER-declared coverage exclusion, folded in by the un-sandboxed producer:
  # #backstop-coverage-exclude<TAB><repo-relative-path><TAB><justification...>
  # The path is already repo-relative (the project declared it that way), so it is
  # NOT prefix-stripped like the module-qualified profile paths are.
  /^#backstop-coverage-exclude\t/ {
    remainder = substr($0, length(exclusion_marker) + 1)
    delimiter = index(remainder, tab)
    excl_path = delimiter ? substr(remainder, 1, delimiter - 1) : ""
    why = delimiter ? substr(remainder, delimiter + 1) : ""
    if (delimiter && valid_path(excl_path) && valid_reason(why)) {
      if (!(excl_path in excluded)) exclusion_order[++en] = excl_path
      excluded[excl_path] = 1
      reason[excl_path] = why
    }
    next
  }
  BEGIN {
    tab = sprintf("%c", 9)
    vt = sprintf("%c", 11)
    ff = sprintf("%c", 12)
    cr = sprintf("%c", 13)
    exclusion_marker = "#backstop-coverage-exclude" tab
  }
  /^mode:/ { next }
  NF == 0 { next }
  {
    # A Go coverage profile block: path:startLine.col,endLine.col numStmt count
    nf = split($0, f, " ")
    if (nf < 3) next
    loc = f[1]
    numstmt = f[2] + 0
    count = f[3] + 0
    idx = index(loc, ".go:")
    if (idx == 0) next
    file = substr(loc, 1, idx + 2)   # includes ".go", module-qualified
    if (!(file in seen)) { order[++n] = file; seen[file] = 1 }
    total[file] += numstmt
    if (count > 0) covered[file] += numstmt
    measuredPkg[pkgdir(file)] = 1
  }
  END {
    # Emit a total:0 N/A record for each producer-listed source file ABSENT from the
    # profile whose package WAS measured (has >=1 profile entry) — a genuinely zero-
    # statement file. Iterated in producer-list order for deterministic output.
    for (i = 1; i <= gn; i++) {
      fp = gofiles[i]
      if (!(fp in seen) && (pkgdir(fp) in measuredPkg)) {
        order[++n] = fp
        seen[fp] = 1
        total[fp] = 0
        covered[fp] = 0
      }
    }
    # Existing profile and eligible GoFiles records keep their positions. Only an
    # accepted declaration still absent from both inventories gets a synthetic record.
    for (i = 1; i <= n; i++) represented[strip(order[i])] = 1
    for (i = 1; i <= en; i++) {
      fp = exclusion_order[i]
      if (!(fp in represented)) {
        order[++n] = fp
        represented[fp] = 1
        synthetic[fp] = 1
        total[fp] = 0
        covered[fp] = 0
      }
    }
    printf "["
    sep = ""
    for (i = 1; i <= n; i++) {
      file = order[i]
      rel = strip(file)
      if (excluded[rel]) {
        printf "%s{\"path\":\"%s\",\"covered\":%d,\"total\":%d,\"measured\":%s,\"excluded\":true,\"metric\":\"statement\",\"justification\":\"%s\"}", \
          sep, esc(rel), covered[file] + 0, total[file] + 0, (file in synthetic) ? "false" : "true", esc(reason[rel])
      } else {
        printf "%s{\"path\":\"%s\",\"covered\":%d,\"total\":%d,\"measured\":true,\"excluded\":false,\"metric\":\"statement\"}", \
          sep, esc(rel), covered[file] + 0, total[file] + 0
      }
      sep = ","
    }
    printf "]\n"
  }
'
