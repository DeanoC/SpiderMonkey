const std = @import("std");
const Config = @import("config.zig");
const runtime_server = @import("agents/runtime_server.zig");
const tool_registry = @import("ziggy-tool-runtime").tool_registry;
const workspace_paths = @import("workspace_paths.zig");

pub const RuntimeOptions = struct {
    config_path: ?[]const u8 = null,
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    emit_debug: bool = false,
};

pub const RuntimeExecution = struct {
    reply_text: []u8,
    log_text: []u8,

    pub fn deinit(self: RuntimeExecution, allocator: std.mem.Allocator) void {
        allocator.free(self.reply_text);
        allocator.free(self.log_text);
    }
};

pub const RuntimeWorker = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    workspace_root_real: []u8,
    agent_id: []u8,
    emit_debug: bool,
    server: *runtime_server.RuntimeServer,
    assets_dir: []u8,
    agents_dir: []u8,
    ltm_directory: []u8,

    pub fn create(
        allocator: std.mem.Allocator,
        workspace_root: []const u8,
        agent_id: []const u8,
        home_path: ?[]const u8,
        options: RuntimeOptions,
    ) !*RuntimeWorker {
        const self = try allocator.create(RuntimeWorker);
        errdefer allocator.destroy(self);

        const workspace_root_owned = try allocator.dupe(u8, workspace_root);
        errdefer allocator.free(workspace_root_owned);
        const workspace_root_real = try std.fs.cwd().realpathAlloc(allocator, workspace_root);
        errdefer allocator.free(workspace_root_real);
        const agent_id_owned = try allocator.dupe(u8, agent_id);
        errdefer allocator.free(agent_id_owned);
        const runtime_root = try resolveRuntimeRoot(allocator);
        defer allocator.free(runtime_root);
        const assets_dir = try std.fs.path.join(allocator, &.{ runtime_root, "templates" });
        errdefer allocator.free(assets_dir);
        const agents_dir = try std.fs.path.join(allocator, &.{ runtime_root, "agents" });
        errdefer allocator.free(agents_dir);
        const ltm_directory = try resolveLtmDirectory(allocator, workspace_root, home_path, agent_id);
        errdefer allocator.free(ltm_directory);
        try std.fs.cwd().makePath(ltm_directory);

        var config = try Config.init(allocator, options.config_path);
        defer config.deinit();
        overrideProviderConfig(allocator, &config.provider, options);
        overrideRuntimeConfig(allocator, &config.runtime, agent_id, workspace_root_real, assets_dir, agents_dir, ltm_directory);

        self.* = .{
            .allocator = allocator,
            .workspace_root = workspace_root_owned,
            .workspace_root_real = workspace_root_real,
            .agent_id = agent_id_owned,
            .emit_debug = options.emit_debug,
            .server = undefined,
            .assets_dir = assets_dir,
            .agents_dir = agents_dir,
            .ltm_directory = ltm_directory,
        };
        errdefer self.cleanup();

        self.server = try runtime_server.RuntimeServer.createWithProviderAndToolDispatch(
            allocator,
            self.agent_id,
            config.runtime,
            config.provider,
            self,
            dispatchTool,
        );
        return self;
    }

    pub fn destroy(self: *RuntimeWorker) void {
        const allocator = self.allocator;
        self.server.destroy();
        self.cleanup();
        allocator.destroy(self);
    }

    pub fn executePrompt(self: *RuntimeWorker, prompt: []const u8) !RuntimeExecution {
        const request_json = try buildSessionSendRequest(self.allocator, prompt);
        defer self.allocator.free(request_json);

        const frames = try self.server.handleMessageFramesWithDebug(request_json, self.emit_debug);
        defer runtime_server.deinitResponseFrames(self.allocator, frames);

        const reply_text = try extractReplyText(self.allocator, frames);
        errdefer self.allocator.free(reply_text);
        const log_text = try joinFrames(self.allocator, frames);
        errdefer self.allocator.free(log_text);
        return .{
            .reply_text = reply_text,
            .log_text = log_text,
        };
    }

    fn cleanup(self: *RuntimeWorker) void {
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.workspace_root_real);
        self.allocator.free(self.agent_id);
        self.allocator.free(self.assets_dir);
        self.allocator.free(self.agents_dir);
        self.allocator.free(self.ltm_directory);
        self.* = undefined;
    }
};

