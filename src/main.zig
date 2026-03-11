const std = @import("std");
const runtime_worker = @import("runtime_worker.zig");

const default_interval_ms: u64 = 5_000;

const max_preview_bytes: usize = 96;

const default_agent_id: []const u8 = "spider-monkey";

const HomeClaim = struct {
    agent_id: []u8,
    service_root: []u8,
    home_path: []u8,
    target_path: []u8,

    fn deinit(self: *HomeClaim, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.service_root);
        allocator.free(self.home_path);
        allocator.free(self.target_path);
        self.* = undefined;
    }
};

const WorkerRegistration = struct {
    agent_id: []u8,
    worker_id: []u8,
    service_root: []u8,
    node_path: []u8,
    memory_path: ?[]u8 = null,
    sub_brains_path: ?[]u8 = null,

    fn deinit(self: *WorkerRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.worker_id);
        allocator.free(self.service_root);
        allocator.free(self.node_path);
        if (self.memory_path) |value| allocator.free(value);
        if (self.sub_brains_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

const JobSummary = struct {
    job_id: []u8,
    job_path: []u8,
    state: []u8,
    input_text: ?[]u8 = null,
    input_preview: ?[]u8 = null,

    fn deinit(self: *JobSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.job_path);
        allocator.free(self.state);
        if (self.input_text) |value| allocator.free(value);
        if (self.input_preview) |value| allocator.free(value);
        self.* = undefined;
    }
};

const ScanReport = struct {
    workspace_root: []const u8,
    services_exists: bool,
    services_chat_exists: bool,
    services_jobs_exists: bool,
    global_chat_exists: bool,
    global_jobs_exists: bool,
    meta_exists: bool,
    jobs_path: ?[]u8,
    job_dir_count: usize,
    jobs: []JobSummary = &.{},

    fn deinit(self: *ScanReport, allocator: std.mem.Allocator) void {
        if (self.jobs_path) |value| allocator.free(value);
        for (self.jobs) |*job| job.deinit(allocator);
        if (self.jobs.len > 0) allocator.free(self.jobs);
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printHelp();
        return;
    }

    if (!std.mem.eql(u8, args[1], "run")) {
        try printHelp();
        return error.InvalidArguments;
    }

    var workspace_root: ?[]const u8 = null;
    var agent_id = default_agent_id;
    var worker_id: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var provider_name: ?[]const u8 = null;
    var model_name: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var base_url: ?[]const u8 = null;
    var emit_debug = false;
    var once = false;
    var scan_only = false;
    var interval_ms = default_interval_ms;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--workspace-root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            workspace_root = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--agent-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            agent_id = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--worker-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            worker_id = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            provider_name = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            model_name = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--api-key")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            api_key = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--base-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            base_url = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit-debug")) {
            emit_debug = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--once")) {
            once = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scan-only")) {
            scan_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            interval_ms = try std.fmt.parseInt(u64, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        }
        return error.InvalidArguments;
    }

    const root = workspace_root orelse return error.InvalidArguments;
    try ensureWorkspaceRoot(root);
    const effective_worker_id = if (worker_id) |value|
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "{s}-{d}", .{ agent_id, std.time.milliTimestamp() });
    defer allocator.free(effective_worker_id);

    var home_claim = try ensureAgentHome(allocator, root, agent_id);
    defer if (home_claim) |*claim| claim.deinit(allocator);
    var worker_registration = try ensureWorkerRegistration(allocator, root, agent_id, effective_worker_id);
    defer if (worker_registration) |registration| sendWorkerDetach(allocator, registration) catch {};
    defer if (worker_registration) |*registration| registration.deinit(allocator);

    const runtime = if (!scan_only)
        try runtime_worker.RuntimeWorker.create(allocator, root, agent_id, if (home_claim) |claim| claim.home_path else null, .{
            .config_path = config_path,
            .provider_name = provider_name,
            .model_name = model_name,
            .api_key = api_key,
            .base_url = base_url,
            .emit_debug = emit_debug,
        })
    else
        null;
    defer if (runtime) |value| value.destroy();

    try printStartupSummary(allocator, root, agent_id, effective_worker_id, once, scan_only, interval_ms, home_claim, worker_registration, runtime != null, emit_debug);
    try runScanner(allocator, root, once, scan_only, interval_ms, worker_registration, runtime);
}

