const std = @import("std");
const profiles = @import("../auth/profiles.zig");
const external_auth = @import("../auth/external.zig");
const paths = @import("../storage/paths.zig");
const library = @import("../api/library.zig");
const api_sync = @import("../api/sync.zig");
const api_download = @import("../api/download.zig");
const api_account = @import("../api/account.zig");
const downloads = @import("../downloads/manager.zig");
const download_jobs = @import("../downloads/jobs.zig");
const session = @import("../auth/session.zig");
const mpv = @import("../player/mpv.zig");
const now_playing = @import("../player/now_playing.zig");
const database_mod = @import("../storage/database.zig");
const yoto = @import("../yoto/provider.zig");

pub const version: u32 = 1;

pub const Runtime = struct {
    const DownloadRecord = struct {
        jobId: []const u8,
        itemId: []const u8,
        title: []const u8,
        state: []const u8,
        received: u64,
        total: ?u64,
        path: []const u8,
    };
    const BookmarkRecord = struct { id: i64, positionSeconds: f64, label: ?[]const u8 };

    database: ?*database_mod.Database = null,
    player: ?std.process.Child = null,
    item_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    local_path: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
    paused: bool = true,
    position_seconds: f64 = 0,
    duration_seconds: f64 = 0,
    chapter: i64 = 0,
    speed: f64 = 1,
    volume: f64 = 100,
    ended: bool = false,
    profile_name: ?[]const u8 = null,
    provider_id: []const u8 = "audible",
    last_saved_position: f64 = 0,
    last_saved_duration: f64 = 0,
    bookmarks: []const BookmarkRecord = &.{},
    chapters: []const mpv.Chapter = &.{},
    chapters_allocator: ?std.mem.Allocator = null,
    chapters_loaded: bool = false,
    sleep_deadline: ?i64 = null,
    sleep_chapter: ?i64 = null,
    download_mirror_fingerprint: ?u64 = null,
    download_job: ?DownloadRecord = null,
    pending_login: ?external_auth.PendingLogin = null,

    pub fn deinit(self: *Runtime, io: std.Io) void {
        if (self.socket_path) |socket_path| {
            if (mpv.queryState(std.heap.page_allocator, io, socket_path, .{
                .path = self.local_path,
                .time_pos = self.position_seconds,
                .duration = self.duration_seconds,
                .paused = self.paused,
                .chapter = self.chapter,
                .speed = self.speed,
                .volume = self.volume,
                .ended = self.ended,
            })) |state| {
                self.position_seconds = state.time_pos;
                self.duration_seconds = state.duration;
                self.ended = state.ended;
            } else |_| {}
        }
        persistPlayback(self) catch {};
        if (self.player) |*child| child.kill(io);
        if (self.socket_path) |socket_path| {
            std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
            if (std.fs.path.dirname(socket_path)) |state_dir| now_playing.clear(io, state_dir);
        }
        self.player = null;
        self.socket_path = null;
        self.sleep_deadline = null;
        self.sleep_chapter = null;
        if (self.chapters_allocator) |allocator| mpv.deinitChapters(allocator, self.chapters);
        self.chapters = &.{};
        self.chapters_allocator = null;
        self.chapters_loaded = false;
        if (self.pending_login) |*pending| std.crypto.secureZero(u8, &pending.verifier);
        self.pending_login = null;
    }
};

fn persistPlayback(runtime: *Runtime) !void {
    const database = runtime.database orelse return;
    const profile = runtime.profile_name orelse return;
    const item_id = runtime.item_id orelse return;
    const title = runtime.title orelse return;
    const position = if (runtime.ended) 0 else mpv.resumePosition(runtime.position_seconds, runtime.duration_seconds);
    try database.putProviderPlaybackPosition(.{ .provider_id = runtime.provider_id, .account_id = profile }, item_id, title, position, runtime.duration_seconds);
    runtime.last_saved_position = position;
    runtime.last_saved_duration = runtime.duration_seconds;
}

fn loadBookmarks(allocator: std.mem.Allocator, runtime: *Runtime) !void {
    const database = runtime.database orelse return;
    const profile = runtime.profile_name orelse return;
    const item_id = runtime.item_id orelse return;
    const stored = try database.listProviderBookmarks(allocator, .{ .provider_id = runtime.provider_id, .account_id = profile }, item_id);
    const result = try allocator.alloc(Runtime.BookmarkRecord, stored.len);
    for (stored, 0..) |bookmark, index| result[index] = .{
        .id = bookmark.id,
        .positionSeconds = bookmark.position_seconds,
        .label = bookmark.label,
    };
    runtime.bookmarks = result;
}

fn remoteDownload(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, runtime: *Runtime, writer: *std.Io.Writer, id: []const u8, params: std.json.ObjectMap) !void {
    const asin = stringParam(params, "asin") orelse stringParam(params, "itemId") orelse return failure(writer, id, "INVALID_REQUEST", "asin is required");
    const profile_name = stringParam(params, "profile") orelse "default";
    const xdg = paths.resolve(allocator, environ) catch return failure(writer, id, "INTERNAL", "application paths could not be resolved");
    defer xdg.deinit(allocator);
    const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
    defer allocator.free(cache_path);
    var cache = library.loadCache(allocator, io, cache_path) catch return failure(writer, id, "INVALID_REQUEST", "refresh the owned library before downloading");
    defer cache.deinit();
    var selected_index: ?usize = null;
    for (cache.value.items, 0..) |item, index| if (std.mem.eql(u8, item.asin, asin)) {
        selected_index = index;
        break;
    };
    const index = selected_index orelse return failure(writer, id, "INVALID_REQUEST", "the requested ASIN is not in the owned-library cache");
    const item = &cache.value.items[index];
    if (item.downloaded and item.localPath != null) {
        if (std.Io.Dir.cwd().statFile(io, item.localPath.?, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .file) {
                runtime.download_job = .{ .jobId = try allocator.dupe(u8, asin), .itemId = try allocator.dupe(u8, asin), .title = try allocator.dupe(u8, item.title), .state = "completed", .received = stat.size, .total = stat.size, .path = try allocator.dupe(u8, item.localPath.?) };
                return success(writer, id, .{ .jobId = asin, .itemId = asin, .state = "completed", .received = stat.size, .total = stat.size, .path = item.localPath.? });
            }
        } else |_| {}
    }
    const license = api_download.requestForProfile(allocator, io, environ, profile_name, asin) catch |err| switch (err) {
        error.ProfileNotFound, error.ProfilePasswordRequired, error.Unauthorized => return failure(writer, id, "REAUTH_REQUIRED", "the selected profile must be unlocked or authenticated again"),
        error.LicenseDenied => return failure(writer, id, "LICENSE_DENIED", "Audible did not grant an offline license for this title"),
        error.RateLimited => return failure(writer, id, "RATE_LIMITED", "Audible temporarily rate-limited the license request"),
        else => return failure(writer, id, "DOWNLOAD_FAILED", "Audible did not provide a usable media license"),
    };
    defer license.deinit();
    const output_dir = stringParam(params, "outputDir") orelse blk: {
        const value = try std.fs.path.join(allocator, &.{ xdg.data, "downloads" });
        break :blk value;
    };
    defer if (params.get("outputDir") == null) allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    const safe_title = try downloads.sanitizeFilename(allocator, item.title);
    defer allocator.free(safe_title);
    const filename = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ safe_title, license.content_format, license.extension() });
    defer allocator.free(filename);
    const destination = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(destination);
    const stem = destination[0 .. destination.len - license.extension().len];
    const voucher_path = try std.fmt.allocPrint(allocator, "{s}.voucher", .{stem});
    defer allocator.free(voucher_path);
    // A granted request may consume a voucher. Preserve it privately before
    // starting the potentially long media transfer.
    session.atomicWriteCredentials(allocator, io, voucher_path, license.response) catch return failure(writer, id, "DOWNLOAD_FAILED", "could not privately save the Audible voucher");
    const result = downloads.downloadUrl(allocator, io, license.media_url, destination) catch |err| switch (err) {
        error.AlreadyExists => return failure(writer, id, "ALREADY_EXISTS", "this title is already downloaded"),
        else => return failure(writer, id, "DOWNLOAD_FAILED", "media transfer failed; its partial file was retained for resume"),
    };
    item.localPath = destination;
    item.downloaded = true;
    try api_sync.writeCache(allocator, io, cache_path, cache.value.items);
    try event(writer, "download.progress", .{ .jobId = asin, .received = result.received, .total = result.received });
    try event(writer, "download.state", .{ .jobId = asin, .state = "completed", .path = destination });
    runtime.download_job = .{ .jobId = try allocator.dupe(u8, asin), .itemId = try allocator.dupe(u8, asin), .title = try allocator.dupe(u8, item.title), .state = "completed", .received = result.received, .total = result.received, .path = try allocator.dupe(u8, destination) };
    return success(writer, id, .{ .jobId = asin, .itemId = asin, .state = "completed", .received = result.received, .total = result.received, .path = destination });
}

fn sendMpv(io: std.Io, socket_path: []const u8, command: mpv.Command) !void {
    return mpv.send(io, socket_path, command);
}

fn waitForSocket(io: std.Io, socket_path: []const u8) !void {
    var attempt: u8 = 0;
    while (attempt < 80) : (attempt += 1) {
        if (std.Io.Dir.cwd().statFile(io, socket_path, .{})) |_| return else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    }
    return error.MpvSocketTimeout;
}

fn speedSettingKey(allocator: std.mem.Allocator, provider_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "player.speed.{s}", .{provider_id});
}