fn overrideProviderConfig(
    allocator: std.mem.Allocator,
    provider: *Config.ProviderConfig,
    options: RuntimeOptions,
) void {
    if (options.provider_name) |value| {
        allocator.free(provider.name);
        provider.name = allocator.dupe(u8, value) catch @panic("out of memory");
    }
    if (options.model_name) |value| {
        if (provider.model) |current| allocator.free(current);
        provider.model = allocator.dupe(u8, value) catch @panic("out of memory");
    }
    if (options.api_key) |value| {
        if (provider.api_key) |current| allocator.free(current);
        provider.api_key = allocator.dupe(u8, value) catch @panic("out of memory");
    }
    if (options.base_url) |value| {
        if (provider.base_url) |current| allocator.free(current);
        provider.base_url = allocator.dupe(u8, value) catch @panic("out of memory");
    }
}

fn overrideRuntimeConfig(
    allocator: std.mem.Allocator,
    runtime: *Config.RuntimeConfig,
    agent_id: []const u8,
    workspace_root_real: []const u8,
    assets_dir: []const u8,
    agents_dir: []const u8,
    ltm_directory: []const u8,
) void {
    allocator.free(runtime.default_agent_id);
    runtime.default_agent_id = allocator.dupe(u8, agent_id) catch @panic("out of memory");
    allocator.free(runtime.spider_web_root);
    runtime.spider_web_root = allocator.dupe(u8, workspace_root_real) catch @panic("out of memory");
    allocator.free(runtime.assets_dir);
    runtime.assets_dir = allocator.dupe(u8, assets_dir) catch @panic("out of memory");
    allocator.free(runtime.agents_dir);
    runtime.agents_dir = allocator.dupe(u8, agents_dir) catch @panic("out of memory");
    allocator.free(runtime.ltm_directory);
    runtime.ltm_directory = allocator.dupe(u8, ltm_directory) catch @panic("out of memory");
    allocator.free(runtime.ltm_filename);
    runtime.ltm_filename = allocator.dupe(u8, "runtime-memory.db") catch @panic("out of memory");
    runtime.sandbox_enabled = false;
}

fn resolveRuntimeRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "SPIDER_MONKEY_ROOT")) |env_root| {
        errdefer allocator.free(env_root);
        if (isRuntimeRoot(env_root)) return env_root;
        allocator.free(env_root);
    } else |_| {}

    const cwd_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(cwd_root);
    if (isRuntimeRoot(cwd_root)) return cwd_root;
    allocator.free(cwd_root);

    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    const candidates = [_][]const []const u8{
        &.{exe_dir},
        &.{ exe_dir, ".." },
        &.{ exe_dir, "..", ".." },
    };
    for (candidates) |parts| {
        const candidate = try std.fs.path.resolve(allocator, parts);
        errdefer allocator.free(candidate);
        if (isRuntimeRoot(candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.RuntimeRootNotFound;
}

fn isRuntimeRoot(path: []const u8) bool {
    const templates = std.fs.path.join(std.heap.page_allocator, &.{ path, "templates" }) catch return false;
    defer std.heap.page_allocator.free(templates);
    const agents = std.fs.path.join(std.heap.page_allocator, &.{ path, "agents" }) catch return false;
    defer std.heap.page_allocator.free(agents);
    return pathExists(templates) and pathExists(agents);
}

fn resolveLtmDirectory(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    home_path: ?[]const u8,
    agent_id: []const u8,
) ![]u8 {
    if (home_path) |value| {
        const local_home = try localWorkspacePath(allocator, workspace_root, value);
        defer allocator.free(local_home);
        return std.fs.path.join(allocator, &.{ local_home, "state", "ltm" });
    }
    return std.fs.path.join(allocator, &.{ workspace_root, ".spider-monkey", agent_id, "state", "ltm" });
}

fn buildSessionSendRequest(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const escaped_prompt = try jsonEscape(allocator, prompt);
    defer allocator.free(escaped_prompt);
    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"job-request\",\"type\":\"session.send\",\"content\":\"{s}\"}}",
        .{escaped_prompt},
    );
}

fn extractReplyText(allocator: std.mem.Allocator, frames: [][]u8) ![]u8 {
    var latest_reply: ?[]u8 = null;
    errdefer if (latest_reply) |value| allocator.free(value);
    for (frames) |frame| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const msg_type = parsed.value.object.get("type") orelse continue;
        if (msg_type != .string or !std.mem.eql(u8, msg_type.string, "session.receive")) continue;
        const content = parsed.value.object.get("content") orelse continue;
        if (content != .string) continue;
        if (latest_reply) |value| allocator.free(value);
        latest_reply = try allocator.dupe(u8, content.string);
    }
    return latest_reply orelse error.MissingReplyFrame;
}