fn runScanner(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    once: bool,
    scan_only: bool,
    interval_ms: u64,
    worker_registration: ?WorkerRegistration,
    runtime: ?*runtime_worker.RuntimeWorker,
) !void {
    while (true) {
        if (worker_registration) |registration| {
            try sendWorkerHeartbeat(allocator, registration);
        }
        var pre_report = try scanWorkspace(allocator, workspace_root);
        if (!scan_only) {
            const processed = try processQueuedJobs(allocator, workspace_root, pre_report.jobs, runtime);
            if (processed > 0) {
                var out = std.fs.File.stdout();
                const line = try std.fmt.allocPrint(allocator, "processed_jobs: {d}\n", .{processed});
                defer allocator.free(line);
                try out.writeAll(line);
            }
        }
        pre_report.deinit(allocator);

        var report = try scanWorkspace(allocator, workspace_root);
        defer report.deinit(allocator);
        try printScanReport(allocator, &report);

        if (once) return;
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
}

fn scanWorkspace(allocator: std.mem.Allocator, workspace_root: []const u8) !ScanReport {
    const services_path = try std.fs.path.join(allocator, &.{ workspace_root, "services" });
    defer allocator.free(services_path);
    const services_chat_path = try std.fs.path.join(allocator, &.{ workspace_root, "services", "chat" });
    defer allocator.free(services_chat_path);
    const services_jobs_path = try std.fs.path.join(allocator, &.{ workspace_root, "services", "jobs" });
    defer allocator.free(services_jobs_path);
    const global_chat_path = try std.fs.path.join(allocator, &.{ workspace_root, "global", "chat" });
    defer allocator.free(global_chat_path);
    const global_jobs_path = try std.fs.path.join(allocator, &.{ workspace_root, "global", "jobs" });
    defer allocator.free(global_jobs_path);
    const meta_path = try std.fs.path.join(allocator, &.{ workspace_root, "meta" });
    defer allocator.free(meta_path);

    const jobs_exists = pathExists(services_jobs_path);
    const jobs = if (jobs_exists) try scanJobs(allocator, services_jobs_path) else try allocator.alloc(JobSummary, 0);
    return .{
        .workspace_root = workspace_root,
        .services_exists = pathExists(services_path),
        .services_chat_exists = pathExists(services_chat_path),
        .services_jobs_exists = jobs_exists,
        .global_chat_exists = pathExists(global_chat_path),
        .global_jobs_exists = pathExists(global_jobs_path),
        .meta_exists = pathExists(meta_path),
        .jobs_path = if (jobs_exists) try allocator.dupe(u8, services_jobs_path) else null,
        .job_dir_count = jobs.len,
        .jobs = jobs,
    };
}

fn ensureWorkspaceRoot(path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
}

fn ensureAgentHome(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    agent_id: []const u8,
) !?HomeClaim {
    const service_root = try findHomeServiceRoot(allocator, workspace_root);
    defer if (service_root == null) {} else allocator.free(service_root.?);
    const root = service_root orelse return null;

    const ensure_path = try std.fs.path.join(allocator, &.{ root, "control", "ensure.json" });
    defer allocator.free(ensure_path);
    const result_path = try std.fs.path.join(allocator, &.{ root, "result.json" });
    defer allocator.free(result_path);

    const payload = try std.fmt.allocPrint(allocator, "{{\"agent_id\":\"{s}\"}}", .{agent_id});
    defer allocator.free(payload);
    try writeFileReplacing(ensure_path, payload);

    const result_raw = try std.fs.cwd().readFileAlloc(allocator, result_path, 64 * 1024);
    defer allocator.free(result_raw);
    var claim = try parseHomeClaimResult(allocator, root, agent_id, result_raw);
    errdefer claim.deinit(allocator);

    try ensureRelativeDirectoryForAbsoluteWorkspacePath(allocator, workspace_root, claim.home_path);
    const state_path = try std.fmt.allocPrint(allocator, "{s}/state", .{claim.home_path});
    defer allocator.free(state_path);
    try ensureRelativeDirectoryForAbsoluteWorkspacePath(allocator, workspace_root, state_path);
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/cache", .{claim.home_path});
    defer allocator.free(cache_path);
    try ensureRelativeDirectoryForAbsoluteWorkspacePath(allocator, workspace_root, cache_path);
    const binds_path = try std.fmt.allocPrint(allocator, "{s}/binds", .{claim.home_path});
    defer allocator.free(binds_path);
    try ensureRelativeDirectoryForAbsoluteWorkspacePath(allocator, workspace_root, binds_path);
    return claim;
}

fn ensureWorkerRegistration(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    agent_id: []const u8,
    worker_id: []const u8,
) !?WorkerRegistration {
    const service_root = try findWorkersServiceRoot(allocator, workspace_root);
    defer if (service_root == null) {} else allocator.free(service_root.?);
    const root = service_root orelse return null;

    const register_path = try std.fs.path.join(allocator, &.{ root, "control", "register.json" });
    defer allocator.free(register_path);
    const result_path = try std.fs.path.join(allocator, &.{ root, "result.json" });
    defer allocator.free(result_path);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"agent_id\":\"{s}\",\"worker_id\":\"{s}\",\"venoms\":[\"memory\",\"sub_brains\"]}}",
        .{ agent_id, worker_id },
    );
    defer allocator.free(payload);
    try writeFileReplacing(register_path, payload);

    const result_raw = try std.fs.cwd().readFileAlloc(allocator, result_path, 64 * 1024);
    defer allocator.free(result_raw);
    return try parseWorkerRegistrationResult(allocator, root, agent_id, worker_id, result_raw);
}

