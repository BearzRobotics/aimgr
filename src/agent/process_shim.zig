//! Re-export of the shared argv-only process runner (kept separate so agent files import one name).
pub const run = @import("../process.zig").runIn;
pub const Result = @import("../process.zig").Result;
