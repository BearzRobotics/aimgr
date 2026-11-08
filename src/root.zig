pub const backend = @import("backend.zig");
pub const process = @import("process.zig");
pub const inventory = @import("inventory.zig");
pub const catalog = @import("catalog.zig");
pub const config = @import("config.zig");
pub const launcher = @import("launcher.zig");
pub const netstat = @import("netstat.zig");
pub const supervise = @import("supervise.zig");
pub const launch_cmd = @import("launch_cmd.zig");
pub const manage = @import("manage.zig");
pub const manage_cmd = @import("manage_cmd.zig");
pub const term = @import("tui/term.zig");
pub const tui_model = @import("tui/model.zig");
pub const jobs = @import("tui/jobs.zig");
pub const tui_state = @import("tui/state.zig");
pub const tui_draw = @import("tui/draw.zig");
pub const tui_app = @import("tui/app.zig");
pub const catalog_io = @import("catalog_io.zig");
pub const abliterate = @import("abliterate.zig");
pub const abliterate_cmd = @import("abliterate_cmd.zig");
pub const hardware = @import("hardware.zig");
pub const discover = @import("discover.zig");
pub const ollama = @import("backends/ollama.zig");
pub const llama = @import("backends/llama.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
