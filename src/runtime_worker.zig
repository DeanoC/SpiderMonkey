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
    terminal_error: bool = false,
    error_code: ?[]u8 = null,

    pub fn deinit(self: RuntimeExecution, allocator: std.mem.Allocator) void {
        allocator.free(self.reply_text);
        allocator.free(self.log_text);
        if (self.error_code) |value| allocator.free(value);
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
    agent_root: []u8,
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
        const source_agents_dir = try std.fs.path.join(allocator, &.{ runtime_root, "agents" });
        defer allocator.free(source_agents_dir);
        const agents_dir = try resolveRuntimeAgentsDirectory(allocator, workspace_root_real);
        errdefer allocator.free(agents_dir);
        const agent_root = try std.fs.path.join(allocator, &.{ agents_dir, agent_id });
        errdefer allocator.free(agent_root);
        const ltm_directory = try resolveLtmDirectory(allocator, workspace_root_real, home_path, agent_id);
        errdefer allocator.free(ltm_directory);
        try std.fs.cwd().makePath(ltm_directory);
        try ensureRuntimeAgentFiles(allocator, source_agents_dir, assets_dir, agent_root, agent_id);

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
            .agent_root = agent_root,
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

        const log_text = try joinFrames(self.allocator, frames);
        errdefer self.allocator.free(log_text);
        const reply = try extractReplyText(self.allocator, frames);
        errdefer {
            self.allocator.free(reply.text);
            if (reply.error_code) |value| self.allocator.free(value);
        }
        return .{
            .reply_text = reply.text,
            .log_text = log_text,
            .terminal_error = reply.terminal_error,
            .error_code = reply.error_code,
        };
    }

    fn cleanup(self: *RuntimeWorker) void {
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.workspace_root_real);
        self.allocator.free(self.agent_id);
        self.allocator.free(self.assets_dir);
        self.allocator.free(self.agents_dir);
        self.allocator.free(self.agent_root);
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
    workspace_root_real: []const u8,
    home_path: ?[]const u8,
    agent_id: []const u8,
) ![]u8 {
    if (home_path) |value| {
        _ = value;
        return resolveLocalLtmDirectory(allocator, workspace_root_real, agent_id);
    }
    return resolveLocalLtmDirectory(allocator, workspace_root_real, agent_id);
}

fn resolveLocalLtmDirectory(
    allocator: std.mem.Allocator,
    workspace_root_real: []const u8,
    agent_id: []const u8,
) ![]u8 {
    const workspace_root = try resolveWorkspaceStateRoot(allocator, workspace_root_real);
    defer allocator.free(workspace_root);
    return std.fs.path.join(allocator, &.{ workspace_root, "agents", agent_id, "ltm" });
}

fn resolveRuntimeAgentsDirectory(
    allocator: std.mem.Allocator,
    workspace_root_real: []const u8,
) ![]u8 {
    const workspace_root = try resolveWorkspaceStateRoot(allocator, workspace_root_real);
    defer allocator.free(workspace_root);
    return std.fs.path.join(allocator, &.{ workspace_root, "runtime-agents" });
}

fn resolveLocalStateRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |raw_state_home| {
        defer allocator.free(raw_state_home);
        const state_home = std.mem.trim(u8, raw_state_home, " \t\r\n");
        if (state_home.len > 0) {
            return std.fs.path.join(allocator, &.{ state_home, "spider-monkey" });
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "spider-monkey" });
    } else |_| {}

    return allocator.dupe(u8, ".spider-monkey-state");
}

fn resolveWorkspaceStateRoot(allocator: std.mem.Allocator, workspace_root_real: []const u8) ![]u8 {
    const state_root = try resolveLocalStateRoot(allocator);
    defer allocator.free(state_root);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(workspace_root_real);
    const workspace_key = hasher.final();
    const workspace_segment = try std.fmt.allocPrint(allocator, "workspace-{x}", .{workspace_key});
    defer allocator.free(workspace_segment);

    return std.fs.path.join(allocator, &.{ state_root, "workspaces", workspace_segment });
}