fn sendWorkerHeartbeat(allocator: std.mem.Allocator, registration: WorkerRegistration) !void {
    const heartbeat_path = try std.fs.path.join(allocator, &.{ registration.service_root, "control", "heartbeat.json" });
    defer allocator.free(heartbeat_path);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"agent_id\":\"{s}\",\"worker_id\":\"{s}\",\"venoms\":[\"memory\",\"sub_brains\"],\"ttl_ms\":30000}}",
        .{ registration.agent_id, registration.worker_id },
    );
    defer allocator.free(payload);
    try writeFileReplacing(heartbeat_path, payload);
}

fn sendWorkerDetach(allocator: std.mem.Allocator, registration: WorkerRegistration) !void {
    const detach_path = try std.fs.path.join(allocator, &.{ registration.service_root, "control", "detach.json" });
    defer allocator.free(detach_path);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"agent_id\":\"{s}\",\"worker_id\":\"{s}\"}}",
        .{ registration.agent_id, registration.worker_id },
    );
    defer allocator.free(payload);
    try writeFileReplacing(detach_path, payload);
}

fn findHomeServiceRoot(allocator: std.mem.Allocator, workspace_root: []const u8) !?[]u8 {
    const candidates = [_][]const u8{
        "services/home",
        "nodes/local/venoms/home",
        "global/home",
    };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ workspace_root, candidate });
        if (pathExists(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn findWorkersServiceRoot(allocator: std.mem.Allocator, workspace_root: []const u8) !?[]u8 {
    const candidates = [_][]const u8{
        "services/workers",
        "nodes/local/venoms/workers",
        "global/workers",
    };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ workspace_root, candidate });
        if (pathExists(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn parseHomeClaimResult(
    allocator: std.mem.Allocator,
    service_root: []const u8,
    agent_id: []const u8,
    raw: []const u8,
) !HomeClaim {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHomeClaim;
    const root_obj = parsed.value.object;
    const ok_value = root_obj.get("ok") orelse return error.InvalidHomeClaim;
    if (ok_value != .bool or !ok_value.bool) return error.InvalidHomeClaim;

    const result_value = root_obj.get("result") orelse return error.InvalidHomeClaim;
    if (result_value != .object) return error.InvalidHomeClaim;
    const result_obj = result_value.object;
    const result_ok = result_obj.get("ok") orelse return error.InvalidHomeClaim;
    if (result_ok != .bool or !result_ok.bool) return error.InvalidHomeClaim;

    const home_path_value = result_obj.get("home_path") orelse return error.InvalidHomeClaim;
    const target_path_value = result_obj.get("target_path") orelse return error.InvalidHomeClaim;
    if (home_path_value != .string or home_path_value.string.len == 0) return error.InvalidHomeClaim;
    if (target_path_value != .string or target_path_value.string.len == 0) return error.InvalidHomeClaim;

    return .{
        .agent_id = try allocator.dupe(u8, agent_id),
        .service_root = try allocator.dupe(u8, service_root),
        .home_path = try allocator.dupe(u8, home_path_value.string),
        .target_path = try allocator.dupe(u8, target_path_value.string),
    };
}

fn parseWorkerRegistrationResult(
    allocator: std.mem.Allocator,
    service_root: []const u8,
    agent_id: []const u8,
    worker_id: []const u8,
    raw: []const u8,
) !WorkerRegistration {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkerRegistration;
    const root_obj = parsed.value.object;
    const ok_value = root_obj.get("ok") orelse return error.InvalidWorkerRegistration;
    if (ok_value != .bool or !ok_value.bool) return error.InvalidWorkerRegistration;

    const result_value = root_obj.get("result") orelse return error.InvalidWorkerRegistration;
    if (result_value != .object) return error.InvalidWorkerRegistration;
    const result_obj = result_value.object;
    const result_ok = result_obj.get("ok") orelse return error.InvalidWorkerRegistration;
    if (result_ok != .bool or !result_ok.bool) return error.InvalidWorkerRegistration;

    const node_path_value = result_obj.get("node_path") orelse return error.InvalidWorkerRegistration;
    if (node_path_value != .string or node_path_value.string.len == 0) return error.InvalidWorkerRegistration;

    var registration = WorkerRegistration{
        .agent_id = try allocator.dupe(u8, agent_id),
        .worker_id = try allocator.dupe(u8, worker_id),
        .service_root = try allocator.dupe(u8, service_root),
        .node_path = try allocator.dupe(u8, node_path_value.string),
    };
    errdefer registration.deinit(allocator);

    const venoms_value = result_obj.get("venoms") orelse return error.InvalidWorkerRegistration;
    if (venoms_value != .array) return error.InvalidWorkerRegistration;
    for (venoms_value.array.items) |item| {
        if (item != .object) continue;
        const venom_id_value = item.object.get("venom_id") orelse continue;
        const path_value = item.object.get("path") orelse continue;
        if (venom_id_value != .string or path_value != .string or path_value.string.len == 0) continue;
        if (std.mem.eql(u8, venom_id_value.string, "memory")) {
            registration.memory_path = try allocator.dupe(u8, path_value.string);
        } else if (std.mem.eql(u8, venom_id_value.string, "sub_brains")) {
            registration.sub_brains_path = try allocator.dupe(u8, path_value.string);
        }
    }

    return registration;
}

fn ensureRelativeDirectoryForAbsoluteWorkspacePath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    absolute_workspace_path: []const u8,
) !void {
    if (!std.mem.startsWith(u8, absolute_workspace_path, "/")) return error.InvalidWorkspacePath;
    const relative = std.mem.trimLeft(u8, absolute_workspace_path, "/");
    if (relative.len == 0) return error.InvalidWorkspacePath;
    const path = try std.fs.path.join(allocator, &.{ workspace_root, relative });
    defer allocator.free(path);
    try std.fs.cwd().makePath(path);
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn countChildDirectories(path: []const u8) !usize {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) count += 1;
    }
    return count;
}

fn scanJobs(allocator: std.mem.Allocator, jobs_path: []const u8) ![]JobSummary {
    var dir = try std.fs.cwd().openDir(jobs_path, .{ .iterate = true });
    defer dir.close();

    var out = std.ArrayListUnmanaged(JobSummary){};
    errdefer {
        for (out.items) |*job| job.deinit(allocator);
        out.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const job_path = try std.fs.path.join(allocator, &.{ jobs_path, entry.name });
        defer allocator.free(job_path);
        try out.append(allocator, try scanSingleJob(allocator, entry.name, job_path));
    }

    std.mem.sort(JobSummary, out.items, {}, struct {
        fn lessThan(_: void, lhs: JobSummary, rhs: JobSummary) bool {
            return std.mem.lessThan(u8, lhs.job_id, rhs.job_id);
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
}

fn scanSingleJob(allocator: std.mem.Allocator, job_id: []const u8, job_path: []const u8) !JobSummary {
    const status_path = try std.fs.path.join(allocator, &.{ job_path, "status.json" });
    defer allocator.free(status_path);
    const request_path = try std.fs.path.join(allocator, &.{ job_path, "request.json" });
    defer allocator.free(request_path);

    const status_raw = try readOptionalFile(allocator, status_path, 16 * 1024);
    defer if (status_raw) |value| allocator.free(value);
    const request_raw = try readOptionalFile(allocator, request_path, 64 * 1024);
    defer if (request_raw) |value| allocator.free(value);
    const request_text = try parseJobInputText(allocator, request_raw);
    errdefer if (request_text) |value| allocator.free(value);
    const input_preview = if (request_text) |value|
        try previewText(allocator, value)
    else
        try parseJobInputPreview(allocator, request_raw);
    errdefer if (input_preview) |value| allocator.free(value);

    return .{
        .job_id = try allocator.dupe(u8, job_id),
        .job_path = try allocator.dupe(u8, job_path),
        .state = try parseJobState(allocator, status_raw),
        .input_text = request_text,
        .input_preview = input_preview,
    };
}

fn readOptionalFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return @as(?[]u8, content);
}

fn parseJobState(allocator: std.mem.Allocator, raw: ?[]const u8) ![]u8 {
    const content = raw orelse return allocator.dupe(u8, "unknown");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "unknown");
    const state = parsed.value.object.get("state") orelse return allocator.dupe(u8, "unknown");
    if (state != .string or state.string.len == 0) return allocator.dupe(u8, "unknown");
    return allocator.dupe(u8, state.string);
}

fn parseJobInputPreview(allocator: std.mem.Allocator, raw: ?[]const u8) !?[]u8 {
    const content = raw orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return try previewText(allocator, content);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try previewText(allocator, content);
    const input = parsed.value.object.get("input") orelse return try previewText(allocator, content);
    if (input != .string or input.string.len == 0) return null;
    return try previewText(allocator, input.string);
}

fn parseJobInputText(allocator: std.mem.Allocator, raw: ?[]const u8) !?[]u8 {
    const content = raw orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const input = parsed.value.object.get("input") orelse return null;
    if (input != .string or input.string.len == 0) return null;
    const copied = try allocator.dupe(u8, input.string);
    return @as(?[]u8, copied);
}

fn previewText(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const clipped = if (trimmed.len > max_preview_bytes) trimmed[0..max_preview_bytes] else trimmed;
    const copied = try allocator.dupe(u8, clipped);
    return @as(?[]u8, copied);
}

fn processQueuedJobs(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    jobs: []const JobSummary,
    runtime: ?*runtime_worker.RuntimeWorker,
) !usize {
    var processed: usize = 0;
    for (jobs) |job| {
        if (!std.mem.eql(u8, job.state, "queued")) continue;
        const input_text = job.input_text orelse continue;
        try processSingleQueuedJob(allocator, workspace_root, job.job_path, job.job_id, input_text, runtime);
        processed += 1;
    }
    return processed;
}

fn processSingleQueuedJob(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    job_path: []const u8,
    job_id: []const u8,
    input_text: []const u8,
    runtime: ?*runtime_worker.RuntimeWorker,
) !void {
    const status_path = try std.fs.path.join(allocator, &.{ job_path, "status.json" });
    defer allocator.free(status_path);
    const result_path = try std.fs.path.join(allocator, &.{ job_path, "result.txt" });
    defer allocator.free(result_path);
    const log_path = try std.fs.path.join(allocator, &.{ job_path, "log.txt" });
    defer allocator.free(log_path);

    const running_status = try std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"running\",\"correlation_id\":null,\"error\":null,\"updated_at_ms\":{d}}}",
        .{std.time.milliTimestamp()},
    );
    defer allocator.free(running_status);
    try writeFileReplacing(status_path, running_status);

    const started_log = try std.fmt.allocPrint(
        allocator,
        "[spider-monkey] picked up {s}\n",
        .{job_id},
    );
    defer allocator.free(started_log);
    try writeFileReplacing(log_path, started_log);

    const runtime_execution = if (runtime) |active_runtime|
        active_runtime.executePrompt(input_text) catch |err| {
            const failure_log = try std.fmt.allocPrint(
                allocator,
                "[spider-monkey] picked up {s}\n[spider-monkey] runtime failed: {s}\n",
                .{ job_id, @errorName(err) },
            );
            defer allocator.free(failure_log);
            try writeFileReplacing(log_path, failure_log);

            const failed_status = try std.fmt.allocPrint(
                allocator,
                "{{\"state\":\"failed\",\"correlation_id\":null,\"error\":\"{s}\",\"updated_at_ms\":{d}}}",
                .{ @errorName(err), std.time.milliTimestamp() },
            );
            defer allocator.free(failed_status);
            try writeFileReplacing(status_path, failed_status);
            return;
        }
    else
        null;
    defer if (runtime_execution) |*value| value.deinit(allocator);

    const reply = if (runtime_execution) |value|
        try allocator.dupe(u8, value.reply_text)
    else
        try std.fmt.allocPrint(
            allocator,
            "Spider Monkey received: {s}",
            .{input_text},
        );
    defer allocator.free(reply);
    try writeFileReplacing(result_path, reply);

    const completed_log = if (runtime_execution) |value|
        try std.fmt.allocPrint(
            allocator,
            "[spider-monkey] picked up {s}\n{s}[spider-monkey] completed queued job via external workspace worker\n",
            .{ job_id, value.log_text },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "[spider-monkey] picked up {s}\n[spider-monkey] completed queued job via external workspace worker\n",
            .{job_id},
        );
    defer allocator.free(completed_log);
    try writeFileReplacing(log_path, completed_log);

    const reply_targets = [_][]const u8{
        "services/chat/control/reply",
        "global/chat/control/reply",
    };
    for (reply_targets) |target| {
        const reply_path = try std.fs.path.join(allocator, &.{ workspace_root, target });
        defer allocator.free(reply_path);
        writeFileReplacing(reply_path, reply) catch {};
    }

    const done_status = try std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"done\",\"correlation_id\":null,\"error\":null,\"updated_at_ms\":{d}}}",
        .{std.time.milliTimestamp()},
    );
    defer allocator.free(done_status);
    try writeFileReplacing(status_path, done_status);
}