fn voucherPathForMedia(allocator: std.mem.Allocator, local_path: []const u8) ![]u8 {
    const extension = std.fs.path.extension(local_path);
    const stem = local_path[0 .. local_path.len - extension.len];
    return std.fmt.allocPrint(allocator, "{s}.voucher", .{stem});
}

fn knownKey(key: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn objectHasOnly(object: std.json.ObjectMap, allowed: []const []const u8) bool {
    var it = object.iterator();
    while (it.next()) |entry| if (!knownKey(entry.key_ptr.*, allowed)) return false;
    return true;
}

fn failure(writer: *std.Io.Writer, id: []const u8, code: []const u8, message: []const u8) !void {
    try std.json.Stringify.value(.{
        .v = version,
        .id = id,
        .ok = false,
        .@"error" = .{ .code = code, .message = message },
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn success(writer: *std.Io.Writer, id: []const u8, result: anytype) !void {
    try std.json.Stringify.value(.{ .v = version, .id = id, .ok = true, .result = result }, .{}, writer);
    try writer.writeByte('\n');
}

fn event(writer: *std.Io.Writer, name: []const u8, data: anytype) !void {
    try std.json.Stringify.value(.{ .v = version, .event = name, .data = data }, .{}, writer);
    try writer.writeByte('\n');
}

fn jobsDirectory(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const xdg = try paths.resolve(allocator, environ);
    defer xdg.deinit(allocator);
    return std.fs.path.join(allocator, &.{ xdg.state, "download-jobs" });
}

fn sqliteJobState(state: download_jobs.State) []const u8 {
    return switch (state) {
        .queued => "queued",
        .active => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

fn mirrorArtifact(database: *database_mod.Database, io: std.Io, profile: []const u8, asin: []const u8, title: []const u8, path: ?[]const u8, kind: []const u8) !void {
    const present = path orelse return;
    const stat = std.Io.Dir.cwd().statFile(io, present, .{ .follow_symlinks = false }) catch return;
    if (stat.kind == .file) try database.putLocalFile(profile, asin, title, kind, present, stat.size, null);
}

fn mirrorDownload(database: *database_mod.Database, io: std.Io, record: download_jobs.Record) !void {
    const asin = if (record.asin.len != 0) record.asin else record.itemId;
    const destination = record.path orelse record.destination orelse record.outputDir;
    try database.putDownloadJob(.{
        .id = record.jobId,
        .profile = if (record.profile.len != 0) record.profile else "default",
        .asin = asin,
        .title = record.title,
        .kind = @tagName(record.kind),
        .destination = destination,
        .status = sqliteJobState(record.state),
        .bytes_downloaded = record.received,
        .total_bytes = record.total,
        .error_message = record.@"error",
        .created_at = record.createdAt,
        .updated_at = record.updatedAt,
    });
    if (record.state != .completed) return;
    const profile = if (record.profile.len != 0) record.profile else "default";
    try mirrorArtifact(database, io, profile, asin, record.title, record.path, "audio");
    try mirrorArtifact(database, io, profile, asin, record.title, record.coverPath, "cover");
    try mirrorArtifact(database, io, profile, asin, record.title, record.pdfPath, "pdf");
    try mirrorArtifact(database, io, profile, asin, record.title, record.metadataPath, "metadata");
    try mirrorArtifact(database, io, profile, asin, record.title, record.chaptersPath, "chapters");
    try mirrorArtifact(database, io, profile, asin, record.title, record.annotationsPath, "annotations");
}

fn downloadFingerprint(records: []download_jobs.Loaded) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (records) |*loaded| {
        const record = loaded.value();
        hasher.update(record.jobId);
        hasher.update(@tagName(record.state));
        hasher.update(std.mem.asBytes(&record.received));
        hasher.update(std.mem.asBytes(&record.updatedAt));
        if (record.total) |total| hasher.update(std.mem.asBytes(&total));
        if (record.path) |path| hasher.update(path);
    }
    return hasher.final();
}

fn spawnDownloadWorker(allocator: std.mem.Allocator, io: std.Io, job_id: []const u8) !?i64 {
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const child = try std.process.spawn(io, .{
        .argv = &.{ executable, "internal", "download-worker", job_id },
        .stdin = .ignore,
        // Detached workers must not inherit the RPC pipe: an inherited writer
        // keeps client reads open and makes graceful shutdown wait for a long
        // transfer. Job files are the authoritative progress channel.
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    });
    return if (@import("builtin").os.tag == .windows) null else @intCast(child.id.?);
}

fn workerAlive(allocator: std.mem.Allocator, io: std.Io, pid: ?i64, job_id: []const u8) bool {
    _ = job_id;
    if (@import("builtin").os.tag != .linux) return false;
    const value = pid orelse return false;
    const proc = std.fmt.allocPrint(allocator, "/proc/{d}", .{value}) catch return false;
    defer allocator.free(proc);
    const file = std.Io.Dir.cwd().openFile(io, proc, .{ .allow_directory = true }) catch return false;
    file.close(io);
    return true;
}

fn countsAsActive(now: i64, updated_at: i64, pid: ?i64, process_alive: bool) bool {
    return process_alive or (pid == null and now >= updated_at and now - updated_at < 10);
}

fn dispatchDownloads(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    const directory = try jobsDirectory(allocator, environ);
    defer allocator.free(directory);
    try download_jobs.ensure(io, directory);
    const lock_path = try std.fs.path.join(allocator, &.{ directory, ".queue.lock" });
    defer allocator.free(lock_path);
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    const persistent = try download_jobs.list(allocator, io, directory);
    defer download_jobs.deinitList(allocator, persistent);
    const now = std.Io.Clock.real.now(io).toSeconds();
    var active: usize = 0;
    for (persistent) |*loaded| {
        const job = loaded.value();
        if (job.state != .active) continue;
        // Give a newly spawned worker time to claim the record and publish its
        // PID. Without this window a second dispatcher can launch a duplicate.
        if (countsAsActive(now, job.updatedAt, job.pid, workerAlive(allocator, io, job.pid, job.jobId))) active += 1 else {
            job.state = .queued;
            job.pid = null;
            try download_jobs.save(allocator, io, directory, job.*);
        }
    }
    for (persistent) |*loaded| {
        if (active >= download_jobs.max_concurrent) break;
        const job = loaded.value();
        if (job.state != .queued) continue;
        job.state = .active;
        job.updatedAt = now;
        try download_jobs.save(allocator, io, directory, job.*);
        _ = spawnDownloadWorker(allocator, io, job.jobId) catch |err| {
            job.state = .queued;
            job.updatedAt = std.Io.Clock.real.now(io).toSeconds();
            try download_jobs.save(allocator, io, directory, job.*);
            return err;
        };
        active += 1;
    }
}

pub fn recoverDownloads(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    try dispatchDownloads(allocator, io, environ);
}

const WorkerObserver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    record: *download_jobs.Record,

    fn update(raw: ?*anyopaque, received: u64, total: ?u64) !void {
        const self: *WorkerObserver = @ptrCast(@alignCast(raw.?));
        if (download_jobs.isCancelled(self.allocator, self.io, self.directory, self.record.jobId)) return error.Cancelled;
        self.record.received = received;
        if (total) |value| self.record.total = value;
        self.record.updatedAt = std.Io.Clock.real.now(self.io).toSeconds();
        try download_jobs.save(self.allocator, self.io, self.directory, self.record.*);
    }
};

fn failDownloadWorker(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, job: *download_jobs.Record, err: anyerror) !void {
    job.state = if (err == error.Cancelled) .cancelled else .failed;
    job.@"error" = if (err == error.Cancelled) null else "transfer failed; retry will resume the retained partial file";
    job.updatedAt = std.Io.Clock.real.now(io).toSeconds();
    try download_jobs.save(allocator, io, directory, job.*);
}

fn fetchOptionalArtifact(allocator: std.mem.Allocator, io: std.Io, url: ?[]const u8, destination: []const u8) !bool {
    const source = url orelse return false;
    if (!std.mem.startsWith(u8, source, "https://")) return false;
    if (std.Io.Dir.cwd().statFile(io, destination, .{})) |stat| return stat.kind == .file and stat.size > 0 else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    _ = downloads.downloadUrl(allocator, io, source, destination) catch return false;
    return true;
}

/// Entry point for the detached download process. Job files contain only
/// non-secret inputs; signed media URLs and vouchers remain worker-local.
fn runDownloadWorkerImpl(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, job_id: []const u8) !void {
    _ = writer;
    const directory = try jobsDirectory(allocator, environ);
    defer allocator.free(directory);
    var loaded = try download_jobs.load(allocator, io, directory, job_id);
    defer loaded.deinit();
    const job = loaded.value();
    if (job.state == .cancelled or job.state == .completed) return;
    job.state = .active;
    job.pid = if (@import("builtin").os.tag == .linux) @intCast(std.os.linux.getpid()) else null;
    job.attempts += 1;
    job.updatedAt = std.Io.Clock.real.now(io).toSeconds();
    try download_jobs.save(allocator, io, directory, job.*);
    var observer_context = WorkerObserver{ .allocator = allocator, .io = io, .directory = directory, .record = job };
    const observer: downloads.Observer = .{ .context = &observer_context, .update = WorkerObserver.update };

    const result = if (job.kind == .local) blk: {
        const source = job.source orelse return error.InvalidJob;
        const destination = job.destination orelse return error.InvalidJob;
        break :blk downloads.copyLocalObserved(allocator, io, source, destination, observer) catch |err| {
            try failDownloadWorker(allocator, io, directory, job, err);
            try dispatchDownloads(allocator, io, environ);
            return;
        };
    } else blk: {
        const xdg = try paths.resolve(allocator, environ);
        defer xdg.deinit(allocator);
        const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
        defer allocator.free(cache_path);
        var cache = try library.loadCache(allocator, io, cache_path);
        defer cache.deinit();
        var selected_index: ?usize = null;
        for (cache.value.items, 0..) |item, index| if (std.mem.eql(u8, item.asin, job.asin)) {
            selected_index = index;
            break;
        };
        const index = selected_index orelse return error.ItemNotOwned;
        const item = &cache.value.items[index];
        const license = try api_download.requestForProfile(allocator, io, environ, job.profile, job.asin);
        defer license.deinit();
        const safe_title = try downloads.sanitizeFilename(allocator, item.title);
        defer allocator.free(safe_title);
        const filename_value = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ safe_title, license.content_format, license.extension() });
        defer allocator.free(filename_value);
        const destination = try std.fs.path.join(allocator, &.{ job.outputDir, filename_value });
        const stem = destination[0 .. destination.len - license.extension().len];
        const voucher_path = try std.fmt.allocPrint(allocator, "{s}.voucher", .{stem});
        defer allocator.free(voucher_path);
        try session.atomicWriteCredentials(allocator, io, voucher_path, license.response);
        const transferred = downloads.downloadUrlObserved(allocator, io, license.media_url, destination, observer) catch |err| {
            try failDownloadWorker(allocator, io, directory, job, err);
            try dispatchDownloads(allocator, io, environ);
            return;
        };
        const cover_path = try std.fmt.allocPrint(allocator, "{s}.cover.jpg", .{stem});
        if (try fetchOptionalArtifact(allocator, io, item.coverUrl, cover_path)) job.coverPath = cover_path else allocator.free(cover_path);
        const pdf_path = try std.fmt.allocPrint(allocator, "{s}.pdf", .{stem});
        if (try fetchOptionalArtifact(allocator, io, license.pdf_url, pdf_path)) job.pdfPath = pdf_path else allocator.free(pdf_path);
        if (download_jobs.isCancelled(allocator, io, directory, job.jobId)) {
            try failDownloadWorker(allocator, io, directory, job, error.Cancelled);
            try dispatchDownloads(allocator, io, environ);
            return;
        }
        const artifacts = api_download.artifactsForProfile(allocator, io, environ, job.profile, job.asin) catch null;
        if (artifacts) |documents| {
            defer documents.deinit();
            if (documents.chapters) |contents| {
                const chapters_path = try std.fmt.allocPrint(allocator, "{s}-chapters.json", .{stem});
                try session.atomicWriteCredentials(allocator, io, chapters_path, contents);
                job.chaptersPath = chapters_path;
            }
            if (documents.annotations) |contents| {
                const annotations_path = try std.fmt.allocPrint(allocator, "{s}-annotations.json", .{stem});
                try session.atomicWriteCredentials(allocator, io, annotations_path, contents);
                job.annotationsPath = annotations_path;
            }
        }
        const metadata_path = try std.fmt.allocPrint(allocator, "{s}.metadata.json", .{stem});
        var metadata: std.Io.Writer.Allocating = .init(allocator);
        defer metadata.deinit();
        try std.json.Stringify.value(.{
            .asin = item.asin,
            .title = item.title,
            .authors = item.authors,
            .narrators = item.narrators,
            .durationSeconds = item.durationSeconds,
            .releaseDate = item.releaseDate,
            .mediaPath = destination,
            .coverPath = job.coverPath,
            .pdfPath = job.pdfPath,
            .chaptersPath = job.chaptersPath,
            .annotationsPath = job.annotationsPath,
        }, .{}, &metadata.writer);
        try session.atomicWriteCredentials(allocator, io, metadata_path, metadata.written());
        job.metadataPath = metadata_path;
        item.localPath = destination;
        item.downloaded = true;
        try api_sync.writeCache(allocator, io, cache_path, cache.value.items);
        job.destination = destination;
        break :blk transferred;
    };
    if (download_jobs.isCancelled(allocator, io, directory, job.jobId)) {
        try failDownloadWorker(allocator, io, directory, job, error.Cancelled);
        try dispatchDownloads(allocator, io, environ);
        return;
    }
    job.received = result.received;
    job.total = result.received;
    job.path = job.destination;
    job.state = .completed;
    job.@"error" = null;
    job.updatedAt = std.Io.Clock.real.now(io).toSeconds();
    try download_jobs.save(allocator, io, directory, job.*);
    try dispatchDownloads(allocator, io, environ);
}

/// Worker failures are converted into durable terminal state. Detached
/// children intentionally produce no protocol output, so a later poll can
/// always explain a failure instead of leaving an immortal `active` record.
pub fn runDownloadWorker(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, writer: *std.Io.Writer, job_id: []const u8) !void {
    runDownloadWorkerImpl(allocator, io, environ, writer, job_id) catch |err| {
        const directory = jobsDirectory(allocator, environ) catch return;
        defer allocator.free(directory);
        var loaded = download_jobs.load(allocator, io, directory, job_id) catch return;
        defer loaded.deinit();
        const job = loaded.value();
        if (job.state != .completed and job.state != .cancelled) failDownloadWorker(allocator, io, directory, job, err) catch {};
        dispatchDownloads(allocator, io, environ) catch {};
    };
}

fn playerSuccess(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, id: []const u8, runtime: *Runtime) !void {
    if (runtime.socket_path) |socket_path| {
        const current = mpv.queryState(allocator, io, socket_path, .{
            .path = runtime.local_path,
            .time_pos = runtime.position_seconds,
            .duration = runtime.duration_seconds,
            .paused = runtime.paused,
            .chapter = runtime.chapter,
            .speed = runtime.speed,
            .volume = runtime.volume,
            .ended = runtime.ended,
        }) catch null;
        if (current) |state| {
            runtime.position_seconds = state.time_pos;
            runtime.duration_seconds = state.duration;
            runtime.paused = state.paused;
            runtime.chapter = state.chapter;
            runtime.speed = state.speed;
            runtime.volume = state.volume;
            runtime.ended = state.ended;
        }
    }
    const now = std.Io.Clock.real.now(io).toSeconds();
    const sleep_expired = if (runtime.sleep_deadline) |deadline| now >= deadline else false;
    const chapter_finished = if (runtime.sleep_chapter) |chapter| runtime.chapter != chapter else false;
    if ((sleep_expired or chapter_finished) and runtime.socket_path != null) {
        sendMpv(io, runtime.socket_path.?, .{ .pause = true }) catch {};
        runtime.paused = true;
        runtime.sleep_deadline = null;
        runtime.sleep_chapter = null;
    }
    if (runtime.item_id != null and ((runtime.ended and
        (runtime.last_saved_position != 0 or runtime.last_saved_duration != runtime.duration_seconds)) or
        @abs(runtime.position_seconds - runtime.last_saved_position) >= 5 or
        (runtime.duration_seconds > 0 and runtime.last_saved_duration == 0)))
    {
        persistPlayback(runtime) catch {};
    }
    const sleep_remaining: ?i64 = if (runtime.sleep_deadline) |deadline| @max(0, deadline - now) else null;
    const sleep_mode: ?[]const u8 = if (runtime.sleep_deadline != null)
        "duration"
    else if (runtime.sleep_chapter != null)
        "chapter"
    else
        null;
    if (!runtime.chapters_loaded) {
        if (runtime.socket_path) |socket_path| {
            runtime.chapters = mpv.queryChapters(allocator, io, socket_path) catch &.{};
            runtime.chapters_allocator = allocator;
        }
        runtime.chapters_loaded = true;
    }
    return success(writer, id, .{
        .itemId = runtime.item_id,
        .title = runtime.title orelse "",
        .chapter = runtime.chapter,
        .positionSeconds = runtime.position_seconds,
        .durationSeconds = runtime.duration_seconds,
        .paused = runtime.paused,
        .speed = runtime.speed,
        .volume = runtime.volume,
        .sleepTimer = sleep_remaining,
        .sleepTimerSeconds = sleep_remaining,
        .sleepTimerMode = sleep_mode,
        .ended = runtime.ended,
        .bookmarks = runtime.bookmarks,
        .chapters = runtime.chapters,
    });
}

fn titleFromPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const basename = std.fs.path.basename(path);
    const extension = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - extension.len];
    return allocator.dupe(u8, if (stem.len == 0) basename else stem);
}