fn joinFrames(allocator: std.mem.Allocator, frames: [][]u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (frames, 0..) |frame, index| {
        if (index > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, frame);
    }
    if (frames.len > 0) try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn dispatchTool(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args_json: []const u8,
) tool_registry.ToolExecutionResult {
    const self: *RuntimeWorker = @ptrCast(@alignCast(ctx));
    return dispatchToolCall(self, allocator, tool_name, args_json);
}

fn dispatchToolCall(
    self: *RuntimeWorker,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args_json: []const u8,
) tool_registry.ToolExecutionResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
        return toolFailure(allocator, .invalid_params, "arguments must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return toolFailure(allocator, .invalid_params, "arguments must be a JSON object");

    if (std.mem.eql(u8, tool_name, "file_read")) return handleFileRead(self, allocator, parsed.value.object);
    if (std.mem.eql(u8, tool_name, "file_write")) return handleFileWrite(self, allocator, parsed.value.object);
    if (std.mem.eql(u8, tool_name, "file_list")) return handleFileList(self, allocator, parsed.value.object);
    return toolFailure(allocator, .tool_not_found, "unsupported remote tool");
}

fn handleFileRead(
    self: *RuntimeWorker,
    allocator: std.mem.Allocator,
    args: std.json.ObjectMap,
) tool_registry.ToolExecutionResult {
    const requested_path = requiredString(args, "path") orelse return toolFailure(allocator, .invalid_params, "missing required parameter: path");
    const max_bytes = parseUsize(args, "max_bytes", 128 * 1024) orelse return toolFailure(allocator, .invalid_params, "max_bytes must be a non-negative integer");
    const wait_until_ready = parseBool(args, "wait_until_ready", true) orelse return toolFailure(allocator, .invalid_params, "wait_until_ready must be boolean");
    const local_path = workspace_paths.resolveRequestedPath(allocator, self.workspace_root_real, requested_path) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    defer allocator.free(local_path);

    const content = std.fs.cwd().readFileAlloc(allocator, local_path, max_bytes) catch |err| {
        return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    };
    defer allocator.free(content);
    const escaped_content = jsonEscape(allocator, content) catch return toolFailure(allocator, .execution_failed, "out of memory");
    defer allocator.free(escaped_content);

    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"bytes\":{d},\"truncated\":false,\"content\":\"{s}\",\"ready\":true,\"wait_until_ready\":{s}}}",
        .{
            requested_path,
            content.len,
            escaped_content,
            if (wait_until_ready) "true" else "false",
        },
    ) catch return toolFailure(allocator, .execution_failed, "out of memory");
    return .{ .success = .{ .payload_json = payload } };
}

fn handleFileWrite(
    self: *RuntimeWorker,
    allocator: std.mem.Allocator,
    args: std.json.ObjectMap,
) tool_registry.ToolExecutionResult {
    const requested_path = requiredString(args, "path") orelse return toolFailure(allocator, .invalid_params, "missing required parameter: path");
    const content = requiredString(args, "content") orelse return toolFailure(allocator, .invalid_params, "missing required parameter: content");
    const append = parseBool(args, "append", false) orelse return toolFailure(allocator, .invalid_params, "append must be boolean");
    const create_parents = parseBool(args, "create_parents", true) orelse return toolFailure(allocator, .invalid_params, "create_parents must be boolean");
    const wait_until_ready = parseBool(args, "wait_until_ready", true) orelse return toolFailure(allocator, .invalid_params, "wait_until_ready must be boolean");
    const local_path = workspace_paths.resolveRequestedPath(allocator, self.workspace_root_real, requested_path) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    defer allocator.free(local_path);

    if (create_parents) {
        ensureAbsoluteParentDir(local_path) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    }

    if (append) {
        var file = std.fs.createFileAbsolute(local_path, .{ .truncate = false }) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
        defer file.close();
        file.seekFromEnd(0) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
        file.writeAll(content) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    } else {
        var file = std.fs.createFileAbsolute(local_path, .{ .truncate = true }) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
        defer file.close();
        file.writeAll(content) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    }

    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"bytes_written\":{d},\"append\":{s},\"ready\":true,\"wait_until_ready\":{s}}}",
        .{
            requested_path,
            content.len,
            if (append) "true" else "false",
            if (wait_until_ready) "true" else "false",
        },
    ) catch return toolFailure(allocator, .execution_failed, "out of memory");
    return .{ .success = .{ .payload_json = payload } };
}