fn writeFileReplacing(path: []const u8, content: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn printStartupSummary(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    agent_id: []const u8,
    worker_id: []const u8,
    once: bool,
    scan_only: bool,
    interval_ms: u64,
    home_claim: ?HomeClaim,
    worker_registration: ?WorkerRegistration,
    runtime_enabled: bool,
    emit_debug: bool,
) !void {
    var out = std.fs.File.stdout();
    try out.writeAll("Spider Monkey\n");

    const root_line = try std.fmt.allocPrint(allocator, "workspace_root: {s}\n", .{workspace_root});
    defer allocator.free(root_line);
    try out.writeAll(root_line);

    const agent_line = try std.fmt.allocPrint(allocator, "agent_id: {s}\n", .{agent_id});
    defer allocator.free(agent_line);
    try out.writeAll(agent_line);

    const worker_line = try std.fmt.allocPrint(allocator, "worker_id: {s}\n", .{worker_id});
    defer allocator.free(worker_line);
    try out.writeAll(worker_line);

    const mode_line = try std.fmt.allocPrint(allocator, "mode: {s}\n", .{if (once) "once" else "loop"});
    defer allocator.free(mode_line);
    try out.writeAll(mode_line);

    const worker_mode_line = try std.fmt.allocPrint(
        allocator,
        "worker_mode: {s}\n",
        .{if (scan_only) "scan-only" else "process-queued"},
    );
    defer allocator.free(worker_mode_line);
    try out.writeAll(worker_mode_line);

    const runtime_line = try std.fmt.allocPrint(
        allocator,
        "runtime: {s}\n",
        .{if (runtime_enabled) "provider-backed" else "disabled"},
    );
    defer allocator.free(runtime_line);
    try out.writeAll(runtime_line);

    if (runtime_enabled) {
        const debug_line = try std.fmt.allocPrint(
            allocator,
            "emit_debug: {s}\n",
            .{if (emit_debug) "true" else "false"},
        );
        defer allocator.free(debug_line);
        try out.writeAll(debug_line);
    }

    if (!once) {
        const interval_line = try std.fmt.allocPrint(allocator, "interval_ms: {d}\n", .{interval_ms});
        defer allocator.free(interval_line);
        try out.writeAll(interval_line);
    }

    if (home_claim) |claim| {
        const home_line = try std.fmt.allocPrint(
            allocator,
            "home: claimed path={s} target={s}\n",
            .{ claim.home_path, claim.target_path },
        );
        defer allocator.free(home_line);
        try out.writeAll(home_line);
    } else {
        try out.writeAll("home: unavailable\n");
    }

    if (worker_registration) |registration| {
        const node_line = try std.fmt.allocPrint(
            allocator,
            "worker_node: path={s}\n",
            .{registration.node_path},
        );
        defer allocator.free(node_line);
        try out.writeAll(node_line);
        if (registration.memory_path) |memory_path| {
            const memory_line = try std.fmt.allocPrint(allocator, "worker_memory: {s}\n", .{memory_path});
            defer allocator.free(memory_line);
            try out.writeAll(memory_line);
        }
        if (registration.sub_brains_path) |sub_brains_path| {
            const sub_brains_line = try std.fmt.allocPrint(allocator, "worker_sub_brains: {s}\n", .{sub_brains_path});
            defer allocator.free(sub_brains_line);
            try out.writeAll(sub_brains_line);
        }
    } else {
        try out.writeAll("worker_node: unavailable\n");
    }

    try out.writeAll(if (scan_only)
        "behavior: read-only workspace scan\n\n"
    else
        "behavior: processes queued jobs through the mounted workspace\n\n");
}

fn printScanReport(allocator: std.mem.Allocator, report: *const ScanReport) !void {
    var out = std.fs.File.stdout();

    const root_line = try std.fmt.allocPrint(allocator, "scan root={s}\n", .{report.workspace_root});
    defer allocator.free(root_line);
    try out.writeAll(root_line);

    const services_line = try std.fmt.allocPrint(allocator, "  services: {s}\n", .{boolLabel(report.services_exists)});
    defer allocator.free(services_line);
    try out.writeAll(services_line);

    const services_chat_line = try std.fmt.allocPrint(allocator, "  services/chat: {s}\n", .{boolLabel(report.services_chat_exists)});
    defer allocator.free(services_chat_line);
    try out.writeAll(services_chat_line);

    const services_jobs_line = try std.fmt.allocPrint(allocator, "  services/jobs: {s}\n", .{boolLabel(report.services_jobs_exists)});
    defer allocator.free(services_jobs_line);
    try out.writeAll(services_jobs_line);

    const global_chat_line = try std.fmt.allocPrint(allocator, "  global/chat: {s}\n", .{boolLabel(report.global_chat_exists)});
    defer allocator.free(global_chat_line);
    try out.writeAll(global_chat_line);

    const global_jobs_line = try std.fmt.allocPrint(allocator, "  global/jobs: {s}\n", .{boolLabel(report.global_jobs_exists)});
    defer allocator.free(global_jobs_line);
    try out.writeAll(global_jobs_line);

    const meta_line = try std.fmt.allocPrint(allocator, "  meta: {s}\n", .{boolLabel(report.meta_exists)});
    defer allocator.free(meta_line);
    try out.writeAll(meta_line);

    if (report.jobs_path) |jobs_path| {
        const jobs_path_line = try std.fmt.allocPrint(allocator, "  jobs_path: {s}\n", .{jobs_path});
        defer allocator.free(jobs_path_line);
        try out.writeAll(jobs_path_line);

        const jobs_count_line = try std.fmt.allocPrint(allocator, "  jobs_directories: {d}\n", .{report.job_dir_count});
        defer allocator.free(jobs_count_line);
        try out.writeAll(jobs_count_line);

        for (report.jobs) |job| {
            const preview = job.input_preview orelse "";
            const job_line = if (preview.len > 0)
                try std.fmt.allocPrint(
                    allocator,
                    "  job {s}: state={s} input=\"{s}\"\n",
                    .{ job.job_id, job.state, preview },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "  job {s}: state={s}\n",
                    .{ job.job_id, job.state },
                );
            defer allocator.free(job_line);
            try out.writeAll(job_line);
        }
    }
    try out.writeAll("\n");
}

fn boolLabel(value: bool) []const u8 {
    return if (value) "present" else "missing";
}

fn printHelp() !void {
    const help =
        \\spider-monkey - Spiderweb workspace worker
        \\
        \\Usage:
        \\  spider-monkey run --workspace-root <mounted-path> [--agent-id <id>] [--worker-id <id>] [--config <path>] [--provider <name>] [--model <name>] [--api-key <key>] [--base-url <url>] [--emit-debug] [--once] [--scan-only] [--interval-ms <ms>]
        \\
        \\Examples:
        \\  spider-monkey run --workspace-root /mnt/spiderweb-demo --agent-id spider-monkey --worker-id spider-monkey-a --provider openai --model gpt-4o-mini --once
        \\  spider-monkey run --workspace-root /mnt/spiderweb-demo --once --scan-only
        \\  spider-monkey run --workspace-root /mnt/spiderweb-demo --interval-ms 5000
        \\
    ;
    try std.fs.File.stdout().writeAll(help);
}

test "boolLabel returns stable strings" {
    try std.testing.expectEqualStrings("present", boolLabel(true));
    try std.testing.expectEqualStrings("missing", boolLabel(false));
}

test "previewText trims and clips input" {
    const allocator = std.testing.allocator;
    const preview = try previewText(allocator, "   hello spider monkey   ");
    defer if (preview) |value| allocator.free(value);
    try std.testing.expectEqualStrings("hello spider monkey", preview.?);
}

test "parseJobInputText reads input from request payload" {
    const allocator = std.testing.allocator;
    const input = try parseJobInputText(allocator, "{\"job_id\":\"job-1\",\"input\":\"hello web\"}");
    defer if (input) |value| allocator.free(value);
    try std.testing.expectEqualStrings("hello web", input.?);
}

test "processQueuedJobs completes queued workspace job" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const services_jobs_dir = try std.fmt.allocPrint(allocator, "{s}/services/jobs/job-1", .{root});
    defer allocator.free(services_jobs_dir);
    try std.fs.cwd().makePath(services_jobs_dir);

    const services_chat_dir = try std.fmt.allocPrint(allocator, "{s}/services/chat/control", .{root});
    defer allocator.free(services_chat_dir);
    try std.fs.cwd().makePath(services_chat_dir);

    const global_chat_dir = try std.fmt.allocPrint(allocator, "{s}/global/chat/control", .{root});
    defer allocator.free(global_chat_dir);
    try std.fs.cwd().makePath(global_chat_dir);

    const request_path = try std.fmt.allocPrint(allocator, "{s}/request.json", .{services_jobs_dir});
    defer allocator.free(request_path);
    try writeFileReplacing(request_path, "{\"job_id\":\"job-1\",\"input\":\"hello from test\"}");

    const status_path = try std.fmt.allocPrint(allocator, "{s}/status.json", .{services_jobs_dir});
    defer allocator.free(status_path);
    try writeFileReplacing(status_path, "{\"state\":\"queued\",\"error\":null}");

    const result_path = try std.fmt.allocPrint(allocator, "{s}/result.txt", .{services_jobs_dir});
    defer allocator.free(result_path);
    try writeFileReplacing(result_path, "");

    const log_path = try std.fmt.allocPrint(allocator, "{s}/log.txt", .{services_jobs_dir});
    defer allocator.free(log_path);
    try writeFileReplacing(log_path, "");

    var report = try scanWorkspace(allocator, root);
    defer report.deinit(allocator);
    const processed = try processQueuedJobs(allocator, root, report.jobs, null);
    try std.testing.expectEqual(@as(usize, 1), processed);

    const status_after = try std.fs.cwd().readFileAlloc(allocator, status_path, 4 * 1024);
    defer allocator.free(status_after);
    try std.testing.expect(std.mem.indexOf(u8, status_after, "\"state\":\"done\"") != null);

    const result_after = try std.fs.cwd().readFileAlloc(allocator, result_path, 4 * 1024);
    defer allocator.free(result_after);
    try std.testing.expectEqualStrings("Spider Monkey received: hello from test", result_after);
}