fn stringParam(params: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = params.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn numberParam(params: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = params.get(name) orelse return null;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

fn boolParam(params: std.json.ObjectMap, name: []const u8) ?bool {
    const value = params.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn libraryResponse(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: []const u8, method: []const u8, object: std.json.ObjectMap, items: []const library.Item) !void {
    if (std.mem.eql(u8, method, "library.search")) {
        const params = object.get("params") orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const query_value = params.object.get("query") orelse return failure(writer, id, "INVALID_REQUEST", "query is required");
        if (query_value != .string or query_value.string.len == 0) return failure(writer, id, "INVALID_REQUEST", "query must be a non-empty string");
        const found = try library.search(allocator, items, query_value.string);
        defer allocator.free(found);
        return success(writer, id, .{ .items = found, .nextCursor = @as(?[]const u8, null) });
    }
    return success(writer, id, .{ .items = items, .nextCursor = @as(?[]const u8, null) });
}

pub fn handleLine(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, runtime: *Runtime, writer: *std.Io.Writer, line: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return failure(writer, "", "INVALID_REQUEST", "request must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failure(writer, "", "INVALID_REQUEST", "request must be an object");
    const object = parsed.value.object;
    const id_value = object.get("id") orelse return failure(writer, "", "INVALID_REQUEST", "id is required");
    const id = if (id_value == .string) id_value.string else return failure(writer, "", "INVALID_REQUEST", "id must be a string");
    if (id.len == 0) return failure(writer, "", "INVALID_REQUEST", "id must not be empty");
    if (!objectHasOnly(object, &.{ "v", "id", "method", "params" })) return failure(writer, id, "INVALID_REQUEST", "request contains an unknown field");
    const request_version = object.get("v") orelse return failure(writer, id, "INVALID_REQUEST", "v is required");
    if (request_version != .integer or request_version.integer != version) return failure(writer, id, "INVALID_REQUEST", "only protocol v1 is supported");
    const method_value = object.get("method") orelse return failure(writer, id, "INVALID_REQUEST", "method is required");
    const method = if (method_value == .string) method_value.string else return failure(writer, id, "INVALID_REQUEST", "method must be a string");
    const params_value = object.get("params");
    if (params_value) |params| if (params != .object) return failure(writer, id, "INVALID_REQUEST", "params must be an object");

    const allowed_params: []const []const u8 = if (std.mem.eql(u8, method, "profile.select"))
        &.{ "profile", "provider", "account" }
    else if (std.mem.eql(u8, method, "profile.remove"))
        &.{ "profile", "confirm" }
    else if (std.mem.eql(u8, method, "library.list"))
        &.{ "provider", "account", "profile", "cursor", "limit" }
    else if (std.mem.eql(u8, method, "library.search"))
        &.{ "provider", "account", "profile", "query", "cursor", "limit" }
    else if (std.mem.eql(u8, method, "library.refresh"))
        &.{ "provider", "account", "profile" }
    else if (std.mem.eql(u8, method, "downloads.start"))
        &.{ "provider", "account", "profile", "asin", "itemId", "format", "outputDir", "localPath" }
    else if (std.mem.eql(u8, method, "downloads.cancel"))
        &.{"jobId"}
    else if (std.mem.eql(u8, method, "wishlist.list"))
        &.{"profile"}
    else if (std.mem.eql(u8, method, "wishlist.add") or std.mem.eql(u8, method, "wishlist.remove"))
        &.{ "profile", "asin" }
    else if (std.mem.eql(u8, method, "player.command"))
        &.{ "command", "value", "path", "localPath", "itemId", "title", "resume", "provider", "account", "profile", "label", "bookmarkId" }
    else if (std.mem.eql(u8, method, "cancel"))
        &.{"id"}
    else if (std.mem.eql(u8, method, "auth.start"))
        &.{ "profile", "countryCode" }
    else if (std.mem.eql(u8, method, "auth.complete"))
        &.{"callbackUrl"}
    else
        &.{};
    if (params_value) |params| if (!objectHasOnly(params.object, allowed_params)) return failure(writer, id, "INVALID_REQUEST", "params contains an unknown field");

    if (std.mem.eql(u8, method, "health") or std.mem.eql(u8, method, "engine.health") or std.mem.eql(u8, method, "internal.health")) {
        return success(writer, id, .{ .protocolVersion = version, .engineVersion = "0.3.4", .status = "ok" });
    }
    if (std.mem.eql(u8, method, "profile.list") or std.mem.eql(u8, method, "profiles.list")) {
        const found = try profiles.discoverAll(allocator, io, environ);
        defer profiles.deinitProfiles(allocator, found);
        const yoto_accounts = try yoto.discoverAccounts(allocator, io, environ);
        defer yoto.deinitAccounts(allocator, yoto_accounts);
        var values: std.ArrayList(struct { name: []const u8, securePermissions: bool, provider: []const u8, account: []const u8 }) = .empty;
        defer values.deinit(allocator);
        var owned_names: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_names.items) |name| allocator.free(name);
            owned_names.deinit(allocator);
        }
        for (found) |profile| {
            try values.append(allocator, .{ .name = profile.name, .securePermissions = profile.secure_permissions, .provider = "audible", .account = profile.name });
            if (runtime.database) |database| database.putProfile(profile.name, null, null) catch {};
        }
        for (yoto_accounts) |account| {
            const name = try std.fmt.allocPrint(allocator, "yoto:{s}", .{account.id});
            try owned_names.append(allocator, name);
            try values.append(allocator, .{ .name = name, .securePermissions = account.secure_permissions, .provider = "yoto", .account = account.id });
            if (runtime.database) |database| {
                database.putProvider("yoto", "Yoto") catch {};
                database.putAccount(.{ .identity = .{ .provider_id = "yoto", .account_id = account.id }, .display_name = account.id }) catch {};
            }
        }
        var selected: ?[]u8 = if (runtime.database) |database| try database.getSelectedProfile(allocator) else null;
        defer if (selected) |name| allocator.free(name);
        if (runtime.database) |database| if (try database.getSelectedAccount(allocator)) |selected_account| {
            defer selected_account.deinit(allocator);
            if (std.mem.eql(u8, selected_account.provider_id, "yoto")) {
                if (selected) |name| allocator.free(name);
                selected = try std.fmt.allocPrint(allocator, "yoto:{s}", .{selected_account.account_id});
            }
        };
        if (selected) |name| {
            var still_present = false;
            for (values.items) |profile| if (std.mem.eql(u8, profile.name, name)) {
                still_present = true;
                break;
            };
            if (!still_present) {
                allocator.free(name);
                selected = null;
            }
        }
        if (selected == null and values.items.len != 0 and runtime.database != null) {
            const fallback = for (values.items) |profile| {
                if (std.mem.eql(u8, profile.name, "default")) break profile;
            } else values.items[0];
            try runtime.database.?.setSelectedAccount(.{ .provider_id = fallback.provider, .account_id = fallback.account });
            if (std.mem.eql(u8, fallback.provider, "audible")) try runtime.database.?.setSelectedProfile(fallback.account);
            selected = try allocator.dupe(u8, fallback.name);
        }
        return success(writer, id, .{ .items = values.items, .selectedProfile = selected });
    }
    if (std.mem.eql(u8, method, "profile.select")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const name = stringParam(params.object, "profile") orelse return failure(writer, id, "INVALID_REQUEST", "profile is required");
        const provider_id = stringParam(params.object, "provider") orelse if (std.mem.startsWith(u8, name, "yoto:")) "yoto" else "audible";
        const account = stringParam(params.object, "account") orelse if (std.mem.eql(u8, provider_id, "yoto") and std.mem.startsWith(u8, name, "yoto:")) name[5..] else name;
        if (std.mem.eql(u8, provider_id, "yoto")) {
            const accounts = try yoto.discoverAccounts(allocator, io, environ);
            defer yoto.deinitAccounts(allocator, accounts);
            var exists = false;
            for (accounts) |candidate| if (std.mem.eql(u8, candidate.id, account)) {
                exists = true;
                break;
            };
            if (!exists) return failure(writer, id, "INVALID_REQUEST", "Yoto account was not found");
            const database = runtime.database orelse return failure(writer, id, "INTERNAL", "account selection storage is unavailable");
            database.putAccount(.{ .identity = .{ .provider_id = "yoto", .account_id = account }, .display_name = account }) catch return failure(writer, id, "INTERNAL", "Yoto account could not be saved");
            database.setSelectedAccount(.{ .provider_id = "yoto", .account_id = account }) catch return failure(writer, id, "INTERNAL", "Yoto account selection could not be saved");
            return success(writer, id, .{ .profile = name, .provider = "yoto", .account = account, .selected = true });
        }
        if (!std.mem.eql(u8, provider_id, "audible")) return failure(writer, id, "INVALID_REQUEST", "provider must be audible or yoto");
        const found = try profiles.discoverAll(allocator, io, environ);
        defer profiles.deinitProfiles(allocator, found);
        var exists = false;
        for (found) |profile| if (std.mem.eql(u8, profile.name, name)) {
            exists = true;
            break;
        };
        if (!exists) return failure(writer, id, "INVALID_REQUEST", "profile was not found");
        const database = runtime.database orelse return failure(writer, id, "INTERNAL", "profile selection storage is unavailable");
        database.setSelectedProfile(name) catch return failure(writer, id, "INTERNAL", "profile selection could not be saved");
        database.setSelectedAccount(.{ .provider_id = "audible", .account_id = name }) catch {};
        return success(writer, id, .{ .profile = name, .provider = "audible", .account = name, .selected = true });
    }
    if (std.mem.eql(u8, method, "profile.status")) {
        const selected = if (runtime.database) |database| try database.getSelectedProfile(allocator) else null;
        defer if (selected) |name| allocator.free(name);
        return success(writer, id, .{ .selectedProfile = selected, .sqlite = runtime.database != null, .remoteDeregistration = false });
    }
    if (std.mem.eql(u8, method, "profile.remove")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const name = stringParam(params.object, "profile") orelse return failure(writer, id, "INVALID_REQUEST", "profile is required");
        if (boolParam(params.object, "confirm") != true) return failure(writer, id, "CONFIRMATION_REQUIRED", "set confirm=true to remove only the local credential copy");
        if (std.mem.startsWith(u8, name, "yoto:")) {
            const account = name[5..];
            const credential_path = yoto.credentialsPath(allocator, environ, account) catch return failure(writer, id, "INVALID_REQUEST", "Yoto account name is invalid");
            defer allocator.free(credential_path);
            std.Io.Dir.cwd().deleteFile(io, credential_path) catch |err| switch (err) {
                error.FileNotFound => return failure(writer, id, "INVALID_REQUEST", "Yoto account was not found"),
                else => return failure(writer, id, "INTERNAL", "local Yoto credentials could not be removed"),
            };
            const cache_path = yoto.cachePath(allocator, environ, account) catch null;
            if (cache_path) |path| {
                defer allocator.free(path);
                std.Io.Dir.cwd().deleteFile(io, path) catch {};
            }
            if (runtime.database) |database| database.removeProviderAccount(.{ .provider_id = "yoto", .account_id = account }) catch return failure(writer, id, "INTERNAL", "local Yoto state could not be removed");
            return success(writer, id, .{ .profile = name, .provider = "yoto", .account = account, .removed = true, .remoteDeregistered = false });
        }
        const found = try profiles.discoverAll(allocator, io, environ);
        defer profiles.deinitProfiles(allocator, found);
        var local_path: ?[]const u8 = null;
        for (found) |profile| if (std.mem.eql(u8, profile.name, name)) {
            local_path = profile.path;
            break;
        };
        const profile_path = local_path orelse return failure(writer, id, "INVALID_REQUEST", "profile was not found");
        std.Io.Dir.cwd().deleteFile(io, profile_path) catch return failure(writer, id, "INTERNAL", "local profile could not be removed");
        if (runtime.database) |database| database.removeProfileState(name) catch return failure(writer, id, "INTERNAL", "local profile state could not be removed");
        return success(writer, id, .{ .profile = name, .removed = true, .remoteDeregistered = false });
    }
    if (std.mem.eql(u8, method, "auth.start")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const profile = stringParam(params.object, "profile") orelse "default";
        const country = stringParam(params.object, "countryCode") orelse "us";
        if (runtime.pending_login) |*previous| {
            std.crypto.secureZero(u8, &previous.verifier);
            runtime.pending_login = null;
        }
        runtime.pending_login = external_auth.begin(allocator, io, profile, country) catch |err| switch (err) {
            error.InvalidProfileName, error.UnsupportedMarketplace => return failure(writer, id, "INVALID_REQUEST", "profile name or marketplace is invalid"),
            else => return err,
        };
        const pending = &runtime.pending_login.?;
        const login_url = try external_auth.loginUrl(allocator, pending);
        defer allocator.free(login_url);
        return success(writer, id, .{ .profile = pending.profile, .countryCode = pending.locale.country_code, .loginUrl = login_url });
    }
    if (std.mem.eql(u8, method, "auth.complete")) {
        // Protocol v1 deliberately has no channel for credential-encryption
        // passphrases. Refuse before exchanging the one-time code so callers
        // cannot register a device whose credentials cannot be persisted.
        return failure(writer, id, "INTERACTIVE_REQUIRED", "finish authorization with `audible-zig quickstart`; secure passphrases are never accepted over RPC");
    }
    if (std.mem.eql(u8, method, "library.refresh")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const provider_id = stringParam(params.object, "provider") orelse "audible";
        const account = stringParam(params.object, "account") orelse stringParam(params.object, "profile") orelse "default";
        if (std.mem.eql(u8, provider_id, "yoto")) {
            const result = yoto.refreshLibrary(allocator, io, environ, account) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRefreshToken, error.TokenRefreshRejected, error.Unauthorized => return failure(writer, id, "REAUTH_REQUIRED", "the Yoto account must be connected again"),
                error.InvalidAccountName => return failure(writer, id, "INVALID_REQUEST", "the Yoto account name is invalid"),
                else => return failure(writer, id, "INTERNAL", "Yoto library refresh failed without replacing the existing cache"),
            };
            if (runtime.database) |database| {
                database.putProvider("yoto", "Yoto") catch {};
                database.putAccount(.{ .identity = .{ .provider_id = "yoto", .account_id = account }, .display_name = account }) catch {};
            }
            return success(writer, id, .{ .provider = "yoto", .account = account, .itemCount = result.item_count, .tokenRefreshed = result.token_refreshed });
        }
        if (!std.mem.eql(u8, provider_id, "audible")) return failure(writer, id, "INVALID_REQUEST", "provider must be audible or yoto");
        const profile_name = account;
        if (profile_name.len == 0) return failure(writer, id, "INVALID_REQUEST", "profile must not be empty");
        const xdg = paths.resolve(allocator, environ) catch return failure(writer, id, "INTERNAL", "application paths could not be resolved");
        defer xdg.deinit(allocator);
        const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
        defer allocator.free(cache_path);
        const result = api_sync.refreshProfile(allocator, io, environ, profile_name, cache_path) catch |err| switch (err) {
            error.ProfileNotFound => return failure(writer, id, "REAUTH_REQUIRED", "profile was not found; connect this account first"),
            error.ProfilePasswordRequired => return failure(writer, id, "PASSWORD_REQUIRED", "the selected legacy profile is encrypted; reconnect it with native authentication"),
            error.UnsafeCredentialPermissions => return failure(writer, id, "UNSAFE_CREDENTIALS", "profile permissions must deny access to group and other users"),
            error.InvalidAuthProfile, error.RefreshTokenRequired, error.TokenRefreshRejected, error.Unauthorized => return failure(writer, id, "REAUTH_REQUIRED", "the selected profile must be authenticated again"),
            error.RateLimited => return failure(writer, id, "RATE_LIMITED", "Audible temporarily rate-limited the library refresh"),
            else => return failure(writer, id, "INTERNAL", "library refresh failed without replacing the existing cache"),
        };
        if (runtime.database) |database| if (library.loadCache(allocator, io, cache_path)) |cached| {
            defer cached.deinit();
            database.upsertLibraryItems(profile_name, cached.value.items) catch return failure(writer, id, "INTERNAL", "library refreshed but SQLite mirroring failed");
        } else |_| {};
        return success(writer, id, .{ .profile = profile_name, .itemCount = result.item_count, .tokenRefreshed = result.token_refreshed });
    }
    if (std.mem.eql(u8, method, "library.list") or std.mem.eql(u8, method, "library.search")) {
        const requested_provider = if (params_value) |params| stringParam(params.object, "provider") else null;
        const account = if (params_value) |params| stringParam(params.object, "account") orelse stringParam(params.object, "profile") orelse "default" else "default";
        if (requested_provider) |provider_id| {
            if (std.mem.eql(u8, provider_id, "yoto")) {
                var cached = yoto.loadCache(allocator, io, environ, account) catch return libraryResponse(allocator, writer, id, method, object, &.{});
                defer cached.deinit();
                return libraryResponse(allocator, writer, id, method, object, cached.value.items);
            }
            if (!std.mem.eql(u8, provider_id, "audible")) return failure(writer, id, "INVALID_REQUEST", "provider must be audible or yoto");
        }
        const xdg = paths.resolve(allocator, environ) catch return libraryResponse(allocator, writer, id, method, object, &.{});
        defer xdg.deinit(allocator);
        const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
        defer allocator.free(cache_path);
        if (library.loadCache(allocator, io, cache_path)) |cached| {
            defer cached.deinit();
            if (runtime.database) |database| database.upsertLibraryItems(if (params_value) |params| stringParam(params.object, "profile") orelse "default" else "default", cached.value.items) catch {};
            if (requested_provider != null) return libraryResponse(allocator, writer, id, method, object, cached.value.items);
            if (yoto.loadCache(allocator, io, environ, account)) |yoto_cached_value| {
                var yoto_cached = yoto_cached_value;
                defer yoto_cached.deinit();
                var merged: std.ArrayList(library.Item) = .empty;
                defer merged.deinit(allocator);
                try merged.appendSlice(allocator, cached.value.items);
                try merged.appendSlice(allocator, yoto_cached.value.items);
                return libraryResponse(allocator, writer, id, method, object, merged.items);
            } else |_| {}
            if (cached.value.items.len != 0) return libraryResponse(allocator, writer, id, method, object, cached.value.items);
        } else |_| {}
        if (requested_provider == null) if (yoto.loadCache(allocator, io, environ, account)) |yoto_cached_value| {
            var yoto_cached = yoto_cached_value;
            defer yoto_cached.deinit();
            if (yoto_cached.value.items.len != 0) return libraryResponse(allocator, writer, id, method, object, yoto_cached.value.items);
        } else |_| {};
        const local_directory = environ.getAlloc(allocator, "AUDIBLE_LIBRARY_DIR") catch return libraryResponse(allocator, writer, id, method, object, &.{});
        defer allocator.free(local_directory);
        const scanned = library.scanDirectory(allocator, io, local_directory) catch return libraryResponse(allocator, writer, id, method, object, &.{});
        defer scanned.deinit(allocator);
        return libraryResponse(allocator, writer, id, method, object, scanned.items);
    }
    if (std.mem.eql(u8, method, "wishlist.list") or std.mem.eql(u8, method, "wishlist.add") or std.mem.eql(u8, method, "wishlist.remove")) {
        const profile_name = if (params_value) |params| stringParam(params.object, "profile") orelse "default" else "default";
        const discovered = profiles.discoverAll(allocator, io, environ) catch return failure(writer, id, "REAUTH_REQUIRED", "the selected profile was not found");
        defer profiles.deinitProfiles(allocator, discovered);
        var selected: ?profiles.Profile = null;
        for (discovered) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
            selected = profile;
            break;
        };
        const profile = selected orelse return failure(writer, id, "REAUTH_REQUIRED", "the selected profile was not found");
        profiles.safeToRead(profile) catch return failure(writer, id, "UNSAFE_CREDENTIALS", "profile permissions must deny access to group and other users");
        var document = api_sync.loadProfileDocument(allocator, io, profile.path) catch return failure(writer, id, "REAUTH_REQUIRED", "the selected profile must be authenticated again");
        defer document.deinit();
        const asin = if (std.mem.eql(u8, method, "wishlist.list")) null else stringParam(params_value.?.object, "asin") orelse return failure(writer, id, "INVALID_REQUEST", "asin is required");
        const endpoint = if (std.mem.eql(u8, method, "wishlist.add"))
            allocator.dupe(u8, "wishlist") catch return failure(writer, id, "INTERNAL", "wishlist request could not be prepared")
        else
            api_account.wishlistEndpoint(allocator, asin) catch return failure(writer, id, "INVALID_REQUEST", "asin is invalid");
        defer allocator.free(endpoint);
        const request_body = if (std.mem.eql(u8, method, "wishlist.add"))
            std.fmt.allocPrint(allocator, "{{\"asin\":\"{s}\"}}", .{asin.?}) catch return failure(writer, id, "INTERNAL", "wishlist request could not be prepared")
        else
            null;
        defer if (request_body) |body| allocator.free(body);
        const response = api_account.requestDocument(allocator, io, document.value, .{
            .method = if (std.mem.eql(u8, method, "wishlist.add")) .POST else if (std.mem.eql(u8, method, "wishlist.remove")) .DELETE else .GET,
            .endpoint = endpoint,
            .body = request_body,
        }) catch |err| switch (err) {
            error.Unauthorized => return failure(writer, id, "REAUTH_REQUIRED", "the selected profile must be authenticated again"),
            error.RateLimited => return failure(writer, id, "RATE_LIMITED", "Audible temporarily rate-limited the wishlist request"),
            else => return failure(writer, id, "INTERNAL", "wishlist request failed"),
        };
        defer response.deinit(allocator);
        if (std.mem.eql(u8, method, "wishlist.list")) {
            const page = api_account.parseWishlist(allocator, response.body) catch return failure(writer, id, "INTERNAL", "Audible returned an invalid wishlist response");
            defer page.deinit();
            var mapped: std.ArrayList(library.Item) = .empty;
            defer mapped.deinit(allocator);
            api_sync.appendMapped(allocator, &mapped, page.value.products) catch return failure(writer, id, "INTERNAL", "wishlist response could not be normalized");
            const items = try mapped.toOwnedSlice(allocator);
            defer api_sync.deinitMapped(allocator, items);
            return success(writer, id, .{ .items = items });
        }
        return success(writer, id, .{ .asin = asin.?, .changed = true });
    }
    if (std.mem.eql(u8, method, "downloads.list")) {
        // Polling is also the recovery heartbeat: it reclaims stale active
        // records and fills open queue slots after an unclean worker exit.
        dispatchDownloads(allocator, io, environ) catch {};
        const directory = try jobsDirectory(allocator, environ);
        defer allocator.free(directory);
        const persistent = try download_jobs.list(allocator, io, directory);
        defer download_jobs.deinitList(allocator, persistent);
        var records: std.ArrayList(download_jobs.Record) = .empty;
        defer records.deinit(allocator);
        const fingerprint = downloadFingerprint(persistent);
        for (persistent) |*loaded| {
            try records.append(allocator, loaded.value().*);
            if (fingerprint != runtime.download_mirror_fingerprint)
                if (runtime.database) |database| mirrorDownload(database, io, loaded.value().*) catch {};
        }
        runtime.download_mirror_fingerprint = fingerprint;
        return success(writer, id, .{ .jobs = records.items });
    }
    if (std.mem.eql(u8, method, "downloads.start")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        if (std.mem.eql(u8, stringParam(params.object, "provider") orelse "audible", "yoto"))
            return failure(writer, id, "UNSUPPORTED", "Yoto titles stream securely and are not downloaded by Auditui");
        const source = stringParam(params.object, "localPath");
        const asin = stringParam(params.object, "asin") orelse stringParam(params.object, "itemId") orelse "local";
        const item_id = stringParam(params.object, "itemId") orelse asin;
        const xdg = try paths.resolve(allocator, environ);
        defer xdg.deinit(allocator);
        const output_dir = stringParam(params.object, "outputDir") orelse blk: {
            const value = try std.fs.path.join(allocator, &.{ xdg.data, "downloads" });
            break :blk value;
        };
        defer if (params.object.get("outputDir") == null) allocator.free(output_dir);
        try std.Io.Dir.cwd().createDirPath(io, output_dir);
        const destination = if (source) |local_path| blk: {
            const stat = std.Io.Dir.cwd().statFile(io, local_path, .{}) catch return failure(writer, id, "INVALID_REQUEST", "localPath was not found");
            if (stat.kind != .file) return failure(writer, id, "INVALID_REQUEST", "localPath must identify a regular file");
            const safe_name = try downloads.sanitizeFilename(allocator, std.fs.path.basename(local_path));
            defer allocator.free(safe_name);
            break :blk try std.fs.path.join(allocator, &.{ output_dir, safe_name });
        } else null;
        defer if (destination) |value| allocator.free(value);
        const directory = try jobsDirectory(allocator, environ);
        defer allocator.free(directory);
        const now = std.Io.Clock.real.now(io).toSeconds();
        var prior_attempts: u16 = 0;
        var original_created_at = now;
        if (download_jobs.load(allocator, io, directory, item_id)) |existing_value| {
            var existing = existing_value;
            defer existing.deinit();
            if (existing.value().state == .active or existing.value().state == .queued)
                return success(writer, id, existing.value().*);
            if (existing.value().state == .completed and existing.value().path != null)
                return success(writer, id, existing.value().*);
            prior_attempts = existing.value().attempts;
            original_created_at = existing.value().createdAt;
        } else |_| {}
        const title = if (source) |local_path| try titleFromPath(allocator, local_path) else blk: {
            const cache_path = try std.fs.path.join(allocator, &.{ xdg.cache, "library.json" });
            defer allocator.free(cache_path);
            var cache = library.loadCache(allocator, io, cache_path) catch return failure(writer, id, "INVALID_REQUEST", "refresh the owned library before downloading");
            defer cache.deinit();
            for (cache.value.items) |item| if (std.mem.eql(u8, item.asin, asin)) break :blk try allocator.dupe(u8, item.title);
            return failure(writer, id, "INVALID_REQUEST", "the requested ASIN is not in the owned-library cache");
        };
        defer allocator.free(title);
        const record: download_jobs.Record = .{
            .jobId = item_id,
            .itemId = item_id,
            .asin = if (source == null) asin else "",
            .title = title,
            .profile = stringParam(params.object, "profile") orelse "default",
            .kind = if (source == null) .audible else .local,
            .source = source,
            .outputDir = output_dir,
            .destination = destination,
            .attempts = prior_attempts,
            .createdAt = original_created_at,
            .updatedAt = now,
        };
        try download_jobs.clearCancel(allocator, io, directory, item_id);
        try download_jobs.save(allocator, io, directory, record);
        if (runtime.database) |database| mirrorDownload(database, io, record) catch return failure(writer, id, "INTERNAL", "download was queued but SQLite mirroring failed");
        runtime.download_mirror_fingerprint = null;
        dispatchDownloads(allocator, io, environ) catch return failure(writer, id, "INTERNAL", "download was queued but its worker could not start; retry will recover it");
        return success(writer, id, record);
    }
    if (std.mem.eql(u8, method, "player.status")) return playerSuccess(allocator, io, writer, id, runtime);
    if (std.mem.eql(u8, method, "player.command")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const command = stringParam(params.object, "command") orelse return failure(writer, id, "INVALID_REQUEST", "command is required");
        if (std.mem.eql(u8, command, "play")) {
            const provider_id = stringParam(params.object, "provider") orelse "audible";
            const account = stringParam(params.object, "account") orelse stringParam(params.object, "profile") orelse "default";
            const local_path_param = stringParam(params.object, "localPath") orelse stringParam(params.object, "path");
            const source = if (local_path_param) |local_path| blk: {
                const stat = std.Io.Dir.cwd().statFile(io, local_path, .{}) catch return failure(writer, id, "INVALID_REQUEST", "local media file was not found");
                if (stat.kind != .file) return failure(writer, id, "INVALID_REQUEST", "localPath must identify a regular file");
                break :blk local_path;
            } else if (std.mem.eql(u8, provider_id, "yoto")) blk: {
                const item_id = stringParam(params.object, "itemId") orelse return failure(writer, id, "INVALID_REQUEST", "Yoto play requires itemId");
                break :blk yoto.playableSource(allocator, io, environ, account, item_id) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRefreshToken, error.TokenRefreshRejected, error.Unauthorized => return failure(writer, id, "REAUTH_REQUIRED", "the Yoto account must be connected again"),
                    error.NoPlayableTracks => return failure(writer, id, "UNSUPPORTED", "this Yoto card has no playable audio tracks"),
                    error.ContentForbidden, error.ContentNotFound => return failure(writer, id, "UNSUPPORTED", "Yoto did not provide playable audio for this card on this account"),
                    else => return failure(writer, id, "INTERNAL", "Yoto could not prepare this title for playback"),
                };
            } else return failure(writer, id, "INVALID_REQUEST", "play requires localPath");
            if (runtime.player != null) runtime.deinit(io);
            const xdg = try paths.resolve(allocator, environ);
            defer xdg.deinit(allocator);
            try std.Io.Dir.cwd().createDirPath(io, xdg.state);
            const socket_path = try std.fs.path.join(allocator, &.{ xdg.state, "mpv.sock" });
            std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};
            const ipc_arg = try std.fmt.allocPrint(allocator, "--input-ipc-server={s}", .{socket_path});
            defer allocator.free(ipc_arg);
            runtime.player = std.process.spawn(io, .{ .argv = &.{ "mpv", "--no-terminal", "--force-window=no", "--audio-display=no", "--idle=yes", ipc_arg }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return failure(writer, id, "INTERNAL", "could not launch mpv; verify it is installed and the media is supported");
            waitForSocket(io, socket_path) catch {
                if (runtime.player) |*child| child.kill(io);
                runtime.player = null;
                return failure(writer, id, "INTERNAL", "mpv IPC did not become ready");
            };
            if (local_path_param != null and std.ascii.eqlIgnoreCase(std.fs.path.extension(source), ".aaxc")) {
                const voucher_path = try voucherPathForMedia(allocator, source);
                defer allocator.free(voucher_path);
                const profile_name = stringParam(params.object, "profile") orelse "default";
                const voucher = api_download.voucherForProfile(allocator, io, environ, profile_name, voucher_path) catch {
                    if (runtime.player) |*child| child.kill(io);
                    runtime.player = null;
                    return failure(writer, id, "VOUCHER_REQUIRED", "the private AAXC voucher is missing or invalid; download the title again");
                };
                defer voucher.deinit();
                const options = try std.fmt.allocPrint(allocator, "audible_key={s},audible_iv={s}", .{ voucher.key, voucher.iv });
                defer {
                    std.crypto.secureZero(u8, options);
                    allocator.free(options);
                }
                sendMpv(io, socket_path, .{ .demuxer_options = options }) catch {
                    if (runtime.player) |*child| child.kill(io);
                    runtime.player = null;
                    return failure(writer, id, "INTERNAL", "could not configure protected Audible playback");
                };
            }
            sendMpv(io, socket_path, .{ .loadfile = source }) catch {
                if (runtime.player) |*child| child.kill(io);
                runtime.player = null;
                return failure(writer, id, "INTERNAL", "could not load the local media file");
            };
            runtime.item_id = try allocator.dupe(u8, stringParam(params.object, "itemId") orelse source);
            runtime.title = if (stringParam(params.object, "title")) |title|
                try allocator.dupe(u8, title)
            else if (std.mem.eql(u8, provider_id, "yoto"))
                try allocator.dupe(u8, runtime.item_id.?)
            else
                try titleFromPath(allocator, source);
            runtime.local_path = try allocator.dupe(u8, source);
            runtime.socket_path = socket_path;
            runtime.profile_name = try allocator.dupe(u8, account);
            runtime.provider_id = provider_id;
            {
                // Desktop integrations read this file; it never carries the
                // media source (a signed Yoto URL or local path), only a cover
                // image that already sits beside a local download.
                const cover = if (local_path_param != null) now_playing.existingCover(allocator, io, source) else null;
                defer if (cover) |value| allocator.free(value);
                now_playing.write(allocator, io, xdg.state, .{
                    .provider = provider_id,
                    .account = account,
                    .itemId = runtime.item_id.?,
                    .title = runtime.title.?,
                    .coverPath = cover,
                    .startedAt = std.Io.Clock.real.now(io).toSeconds(),
                    .enginePid = now_playing.currentPid(),
                }) catch {};
            }
            if (runtime.database) |database| {
                database.putProvider(provider_id, if (std.mem.eql(u8, provider_id, "yoto")) "Yoto" else "Audible") catch {};
                database.putAccount(.{ .identity = .{ .provider_id = provider_id, .account_id = account }, .display_name = account }) catch {};
            }
            runtime.paused = false;
            runtime.position_seconds = 0;
            runtime.duration_seconds = 0;
            runtime.chapter = 0;
            runtime.ended = false;
            runtime.bookmarks = &.{};
            runtime.chapters = &.{};
            runtime.chapters_allocator = null;
            runtime.chapters_loaded = false;
            runtime.sleep_deadline = null;
            runtime.sleep_chapter = null;

            // mpv acknowledges loadfile before demuxing completes. Wait briefly
            // for a real duration so the saved seek is applied deterministically.
            var attempt: u8 = 0;
            while (attempt < 80) : (attempt += 1) {
                const state = mpv.queryState(allocator, io, socket_path, .{ .path = runtime.local_path }) catch {
                    try std.Io.sleep(io, .fromMilliseconds(25), .awake);
                    continue;
                };
                if (state.duration > 0) {
                    runtime.duration_seconds = state.duration;
                    break;
                }
                try std.Io.sleep(io, .fromMilliseconds(25), .awake);
            }
            if (runtime.database) |database| {
                if (try database.getProviderPlaybackPosition(.{ .provider_id = runtime.provider_id, .account_id = runtime.profile_name.? }, runtime.item_id.?)) |saved| {
                    const resume_at = mpv.resumePosition(saved.position_seconds, if (runtime.duration_seconds > 0) runtime.duration_seconds else saved.duration_seconds);
                    runtime.last_saved_position = resume_at;
                    runtime.last_saved_duration = saved.duration_seconds;
                    if (resume_at > 0) {
                        sendMpv(io, socket_path, .{ .seek_absolute = resume_at }) catch {};
                        runtime.position_seconds = resume_at;
                    }
                }
                // Speed is remembered per provider: a Yoto card should never
                // inherit the 1.5x an audiobook listener picked for Audible.
                const speed_key = try speedSettingKey(allocator, provider_id);
                defer allocator.free(speed_key);
                if (try database.getSetting(allocator, speed_key)) |saved_speed| {
                    defer allocator.free(saved_speed);
                    if (std.fmt.parseFloat(f64, saved_speed)) |value| {
                        if (value >= 0.5 and value <= 3) {
                            sendMpv(io, socket_path, .{ .speed = value }) catch {};
                            runtime.speed = value;
                        }
                    } else |_| {}
                }
                if (try database.getSetting(allocator, "player.volume")) |saved_volume| {
                    defer allocator.free(saved_volume);
                    if (std.fmt.parseFloat(f64, saved_volume)) |value| {
                        if (value >= 0 and value <= 100) {
                            sendMpv(io, socket_path, .{ .volume = value }) catch {};
                            runtime.volume = value;
                        }
                    } else |_| {}
                }
                loadBookmarks(allocator, runtime) catch {};
            }
            try event(writer, "player.state", .{ .state = "playing", .positionSeconds = 0, .durationSeconds = 0, .chapter = 0, .speed = 1, .volume = 100 });
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        if (std.mem.eql(u8, command, "stop")) {
            runtime.deinit(io);
            runtime.item_id = null;
            runtime.title = null;
            runtime.local_path = null;
            runtime.paused = true;
            runtime.position_seconds = 0;
            runtime.duration_seconds = 0;
            runtime.chapter = 0;
            runtime.ended = false;
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        const socket_path = runtime.socket_path orelse return failure(writer, id, "INVALID_REQUEST", "no active player");
        if (std.mem.eql(u8, command, "set-sleep-timer")) {
            const seconds = numberParam(params.object, "value") orelse return failure(writer, id, "INVALID_REQUEST", "sleep timer requires seconds");
            if (seconds <= 0 or seconds > 86_400) return failure(writer, id, "INVALID_REQUEST", "sleep timer must be between 1 second and 24 hours");
            runtime.sleep_deadline = std.Io.Clock.real.now(io).toSeconds() + @as(i64, @intFromFloat(@ceil(seconds)));
            runtime.sleep_chapter = null;
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        if (std.mem.eql(u8, command, "cancel-sleep-timer")) {
            runtime.sleep_deadline = null;
            runtime.sleep_chapter = null;
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        if (std.mem.eql(u8, command, "sleep-end-chapter")) {
            runtime.sleep_deadline = null;
            runtime.sleep_chapter = runtime.chapter;
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        if (std.mem.eql(u8, command, "bookmark-add")) {
            const database = runtime.database orelse return failure(writer, id, "INTERNAL", "bookmark database is unavailable");
            const state = mpv.queryState(allocator, io, socket_path, .{
                .path = runtime.local_path,
                .time_pos = runtime.position_seconds,
                .duration = runtime.duration_seconds,
                .paused = runtime.paused,
                .chapter = runtime.chapter,
                .speed = runtime.speed,
                .volume = runtime.volume,
                .ended = runtime.ended,
            }) catch null;
            if (state) |current| runtime.position_seconds = current.time_pos;
            _ = database.addProviderBookmark(.{ .provider_id = runtime.provider_id, .account_id = runtime.profile_name.? }, runtime.item_id.?, runtime.title.?, runtime.position_seconds, stringParam(params.object, "label")) catch return failure(writer, id, "INTERNAL", "bookmark could not be saved");
            loadBookmarks(allocator, runtime) catch return failure(writer, id, "INTERNAL", "bookmarks could not be loaded");
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        if (std.mem.eql(u8, command, "bookmark-delete")) {
            const bookmark_value = params.object.get("bookmarkId") orelse return failure(writer, id, "INVALID_REQUEST", "bookmarkId is required");
            if (bookmark_value != .integer or bookmark_value.integer < 1) return failure(writer, id, "INVALID_REQUEST", "bookmarkId must be a positive integer");
            const database = runtime.database orelse return failure(writer, id, "INTERNAL", "bookmark database is unavailable");
            database.deleteProviderBookmark(.{ .provider_id = runtime.provider_id, .account_id = runtime.profile_name.? }, bookmark_value.integer) catch return failure(writer, id, "INTERNAL", "bookmark could not be deleted");
            loadBookmarks(allocator, runtime) catch return failure(writer, id, "INTERNAL", "bookmarks could not be loaded");
            return playerSuccess(allocator, io, writer, id, runtime);
        }
        // A finished title starts over when the listener presses play, seeks,
        // or changes chapter. mpv sits idle after EOF and would otherwise
        // reject those commands, which used to surface as a misleading
        // "mpv IPC is not ready" error.
        const restart = runtime.ended and runtime.local_path != null and
            (std.mem.eql(u8, command, "toggle") or std.mem.eql(u8, command, "seek-relative") or
                std.mem.eql(u8, command, "seek-absolute") or std.mem.eql(u8, command, "chapter-next") or
                std.mem.eql(u8, command, "chapter-previous") or std.mem.eql(u8, command, "chapter-set"));
        if (restart) {
            sendMpv(io, socket_path, .{ .loadfile = runtime.local_path.? }) catch return failure(writer, id, "INTERNAL", "the title has ended and could not be restarted");
            var attempt: u8 = 0;
            while (attempt < 80) : (attempt += 1) {
                const state = mpv.queryState(allocator, io, socket_path, .{ .path = runtime.local_path }) catch {
                    try std.Io.sleep(io, .fromMilliseconds(25), .awake);
                    continue;
                };
                if (state.duration > 0) break;
                try std.Io.sleep(io, .fromMilliseconds(25), .awake);
            }
            runtime.ended = false;
            runtime.paused = false;
            runtime.position_seconds = 0;
            runtime.chapter = 0;
        }
        const ipc_command: mpv.Command = if (std.mem.eql(u8, command, "pause"))
            .{ .pause = true }
        else if (std.mem.eql(u8, command, "toggle"))
            (if (restart) mpv.Command{ .pause = false } else .pause_toggle)
        else if (std.mem.eql(u8, command, "seek-relative"))
            .{ .seek_relative = if (params.object.get("value")) |value| if (value == .float) value.float else if (value == .integer) @floatFromInt(value.integer) else return failure(writer, id, "INVALID_REQUEST", "value must be a number") else return failure(writer, id, "INVALID_REQUEST", "value is required") }
        else if (std.mem.eql(u8, command, "seek-absolute"))
            .{ .seek_absolute = if (params.object.get("value")) |value| if (value == .float) value.float else if (value == .integer) @floatFromInt(value.integer) else return failure(writer, id, "INVALID_REQUEST", "value must be a number") else return failure(writer, id, "INVALID_REQUEST", "value is required") }
        else if (std.mem.eql(u8, command, "chapter-next"))
            .{ .chapter_relative = 1 }
        else if (std.mem.eql(u8, command, "chapter-prev") or std.mem.eql(u8, command, "chapter-previous"))
            .{ .chapter_relative = -1 }
        else if (std.mem.eql(u8, command, "chapter-set")) blk: {
            const value = numberParam(params.object, "value") orelse return failure(writer, id, "INVALID_REQUEST", "chapter index must be a number");
            if (value < 0 or value > 999 or @floor(value) != value) return failure(writer, id, "INVALID_REQUEST", "chapter index must be between 0 and 999");
            break :blk .{ .chapter = @intFromFloat(value) };
        } else if (std.mem.eql(u8, command, "set-speed")) blk: {
            const value = numberParam(params.object, "value") orelse return failure(writer, id, "INVALID_REQUEST", "value must be a number");
            if (value < 0.5 or value > 3) return failure(writer, id, "INVALID_REQUEST", "speed must be between 0.5 and 3");
            break :blk .{ .speed = value };
        } else if (std.mem.eql(u8, command, "set-volume")) blk: {
            const value = numberParam(params.object, "value") orelse return failure(writer, id, "INVALID_REQUEST", "value must be a number");
            if (value < 0 or value > 100) return failure(writer, id, "INVALID_REQUEST", "volume must be between 0 and 100");
            break :blk .{ .volume = value };
        } else return failure(writer, id, "NOT_IMPLEMENTED", "unknown player command");
        sendMpv(io, socket_path, ipc_command) catch return failure(writer, id, "INTERNAL", "mpv IPC is not ready or disconnected");
        if (std.mem.eql(u8, command, "pause")) runtime.paused = true;
        if (std.mem.eql(u8, command, "toggle") and !restart) runtime.paused = !runtime.paused;
        if (std.mem.eql(u8, command, "set-speed")) runtime.speed = numberParam(params.object, "value").?;
        if (std.mem.eql(u8, command, "set-volume")) runtime.volume = numberParam(params.object, "value").?;
        if (runtime.database) |database| {
            if (std.mem.eql(u8, command, "set-speed") or std.mem.eql(u8, command, "set-volume")) {
                const value = try std.fmt.allocPrint(allocator, "{d}", .{numberParam(params.object, "value").?});
                defer allocator.free(value);
                const speed_key = try speedSettingKey(allocator, runtime.provider_id);
                defer allocator.free(speed_key);
                database.putSetting(if (std.mem.eql(u8, command, "set-speed")) speed_key else "player.volume", value) catch {};
            }
        }
        return playerSuccess(allocator, io, writer, id, runtime);
    }
    if (std.mem.eql(u8, method, "cancel")) return success(writer, id, .{ .cancelled = false });
    if (std.mem.eql(u8, method, "downloads.cancel")) {
        const params = params_value orelse return failure(writer, id, "INVALID_REQUEST", "params are required");
        const job_id = stringParam(params.object, "jobId") orelse return failure(writer, id, "INVALID_REQUEST", "jobId is required");
        const directory = try jobsDirectory(allocator, environ);
        defer allocator.free(directory);
        var loaded = download_jobs.load(allocator, io, directory, job_id) catch return success(writer, id, .{ .cancelled = false });
        defer loaded.deinit();
        if (loaded.value().state == .completed or loaded.value().state == .failed or loaded.value().state == .cancelled)
            return success(writer, id, .{ .cancelled = false });
        try download_jobs.requestCancel(allocator, io, directory, job_id);
        if (loaded.value().state == .queued) {
            loaded.value().state = .cancelled;
            loaded.value().updatedAt = std.Io.Clock.real.now(io).toSeconds();
            try download_jobs.save(allocator, io, directory, loaded.value().*);
            if (runtime.database) |database| mirrorDownload(database, io, loaded.value().*) catch {};
            runtime.download_mirror_fingerprint = null;
        }
        try event(writer, "download.state", .{ .jobId = job_id, .state = "cancelled" });
        return success(writer, id, .{ .cancelled = true });
    }
    return failure(writer, id, "METHOD_NOT_FOUND", "unknown RPC method");
}

test "RPC health response echoes opaque id" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var runtime: Runtime = .{};
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"opaque-42\",\"method\":\"health\"}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"opaque-42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ok\":true") != null);
}

test "RPC rejects missing and empty ids" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var runtime: Runtime = .{};
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"\",\"method\":\"health\"}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "INVALID_REQUEST") != null);
}

test "download startup claim has a bounded duplicate-spawn grace period" {
    try std.testing.expect(countsAsActive(100, 95, null, false));
    try std.testing.expect(!countsAsActive(100, 90, null, false));
    try std.testing.expect(countsAsActive(100, 1, 42, true));
    try std.testing.expect(!countsAsActive(100, 99, 42, false));
}

test "RPC rejects unknown envelope fields" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var runtime: Runtime = .{};
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"x\",\"method\":\"health\",\"secret\":true}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "INVALID_REQUEST") != null);
}

test "library refresh defaults to the primary account without touching network when absent" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var runtime: Runtime = .{};
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"refresh-1\",\"method\":\"library.refresh\",\"params\":{}}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ok\":false") != null);
}

