# 0003: Optional experimental C interface

Status: accepted by the maintainer in conversation.

## Problem

Non-Zig programs (and Zig programs that avoid a package dependency) may want to
use md-zig. `ai/AGENTS.md` section 13 allows an optional C FFI if it does not
burden native consumers.

## Decision

- `src/capi.zig` adapts the native module to C types and is built only by the
  `c-api` build step (static and shared library) and by the C smoke test.
- `include/md.h` documents ownership, status codes and extension flags and is
  marked experimental.
- Opaque handle (`md_document`), caller frees with `md_free` / `md_free_string`;
  no caller memory is kept after a call returns. Allocation uses
  `std.heap.smp_allocator`, so the C side needs no allocator.
- Surface: parse from memory, HTML, terminal text. The tree and reader-based
  input are not exposed.

## Alternatives considered

- Expose the tree (`md_node_*` walker): larger surface to stabilise; deferred
  until a C consumer needs it.
- Reader callbacks for streaming input: needs a callback ABI; deferred.

## Consequences

- No stability promise: names and signatures may change in any release.
- Native consumers pay nothing: the module is a separate root and not imported
  by `root.zig`.