test "ensureAgentHome claims and bootstraps agent home directories" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const home_control_dir = try std.fmt.allocPrint(allocator, "{s}/services/home/control", .{root});
    defer allocator.free(home_control_dir);
    try std.fs.cwd().makePath(home_control_dir);

    const home_result_path = try std.fmt.allocPrint(allocator, "{s}/services/home/result.json", .{root});
    defer allocator.free(home_result_path);
    try writeFileReplacing(
        home_result_path,
        "{\"ok\":true,\"operation\":\"ensure\",\"result\":{\"ok\":true,\"agent_id\":\"spider-monkey\",\"project_id\":\"proj-1\",\"home_path\":\"/agents/spider-monkey/home\",\"target_path\":\"/nodes/local/fs/.spiderweb/agents/spider-monkey/home\"}}",
    );

    var claim = (try ensureAgentHome(allocator, root, "spider-monkey")).?;
    defer claim.deinit(allocator);

    try std.testing.expectEqualStrings("/agents/spider-monkey/home", claim.home_path);
    const home_dir = try std.fmt.allocPrint(allocator, "{s}/agents/spider-monkey/home", .{root});
    defer allocator.free(home_dir);
    try std.testing.expect(pathExists(home_dir));
    const state_dir = try std.fmt.allocPrint(allocator, "{s}/agents/spider-monkey/home/state", .{root});
    defer allocator.free(state_dir);
    try std.testing.expect(pathExists(state_dir));
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/agents/spider-monkey/home/cache", .{root});
    defer allocator.free(cache_dir);
    try std.testing.expect(pathExists(cache_dir));
    const binds_dir = try std.fmt.allocPrint(allocator, "{s}/agents/spider-monkey/home/binds", .{root});
    defer allocator.free(binds_dir);
    try std.testing.expect(pathExists(binds_dir));
}