test "RPC starts browser authorization without exposing PKCE verifier" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var runtime: Runtime = .{};
    defer if (runtime.pending_login) |*pending| pending.deinit(std.testing.allocator);
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"auth-1\",\"method\":\"auth.start\",\"params\":{\"profile\":\"native-test\",\"countryCode\":\"ca\"}}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "https://www.amazon.ca/ap/signin?") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), &runtime.pending_login.?.verifier) == null);
}

test "RPC refuses completion before consuming a one-time authorization code" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var runtime: Runtime = .{};
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"auth-2\",\"method\":\"auth.complete\",\"params\":{\"callbackUrl\":\"sensitive-placeholder\"}}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "INTERACTIVE_REQUIRED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sensitive-placeholder") == null);
}

test "profile status reports the selected durable profile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const database_path = try std.fs.path.join(std.testing.allocator, &.{ buffer[0..length], "rpc.db" });
    defer std.testing.allocator.free(database_path);
    var database = try database_mod.Database.open(std.testing.allocator, std.testing.io, database_path);
    defer database.deinit();
    try database.setSelectedProfile("durable-reader");
    var runtime: Runtime = .{ .database = &database };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"profile-status\",\"method\":\"profile.status\"}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"selectedProfile\":\"durable-reader\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"sqlite\":true") != null);
}

test "local profile removal requires explicit confirmation" {
    var runtime: Runtime = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try handleLine(std.testing.allocator, std.testing.io, .empty, &runtime, &out.writer, "{\"v\":1,\"id\":\"profile-remove\",\"method\":\"profile.remove\",\"params\":{\"profile\":\"reader\",\"confirm\":false}}");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "CONFIRMATION_REQUIRED") != null);
}

test "player title is derived from local media basename" {
    const title = try titleFromPath(std.testing.allocator, "/a/library/The Clockwork Library.m4b");
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("The Clockwork Library", title);
}