fn ensureRuntimeAgentFiles(
    allocator: std.mem.Allocator,
    source_agents_dir: []const u8,
    assets_dir: []const u8,
    agent_root: []const u8,
    agent_id: []const u8,
) !void {
    try std.fs.cwd().makePath(agent_root);

    const source_agent_root = try std.fs.path.join(allocator, &.{ source_agents_dir, agent_id });
    defer allocator.free(source_agent_root);
    copyAgentFileIfPresent(allocator, source_agent_root, agent_root, "agent.json") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const template_files = [_][]const u8{ "CORE.md", "SOUL.md", "AGENT.md", "IDENTITY.md" };
    for (template_files) |filename| {
        const target_path = try std.fs.path.join(allocator, &.{ agent_root, filename });
        defer allocator.free(target_path);
        if (pathExists(target_path)) continue;

        const source_path = try std.fs.path.join(allocator, &.{ source_agent_root, filename });
        defer allocator.free(source_path);
        if (pathExists(source_path)) {
            try copyFileAbsolute(source_path, target_path);
            continue;
        }

        const template_path = try std.fs.path.join(allocator, &.{ assets_dir, filename });
        defer allocator.free(template_path);
        if (pathExists(template_path)) {
            try copyFileAbsolute(template_path, target_path);
        }
    }
}

fn copyAgentFileIfPresent(
    allocator: std.mem.Allocator,
    source_agent_root: []const u8,
    agent_root: []const u8,
    filename: []const u8,
) !void {
    const source_path = try std.fs.path.join(allocator, &.{ source_agent_root, filename });
    defer allocator.free(source_path);
    const target_path = try std.fs.path.join(allocator, &.{ agent_root, filename });
    defer allocator.free(target_path);
    try copyFileAbsolute(source_path, target_path);
}

fn copyFileAbsolute(source_path: []const u8, target_path: []const u8) !void {
    var source_file = try std.fs.openFileAbsolute(source_path, .{});
    defer source_file.close();
    const data = try source_file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024);
    defer std.heap.page_allocator.free(data);
    try std.fs.cwd().writeFile(.{
        .sub_path = target_path,
        .data = data,
    });
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

const ReplyExtraction = struct {
    text: []u8,
    terminal_error: bool,
    error_code: ?[]u8 = null,
};

fn extractReplyText(allocator: std.mem.Allocator, frames: [][]u8) !ReplyExtraction {
    var latest_reply: ?[]u8 = null;
    var latest_error: ?[]u8 = null;
    var latest_error_code: ?[]u8 = null;
    errdefer {
        if (latest_reply) |value| allocator.free(value);
        if (latest_error) |value| allocator.free(value);
        if (latest_error_code) |value| allocator.free(value);
    }
    for (frames) |frame| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const msg_type = parsed.value.object.get("type") orelse continue;
        if (msg_type != .string) continue;
        if (std.mem.eql(u8, msg_type.string, "session.receive")) {
            const content = parsed.value.object.get("content") orelse continue;
            if (content != .string) continue;
            if (latest_reply) |value| allocator.free(value);
            latest_reply = try allocator.dupe(u8, content.string);
            continue;
        }
        if (std.mem.eql(u8, msg_type.string, "error")) {
            const message_value = parsed.value.object.get("message") orelse continue;
            if (message_value != .string or message_value.string.len == 0) continue;
            if (latest_error) |value| allocator.free(value);
            latest_error = try allocator.dupe(u8, message_value.string);

            if (latest_error_code) |value| allocator.free(value);
            latest_error_code = null;
            if (parsed.value.object.get("code")) |code_value| {
                if (code_value == .string and code_value.string.len > 0) {
                    latest_error_code = try allocator.dupe(u8, code_value.string);
                }
            }
        }
    }
    if (latest_reply) |value| {
        return .{
            .text = value,
            .terminal_error = false,
        };
    }
    if (latest_error) |value| {
        return .{
            .text = value,
            .terminal_error = true,
            .error_code = latest_error_code,
        };
    }
    return error.MissingReplyFrame;
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
    const local_path = resolveToolPath(self, allocator, requested_path) catch |err| {
        return toolFailurePathError(allocator, .execution_failed, "file_read", requested_path, requested_path, err);
    };
    defer allocator.free(local_path);

    const content = std.fs.cwd().readFileAlloc(allocator, local_path, max_bytes) catch |err| {
        return toolFailurePathError(allocator, .execution_failed, "file_read", requested_path, local_path, err);
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
    const local_path = resolveToolPath(self, allocator, requested_path) catch |err| {
        return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, requested_path, err);
    };
    defer allocator.free(local_path);

    if (create_parents) {
        ensureAbsoluteParentDir(local_path) catch |err| {
            return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, local_path, err);
        };
    }

    if (append) {
        var file = std.fs.createFileAbsolute(local_path, .{ .truncate = false }) catch |err| {
            return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, local_path, err);
        };
        defer file.close();
        file.seekFromEnd(0) catch |err| return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, local_path, err);
        file.writeAll(content) catch |err| return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, local_path, err);
    } else {
        var file = std.fs.createFileAbsolute(local_path, .{ .truncate = true }) catch |err| {
            return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, local_path, err);
        };
        defer file.close();
        file.writeAll(content) catch |err| return toolFailurePathError(allocator, .execution_failed, "file_write", requested_path, local_path, err);
    }

    const payload = blk: {
        if (isChatReplyPath(requested_path)) {
            const escaped_content = jsonEscape(allocator, content) catch return toolFailure(allocator, .execution_failed, "out of memory");
            defer allocator.free(escaped_content);
            break :blk std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"bytes_written\":{d},\"append\":{s},\"ready\":true,\"wait_until_ready\":{s},\"chat_reply\":{{\"content\":\"{s}\"}}}}",
                .{
                    requested_path,
                    content.len,
                    if (append) "true" else "false",
                    if (wait_until_ready) "true" else "false",
                    escaped_content,
                },
            ) catch return toolFailure(allocator, .execution_failed, "out of memory");
        }
        break :blk std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"bytes_written\":{d},\"append\":{s},\"ready\":true,\"wait_until_ready\":{s}}}",
            .{
                requested_path,
                content.len,
                if (append) "true" else "false",
                if (wait_until_ready) "true" else "false",
            },
        ) catch return toolFailure(allocator, .execution_failed, "out of memory");
    };
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
    const local_path = resolveToolPath(self, allocator, requested_path) catch |err| {
        return toolFailurePathError(allocator, .execution_failed, "file_list", requested_path, requested_path, err);
    };
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
        var walk_dir = std.fs.openDirAbsolute(local_path, .{ .iterate = true }) catch |err| {
            return toolFailurePathError(allocator, .execution_failed, "file_list", requested_path, local_path, err);
        };
        defer walk_dir.close();
        var walker = walk_dir.walk(allocator) catch |err| return toolFailurePathError(allocator, .execution_failed, "file_list", requested_path, local_path, err);
        defer walker.deinit();
        while (walker.next() catch |err| return toolFailurePathError(allocator, .execution_failed, "file_list", requested_path, local_path, err)) |entry| {
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
        var dir = std.fs.openDirAbsolute(local_path, .{ .iterate = true }) catch |err| {
            return toolFailurePathError(allocator, .execution_failed, "file_list", requested_path, local_path, err);
        };
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch |err| return toolFailurePathError(allocator, .execution_failed, "file_list", requested_path, local_path, err)) |entry| {
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
    try std.fs.cwd().makePath(parent);
}