test "ensureWorkerRegistration claims worker node paths" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const workers_control_dir = try std.fmt.allocPrint(allocator, "{s}/services/workers/control", .{root});
    defer allocator.free(workers_control_dir);
    try std.fs.cwd().makePath(workers_control_dir);

    const workers_result_path = try std.fmt.allocPrint(allocator, "{s}/services/workers/result.json", .{root});
    defer allocator.free(workers_result_path);
    try writeFileReplacing(
        workers_result_path,
        "{\"ok\":true,\"operation\":\"register\",\"result\":{\"ok\":true,\"worker_id\":\"spider-monkey-a\",\"agent_id\":\"spider-monkey\",\"node_id\":\"spider-monkey-a\",\"node_path\":\"/nodes/spider-monkey-a\",\"venoms\":[{\"venom_id\":\"memory\",\"path\":\"/nodes/spider-monkey-a/venoms/memory\"},{\"venom_id\":\"sub_brains\",\"path\":\"/nodes/spider-monkey-a/venoms/sub_brains\"}]}}",
    );

    var registration = (try ensureWorkerRegistration(allocator, root, "spider-monkey", "spider-monkey-a")).?;
    defer registration.deinit(allocator);

    try std.testing.expectEqualStrings("/nodes/spider-monkey-a", registration.node_path);
    try std.testing.expectEqualStrings("/nodes/spider-monkey-a/venoms/memory", registration.memory_path.?);
    try std.testing.expectEqualStrings("/nodes/spider-monkey-a/venoms/sub_brains", registration.sub_brains_path.?);
}
