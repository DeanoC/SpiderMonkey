const std = @import("std");

pub fn resolveRequestedPath(
    allocator: std.mem.Allocator,
    workspace_root_real: []const u8,
    requested_path: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, requested_path, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPath;
    const relative = if (std.mem.startsWith(u8, trimmed, "/")) std.mem.trimLeft(u8, trimmed, "/") else trimmed;
    const candidate = try std.fs.path.resolve(allocator, &.{ workspace_root_real, relative });
    errdefer allocator.free(candidate);
    if (!std.mem.startsWith(u8, candidate, workspace_root_real)) return error.PathEscapesWorkspace;
    return candidate;
}

pub fn localWorkspacePath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_path: []const u8,
) ![]u8 {
    if (!std.mem.startsWith(u8, workspace_path, "/")) return error.InvalidWorkspacePath;
    const relative = std.mem.trimLeft(u8, workspace_path, "/");
    if (relative.len == 0) return error.InvalidWorkspacePath;
    return std.fs.path.join(allocator, &.{ workspace_root, relative });
}

test "resolveRequestedPath maps canonical workspace paths into the mount root" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const resolved = try resolveRequestedPath(allocator, root, "/.spiderweb/venoms/terminal/control/invoke.json");
    defer allocator.free(resolved);

    const expected = try std.fs.path.join(allocator, &.{ root, ".spiderweb", "venoms", "terminal", "control", "invoke.json" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "resolveRequestedPath rejects escaping parents" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try std.testing.expectError(error.PathEscapesWorkspace, resolveRequestedPath(allocator, root, "../outside"));
}

test "localWorkspacePath converts canonical workspace paths to local mounted paths" {
    const allocator = std.testing.allocator;
    const local_path = try localWorkspacePath(allocator, "/tmp/workspace", "/agents/spider-monkey/home");
    defer allocator.free(local_path);
    try std.testing.expectEqualStrings("/tmp/workspace/agents/spider-monkey/home", local_path);
}