fn isChatReplyPath(path: []const u8) bool {
    const normalized = std.mem.trim(u8, path, " \t\r\n");
    return std.mem.eql(u8, normalized, "/services/chat/control/reply") or
        std.mem.eql(u8, normalized, "/global/chat/control/reply") or
        std.mem.eql(u8, normalized, "/nodes/local/venoms/chat/control/reply");
}

fn localWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, workspace_path: []const u8) ![]u8 {
    return workspace_paths.localWorkspacePath(allocator, workspace_root, workspace_path);
}

fn resolveToolPath(self: *RuntimeWorker, allocator: std.mem.Allocator, requested_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, requested_path, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPath;
    if (std.mem.startsWith(u8, trimmed, "/")) {
        return workspace_paths.resolveRequestedPath(allocator, self.workspace_root_real, trimmed);
    }
    return workspace_paths.resolveRequestedPath(allocator, self.agent_root, trimmed);
}

test "resolveLtmDirectory keeps runtime sqlite outside the mounted workspace" {
    const allocator = std.testing.allocator;
    const ltm_dir = try resolveLtmDirectory(allocator, "/tmp/mounted-workspace", "/nodes/local/fs/.spiderweb/agents/spider-monkey/home", "spider-monkey");
    defer allocator.free(ltm_dir);

    try std.testing.expect(std.mem.indexOf(u8, ltm_dir, "/tmp/mounted-workspace") == null);
    try std.testing.expect(std.mem.indexOf(u8, ltm_dir, "spider-monkey") != null);
    try std.testing.expect(std.mem.endsWith(u8, ltm_dir, "/ltm"));
}