fn handleFileList(
    self: *RuntimeWorker,
    allocator: std.mem.Allocator,
    args: std.json.ObjectMap,
) tool_registry.ToolExecutionResult {
    const requested_path = optionalString(args, "path") orelse ".";
    const recursive = parseBool(args, "recursive", false) orelse return toolFailure(allocator, .invalid_params, "recursive must be boolean");
    const max_entries = parseUsize(args, "max_entries", 500) orelse return toolFailure(allocator, .invalid_params, "max_entries must be integer");
    const effective_max = @min(max_entries, 5_000);
    const local_path = workspace_paths.resolveRequestedPath(allocator, self.workspace_root_real, requested_path) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
    defer allocator.free(local_path);

    var entries = std.ArrayListUnmanaged(u8){};
    errdefer entries.deinit(allocator);
    entries.appendSlice(allocator, "{\"path\":\"") catch return toolFailure(allocator, .execution_failed, "out of memory");
    appendJsonEscaped(allocator, &entries, requested_path) catch return toolFailure(allocator, .execution_failed, "out of memory");
    entries.appendSlice(allocator, "\",\"entries\":[") catch return toolFailure(allocator, .execution_failed, "out of memory");

    var count: usize = 0;
    var truncated = false;
    var first = true;

    if (recursive) {
        var walk_dir = std.fs.openDirAbsolute(local_path, .{ .iterate = true }) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
        defer walk_dir.close();
        var walker = walk_dir.walk(allocator) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
        defer walker.deinit();
        while (walker.next() catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err))) |entry| {
            if (count >= effective_max) {
                truncated = true;
                break;
            }
            if (!first) entries.append(allocator, ',') catch return toolFailure(allocator, .execution_failed, "out of memory");
            first = false;
            count += 1;
            appendListingEntry(allocator, &entries, entry.path, entry.kind) catch return toolFailure(allocator, .execution_failed, "out of memory");
        }
    } else {
        var dir = std.fs.openDirAbsolute(local_path, .{ .iterate = true }) catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err));
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch |err| return toolFailureOwned(allocator, .execution_failed, @errorName(err))) |entry| {
            if (count >= effective_max) {
                truncated = true;
                break;
            }
            if (!first) entries.append(allocator, ',') catch return toolFailure(allocator, .execution_failed, "out of memory");
            first = false;
            count += 1;
            appendListingEntry(allocator, &entries, entry.name, entry.kind) catch return toolFailure(allocator, .execution_failed, "out of memory");
        }
    }

    entries.appendSlice(allocator, "],\"truncated\":") catch return toolFailure(allocator, .execution_failed, "out of memory");
    entries.appendSlice(allocator, if (truncated) "true" else "false") catch return toolFailure(allocator, .execution_failed, "out of memory");
    entries.append(allocator, '}') catch return toolFailure(allocator, .execution_failed, "out of memory");
    return .{ .success = .{ .payload_json = entries.toOwnedSlice(allocator) catch return toolFailure(allocator, .execution_failed, "out of memory") } };
}

fn appendListingEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    kind: std.fs.Dir.Entry.Kind,
) !void {
    try out.appendSlice(allocator, "{\"name\":\"");
    try appendJsonEscaped(allocator, out, name);
    try out.appendSlice(allocator, "\",\"type\":\"");
    try out.appendSlice(allocator, switch (kind) {
        .directory => "directory",
        .file => "file",
        .sym_link => "symlink",
        else => "other",
    });
    try out.appendSlice(allocator, "\"}");
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn requiredString(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn optionalString(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn parseBool(args: std.json.ObjectMap, key: []const u8, default: bool) ?bool {
    const value = args.get(key) orelse return default;
    return switch (value) {
        .bool => value.bool,
        else => null,
    };
}

fn parseUsize(args: std.json.ObjectMap, key: []const u8, default: usize) ?usize {
    const value = args.get(key) orelse return default;
    return switch (value) {
        .integer => if (value.integer < 0) null else @intCast(value.integer),
        else => null,
    };
}

fn ensureAbsoluteParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.fs.makeDirAbsolute(parent);
}

fn localWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, workspace_path: []const u8) ![]u8 {
    return workspace_paths.localWorkspacePath(allocator, workspace_root, workspace_path);
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try appendJsonEscaped(allocator, &out, input);
    return out.toOwnedSlice(allocator);
}

fn appendJsonEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), input: []const u8) !void {
    for (input) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, char),
        }
    }
}

fn toolFailure(
    allocator: std.mem.Allocator,
    code: tool_registry.ToolErrorCode,
    message: []const u8,
) tool_registry.ToolExecutionResult {
    return .{
        .failure = .{
            .code = code,
            .message = allocator.dupe(u8, message) catch @panic("out of memory"),
        },
    };
}

fn toolFailureOwned(
    allocator: std.mem.Allocator,
    code: tool_registry.ToolErrorCode,
    message: []const u8,
) tool_registry.ToolExecutionResult {
    return .{
        .failure = .{
            .code = code,
            .message = allocator.dupe(u8, message) catch @panic("out of memory"),
        },
    };
}