test "resolveToolPath uses agent root for relative paths and workspace root for absolute paths" {
    const allocator = std.testing.allocator;
    const worker = RuntimeWorker{
        .allocator = allocator,
        .workspace_root = try allocator.dupe(u8, "/tmp/mount"),
        .workspace_root_real = try allocator.dupe(u8, "/tmp/mount"),
        .agent_id = try allocator.dupe(u8, "spider-monkey"),
        .emit_debug = false,
        .server = undefined,
        .assets_dir = try allocator.dupe(u8, "/tmp/templates"),
        .agents_dir = try allocator.dupe(u8, "/tmp/runtime-agents"),
        .agent_root = try allocator.dupe(u8, "/tmp/runtime-agents/spider-monkey"),
        .ltm_directory = try allocator.dupe(u8, "/tmp/state/ltm"),
    };
    defer {
        allocator.free(worker.workspace_root);
        allocator.free(worker.workspace_root_real);
        allocator.free(worker.agent_id);
        allocator.free(worker.assets_dir);
        allocator.free(worker.agents_dir);
        allocator.free(worker.agent_root);
        allocator.free(worker.ltm_directory);
    }

    const relative = try resolveToolPath(@constCast(&worker), allocator, "CORE.md");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/tmp/runtime-agents/spider-monkey/CORE.md", relative);

    const absolute = try resolveToolPath(@constCast(&worker), allocator, "/.spiderweb/venoms/terminal/control/invoke.json");
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/mount/.spiderweb/venoms/terminal/control/invoke.json", absolute);
}

test "ensureAbsoluteParentDir creates nested parent directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const target = try std.fs.path.join(allocator, &.{ root, "nested", "deeper", "file.txt" });
    defer allocator.free(target);

    try ensureAbsoluteParentDir(target);

    const nested = try std.fs.path.join(allocator, &.{ root, "nested", "deeper" });
    defer allocator.free(nested);
    try std.fs.accessAbsolute(nested, .{});
}

test "handleFileWrite returns chat_reply payload for reply targets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const workspace_root = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(workspace_root);
    const agent_root = try std.fs.path.join(allocator, &.{ root, "runtime-agents", "spider-monkey" });
    defer allocator.free(agent_root);
    try std.fs.cwd().makePath(workspace_root);
    try std.fs.cwd().makePath(agent_root);

    const worker = RuntimeWorker{
        .allocator = allocator,
        .workspace_root = try allocator.dupe(u8, workspace_root),
        .workspace_root_real = try allocator.dupe(u8, workspace_root),
        .agent_id = try allocator.dupe(u8, "spider-monkey"),
        .emit_debug = false,
        .server = undefined,
        .assets_dir = try allocator.dupe(u8, "/tmp/templates"),
        .agents_dir = try allocator.dupe(u8, "/tmp/runtime-agents"),
        .agent_root = try allocator.dupe(u8, agent_root),
        .ltm_directory = try allocator.dupe(u8, "/tmp/state/ltm"),
    };
    defer {
        allocator.free(worker.workspace_root);
        allocator.free(worker.workspace_root_real);
        allocator.free(worker.agent_id);
        allocator.free(worker.assets_dir);
        allocator.free(worker.agents_dir);
        allocator.free(worker.agent_root);
        allocator.free(worker.ltm_directory);
    }

    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("path", .{ .string = "/nodes/local/venoms/chat/control/reply" });
    try args.put("content", .{ .string = "hello from spider monkey" });

    const result = handleFileWrite(@constCast(&worker), allocator, args);
    defer switch (result) {
        .success => |success| allocator.free(success.payload_json),
        .failure => |failure| allocator.free(failure.message),
    };

    try std.testing.expect(result == .success);
    try std.testing.expect(std.mem.indexOf(u8, result.success.payload_json, "\"chat_reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.success.payload_json, "hello from spider monkey") != null);
}

test "extractReplyText falls back to terminal error frames" {
    const allocator = std.testing.allocator;
    const frames = [_][]const u8{
        "{\"type\":\"error\",\"code\":\"provider_unavailable\",\"message\":\"provider stream failed\"}",
    };

    const extracted = try extractReplyText(allocator, frames[0..]);
    defer {
        allocator.free(extracted.text);
        if (extracted.error_code) |value| allocator.free(value);
    }

    try std.testing.expect(extracted.terminal_error);
    try std.testing.expectEqualStrings("provider stream failed", extracted.text);
    try std.testing.expectEqualStrings("provider_unavailable", extracted.error_code.?);
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

fn toolFailurePathError(
    allocator: std.mem.Allocator,
    code: tool_registry.ToolErrorCode,
    op: []const u8,
    requested_path: []const u8,
    local_path: []const u8,
    err: anyerror,
) tool_registry.ToolExecutionResult {
    const message = std.fmt.allocPrint(
        allocator,
        "{s} failed for path '{s}' (local '{s}'): {s}",
        .{ op, requested_path, local_path, @errorName(err) },
    ) catch return toolFailure(allocator, code, @errorName(err));
    return .{
        .failure = .{
            .code = code,
            .message = message,
        },
    };
}
