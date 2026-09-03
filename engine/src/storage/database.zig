const std = @import("std");

pub const Error = error{ SqliteFailure, MigrationFailed, InvalidText };

pub const PlaybackPosition = struct {
    position_seconds: f64,
    duration_seconds: f64,
};

pub const DownloadJob = struct {
    id: []const u8,
    profile: []const u8,
    asin: []const u8,
    title: []const u8,
    kind: []const u8,
    destination: []const u8,
    status: []const u8,
    bytes_downloaded: u64 = 0,
    total_bytes: ?u64 = null,
    error_message: ?[]const u8 = null,
    created_at: i64,
    updated_at: i64,
};

pub const Bookmark = struct {
    id: i64,
    position_seconds: f64,
    label: ?[]u8,

    pub fn deinit(self: Bookmark, allocator: std.mem.Allocator) void {
        if (self.label) |label| allocator.free(label);
    }
};

const migrations = [_][]const u8{
    \\CREATE TABLE profiles (
    \\ id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, marketplace TEXT, locale TEXT,
    \\ is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0,1)),
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()), updated_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE UNIQUE INDEX profiles_one_default ON profiles(is_default) WHERE is_default=1;
    \\CREATE TABLE library_items (
    \\ profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, asin TEXT NOT NULL,
    \\ title TEXT NOT NULL, subtitle TEXT, authors_json TEXT NOT NULL DEFAULT '[]',
    \\ narrators_json TEXT NOT NULL DEFAULT '[]', cover_url TEXT, duration_seconds INTEGER,
    \\ release_date TEXT, metadata_json TEXT, updated_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ PRIMARY KEY(profile_id, asin)
    \\);
    \\CREATE INDEX library_items_title ON library_items(title COLLATE NOCASE);
    \\CREATE TABLE local_files (
    \\ id INTEGER PRIMARY KEY, profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    \\ asin TEXT NOT NULL, kind TEXT NOT NULL, path TEXT NOT NULL UNIQUE, size_bytes INTEGER,
    \\ checksum TEXT, completed_at INTEGER,
    \\ FOREIGN KEY(profile_id,asin) REFERENCES library_items(profile_id,asin) ON DELETE CASCADE
    \\);
    \\CREATE TABLE download_jobs (
    \\ id TEXT PRIMARY KEY, profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    \\ asin TEXT NOT NULL, kind TEXT NOT NULL, destination TEXT NOT NULL,
    \\ status TEXT NOT NULL CHECK(status IN ('queued','running','paused','completed','failed','cancelled')),
    \\ bytes_downloaded INTEGER NOT NULL DEFAULT 0 CHECK(bytes_downloaded>=0), total_bytes INTEGER,
    \\ etag TEXT, last_modified TEXT, error_message TEXT,
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()), updated_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ FOREIGN KEY(profile_id,asin) REFERENCES library_items(profile_id,asin) ON DELETE CASCADE
    \\);
    \\CREATE INDEX download_jobs_status ON download_jobs(status,updated_at);
    \\CREATE TABLE playback_positions (
    \\ profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, asin TEXT NOT NULL,
    \\ position_seconds REAL NOT NULL DEFAULT 0 CHECK(position_seconds>=0), duration_seconds REAL,
    \\ updated_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(profile_id,asin),
    \\ FOREIGN KEY(profile_id,asin) REFERENCES library_items(profile_id,asin) ON DELETE CASCADE
    \\);
    \\CREATE TABLE bookmarks (
    \\ id INTEGER PRIMARY KEY, profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    \\ asin TEXT NOT NULL, position_seconds REAL NOT NULL CHECK(position_seconds>=0), label TEXT,
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ FOREIGN KEY(profile_id,asin) REFERENCES library_items(profile_id,asin) ON DELETE CASCADE
    \\);
    \\CREATE INDEX bookmarks_item_position ON bookmarks(profile_id,asin,position_seconds);
    \\CREATE TABLE settings (
    \\ key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
};

/// SQLite is invoked with an argument vector, never through a shell. This
/// avoids a Zig 0.16/GCC 16 link incompatibility while preserving SQLite's
/// transactional and prepared-statement-backed execution. The sqlite3 program
/// is a runtime dependency.
pub const Database = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Database {
        var database = Database{ .allocator = allocator, .io = io, .path = try allocator.dupe(u8, path) };
        errdefer allocator.free(database.path);
        try database.migrate();
        return database;
    }

    pub fn deinit(self: *Database) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Execute trusted application SQL. User values must be quoted first.
    pub fn execute(self: *Database, sql: []const u8) !void {
        const output = try self.run(sql);
        self.allocator.free(output);
    }

    pub fn putSetting(self: *Database, key: []const u8, value: []const u8) !void {
        const quoted_key = try quoteText(self.allocator, key);
        defer self.allocator.free(quoted_key);
        const quoted_value = try quoteText(self.allocator, value);
        defer self.allocator.free(quoted_value);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; INSERT INTO settings(key,value,updated_at) VALUES({s},{s},unixepoch()) " ++
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at; COMMIT;",
            .{ quoted_key, quoted_value },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn getSetting(self: *Database, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const quoted_key = try quoteText(self.allocator, key);
        defer self.allocator.free(quoted_key);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT hex(value) FROM settings WHERE key={s};", .{quoted_key});
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        const hex = std.mem.trim(u8, output, "\r\n");
        if (hex.len == 0) return null;
        if (hex.len % 2 != 0) return error.SqliteFailure;
        const value = try allocator.alloc(u8, hex.len / 2);
        errdefer allocator.free(value);
        _ = std.fmt.hexToBytes(value, hex) catch return error.SqliteFailure;
        return value;
    }

    pub fn putProfile(self: *Database, name: []const u8, marketplace: ?[]const u8, locale: ?[]const u8) !void {
        const q_name = try quoteText(self.allocator, name);
        defer self.allocator.free(q_name);
        const q_marketplace = try quoteOptionalText(self.allocator, marketplace);
        defer self.allocator.free(q_marketplace);
        const q_locale = try quoteOptionalText(self.allocator, locale);
        defer self.allocator.free(q_locale);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO profiles(name,marketplace,locale,updated_at) VALUES({s},{s},{s},unixepoch()) " ++
                "ON CONFLICT(name) DO UPDATE SET marketplace=COALESCE(excluded.marketplace,profiles.marketplace)," ++
                "locale=COALESCE(excluded.locale,profiles.locale),updated_at=excluded.updated_at;",
            .{ q_name, q_marketplace, q_locale },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn setSelectedProfile(self: *Database, name: []const u8) !void {
        try self.putProfile(name, null, null);
        const q_name = try quoteText(self.allocator, name);
        defer self.allocator.free(q_name);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; UPDATE profiles SET is_default=0 WHERE is_default=1; " ++
                "UPDATE profiles SET is_default=1,updated_at=unixepoch() WHERE name={s}; COMMIT;",
            .{q_name},
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
        try self.putSetting("profile.selected", name);
    }

    pub fn getSelectedProfile(self: *Database, allocator: std.mem.Allocator) !?[]u8 {
        const output = try self.run("SELECT hex(name) FROM profiles WHERE is_default=1 LIMIT 1;");
        defer self.allocator.free(output);
        const hex = std.mem.trim(u8, output, "\r\n");
        if (hex.len == 0) return self.getSetting(allocator, "profile.selected");
        if (hex.len % 2 != 0) return error.SqliteFailure;
        const value = try allocator.alloc(u8, hex.len / 2);
        errdefer allocator.free(value);
        _ = std.fmt.hexToBytes(value, hex) catch return error.SqliteFailure;
        return value;
    }

    pub fn removeProfileState(self: *Database, name: []const u8) !void {
        const q_name = try quoteText(self.allocator, name);
        defer self.allocator.free(q_name);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; DELETE FROM profiles WHERE name={s}; " ++
                "DELETE FROM settings WHERE key='profile.selected' AND value={s}; COMMIT;",
            .{ q_name, q_name },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    /// Mirrors the durable JSON library cache into queryable SQLite state.
    /// The JSON cache remains the protocol compatibility source of truth.
    pub fn upsertLibraryItems(self: *Database, profile: []const u8, items: anytype) !void {
        try self.putProfile(profile, null, null);
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        var batch: std.Io.Writer.Allocating = .init(self.allocator);
        defer batch.deinit();
        try batch.writer.writeAll("BEGIN IMMEDIATE;");
        for (items) |item| {
            const q_asin = try quoteText(self.allocator, item.asin);
            defer self.allocator.free(q_asin);
            const q_title = try quoteText(self.allocator, item.title);
            defer self.allocator.free(q_title);
            const q_authors = try quoteJson(self.allocator, item.authors);
            defer self.allocator.free(q_authors);
            const q_narrators = try quoteJson(self.allocator, item.narrators);
            defer self.allocator.free(q_narrators);
            const q_cover = try quoteOptionalText(self.allocator, item.coverUrl);
            defer self.allocator.free(q_cover);
            const q_release = try quoteOptionalText(self.allocator, item.releaseDate);
            defer self.allocator.free(q_release);
            const q_metadata = try quoteJson(self.allocator, item);
            defer self.allocator.free(q_metadata);
            try batch.writer.print(
                "INSERT INTO library_items(profile_id,asin,title,authors_json,narrators_json,cover_url,duration_seconds,release_date,metadata_json,updated_at) " ++
                    "VALUES((SELECT id FROM profiles WHERE name={s}),{s},{s},{s},{s},{s},{d},{s},{s},unixepoch()) " ++
                    "ON CONFLICT(profile_id,asin) DO UPDATE SET title=excluded.title,authors_json=excluded.authors_json," ++
                    "narrators_json=excluded.narrators_json,cover_url=excluded.cover_url,duration_seconds=excluded.duration_seconds," ++
                    "release_date=excluded.release_date,metadata_json=excluded.metadata_json,updated_at=excluded.updated_at;",
                .{ q_profile, q_asin, q_title, q_authors, q_narrators, q_cover, @as(i64, @intFromFloat(@max(0, item.durationSeconds))), q_release, q_metadata },
            );
        }
        try batch.writer.writeAll("COMMIT;");
        try self.execute(batch.written());
        for (items) |item| if (item.downloaded and item.localPath != null) {
            try self.putLocalFile(profile, item.asin, item.title, "audio", item.localPath.?, null, null);
        };
    }

    pub fn putLocalFile(self: *Database, profile: []const u8, asin: []const u8, title: []const u8, kind: []const u8, path: []const u8, size_bytes: ?u64, checksum: ?[]const u8) !void {
        try self.putProfile(profile, null, null);
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const q_asin = try quoteText(self.allocator, asin);
        defer self.allocator.free(q_asin);
        const q_title = try quoteText(self.allocator, title);
        defer self.allocator.free(q_title);
        const q_kind = try quoteText(self.allocator, kind);
        defer self.allocator.free(q_kind);
        const q_path = try quoteText(self.allocator, path);
        defer self.allocator.free(q_path);
        const q_checksum = try quoteOptionalText(self.allocator, checksum);
        defer self.allocator.free(q_checksum);
        const size = if (size_bytes) |value| try std.fmt.allocPrint(self.allocator, "{d}", .{value}) else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(size);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; INSERT INTO library_items(profile_id,asin,title) " ++
                "VALUES((SELECT id FROM profiles WHERE name={s}),{s},{s}) ON CONFLICT(profile_id,asin) DO UPDATE SET title=excluded.title; " ++
                "INSERT INTO local_files(profile_id,asin,kind,path,size_bytes,checksum,completed_at) " ++
                "VALUES((SELECT id FROM profiles WHERE name={s}),{s},{s},{s},{s},{s},unixepoch()) " ++
                "ON CONFLICT(path) DO UPDATE SET profile_id=excluded.profile_id,asin=excluded.asin,kind=excluded.kind," ++
                "size_bytes=excluded.size_bytes,checksum=excluded.checksum,completed_at=excluded.completed_at; COMMIT;",
            .{ q_profile, q_asin, q_title, q_profile, q_asin, q_kind, q_path, size, q_checksum },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putDownloadJob(self: *Database, job: DownloadJob) !void {
        try self.putProfile(job.profile, null, null);
        const q_id = try quoteText(self.allocator, job.id);
        defer self.allocator.free(q_id);
        const q_profile = try quoteText(self.allocator, job.profile);
        defer self.allocator.free(q_profile);
        const q_asin = try quoteText(self.allocator, job.asin);
        defer self.allocator.free(q_asin);
        const q_title = try quoteText(self.allocator, job.title);
        defer self.allocator.free(q_title);
        const q_kind = try quoteText(self.allocator, job.kind);
        defer self.allocator.free(q_kind);
        const q_destination = try quoteText(self.allocator, job.destination);
        defer self.allocator.free(q_destination);
        const q_status = try quoteText(self.allocator, job.status);
        defer self.allocator.free(q_status);
        const q_error = try quoteOptionalText(self.allocator, job.error_message);
        defer self.allocator.free(q_error);
        const total = if (job.total_bytes) |value| try std.fmt.allocPrint(self.allocator, "{d}", .{value}) else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(total);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; INSERT INTO library_items(profile_id,asin,title) " ++
                "VALUES((SELECT id FROM profiles WHERE name={s}),{s},{s}) ON CONFLICT(profile_id,asin) DO UPDATE SET title=excluded.title; " ++
                "INSERT INTO download_jobs(id,profile_id,asin,kind,destination,status,bytes_downloaded,total_bytes,error_message,created_at,updated_at) " ++
                "VALUES({s},(SELECT id FROM profiles WHERE name={s}),{s},{s},{s},{s},{d},{s},{s},{d},{d}) " ++
                "ON CONFLICT(id) DO UPDATE SET profile_id=excluded.profile_id,asin=excluded.asin,kind=excluded.kind," ++
                "destination=excluded.destination,status=excluded.status,bytes_downloaded=excluded.bytes_downloaded," ++
                "total_bytes=excluded.total_bytes,error_message=excluded.error_message,updated_at=excluded.updated_at; COMMIT;",
            .{ q_profile, q_asin, q_title, q_id, q_profile, q_asin, q_kind, q_destination, q_status, job.bytes_downloaded, total, q_error, job.created_at, job.updated_at },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putPlaybackPosition(self: *Database, profile: []const u8, asin: []const u8, title: []const u8, position: f64, duration: f64) !void {
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const q_asin = try quoteText(self.allocator, asin);
        defer self.allocator.free(q_asin);
        const q_title = try quoteText(self.allocator, title);
        defer self.allocator.free(q_title);
        const sql = try std.fmt.allocPrint(self.allocator, "BEGIN IMMEDIATE; " ++
            "INSERT INTO profiles(name) VALUES({s}) ON CONFLICT(name) DO NOTHING; " ++
            "INSERT INTO library_items(profile_id,asin,title) VALUES((SELECT id FROM profiles WHERE name={s}),{s},{s}) " ++
            "ON CONFLICT(profile_id,asin) DO UPDATE SET title=excluded.title; " ++
            "INSERT INTO playback_positions(profile_id,asin,position_seconds,duration_seconds,updated_at) " ++
            "VALUES((SELECT id FROM profiles WHERE name={s}),{s},{d},{d},unixepoch()) " ++
            "ON CONFLICT(profile_id,asin) DO UPDATE SET position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,updated_at=excluded.updated_at; COMMIT;", .{ q_profile, q_profile, q_asin, q_title, q_profile, q_asin, @max(0, position), @max(0, duration) });
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn getPlaybackPosition(self: *Database, profile: []const u8, asin: []const u8) !?PlaybackPosition {
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const q_asin = try quoteText(self.allocator, asin);
        defer self.allocator.free(q_asin);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT position_seconds,COALESCE(duration_seconds,0) FROM playback_positions " ++
            "WHERE profile_id=(SELECT id FROM profiles WHERE name={s}) AND asin={s};", .{ q_profile, q_asin });
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        const row = std.mem.trim(u8, output, "\r\n");
        if (row.len == 0) return null;
        var fields = std.mem.splitScalar(u8, row, '|');
        const position = std.fmt.parseFloat(f64, fields.next() orelse return error.SqliteFailure) catch return error.SqliteFailure;
        const duration = std.fmt.parseFloat(f64, fields.next() orelse return error.SqliteFailure) catch return error.SqliteFailure;
        return .{ .position_seconds = position, .duration_seconds = duration };
    }

    pub fn addBookmark(self: *Database, profile: []const u8, asin: []const u8, title: []const u8, position: f64, label: ?[]const u8) !i64 {
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const q_asin = try quoteText(self.allocator, asin);
        defer self.allocator.free(q_asin);
        const q_title = try quoteText(self.allocator, title);
        defer self.allocator.free(q_title);
        const q_label = if (label) |value| try quoteText(self.allocator, value) else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(q_label);
        const sql = try std.fmt.allocPrint(self.allocator, "BEGIN IMMEDIATE; " ++
            "INSERT INTO profiles(name) VALUES({s}) ON CONFLICT(name) DO NOTHING; " ++
            "INSERT INTO library_items(profile_id,asin,title) VALUES((SELECT id FROM profiles WHERE name={s}),{s},{s}) " ++
            "ON CONFLICT(profile_id,asin) DO UPDATE SET title=excluded.title; " ++
            "INSERT INTO bookmarks(profile_id,asin,position_seconds,label) VALUES((SELECT id FROM profiles WHERE name={s}),{s},{d},{s}); " ++
            "SELECT last_insert_rowid(); COMMIT;", .{ q_profile, q_profile, q_asin, q_title, q_profile, q_asin, @max(0, position), q_label });
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        return std.fmt.parseInt(i64, std.mem.trim(u8, output, "\r\n"), 10) catch error.SqliteFailure;
    }

    pub fn deleteBookmark(self: *Database, profile: []const u8, id: i64) !void {
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM bookmarks WHERE id={d} AND profile_id=(SELECT id FROM profiles WHERE name={s});", .{ id, q_profile });
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn listBookmarks(self: *Database, allocator: std.mem.Allocator, profile: []const u8, asin: []const u8) ![]Bookmark {
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const q_asin = try quoteText(self.allocator, asin);
        defer self.allocator.free(q_asin);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT id,position_seconds,hex(COALESCE(label,'')),label IS NOT NULL FROM bookmarks " ++
            "WHERE profile_id=(SELECT id FROM profiles WHERE name={s}) AND asin={s} ORDER BY position_seconds,id;", .{ q_profile, q_asin });
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        var result: std.ArrayList(Bookmark) = .empty;
        errdefer {
            for (result.items) |bookmark| bookmark.deinit(allocator);
            result.deinit(allocator);
        }
        var lines = std.mem.tokenizeAny(u8, output, "\r\n");
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '|');
            const id = std.fmt.parseInt(i64, fields.next() orelse return error.SqliteFailure, 10) catch return error.SqliteFailure;
            const position = std.fmt.parseFloat(f64, fields.next() orelse return error.SqliteFailure) catch return error.SqliteFailure;
            const label_hex = fields.next() orelse return error.SqliteFailure;
            const has_label = std.mem.eql(u8, fields.next() orelse return error.SqliteFailure, "1");
            var label: ?[]u8 = null;
            if (has_label) {
                if (label_hex.len % 2 != 0) return error.SqliteFailure;
                label = try allocator.alloc(u8, label_hex.len / 2);
                _ = std.fmt.hexToBytes(label.?, label_hex) catch return error.SqliteFailure;
            }
            try result.append(allocator, .{ .id = id, .position_seconds = position, .label = label });
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn migrationVersion(self: *Database) !u32 {
        const output = try self.run("SELECT COALESCE(MAX(version),0) FROM schema_migrations;");
        defer self.allocator.free(output);
        return std.fmt.parseInt(u32, std.mem.trim(u8, output, "\r\n"), 10) catch error.SqliteFailure;
    }

    fn migrate(self: *Database) !void {
        // DELETE + FULL is conservative and crash-safe. WAL remains off until
        // supported local and network filesystems are validated.
        try self.execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL DEFAULT(unixepoch()));");
        const current = try self.migrationVersion();
        if (current > migrations.len) return error.MigrationFailed;
        for (migrations[current..], current + 1..) |migration, version| {
            const sql = try std.fmt.allocPrint(
                self.allocator,
                "PRAGMA foreign_keys=ON; BEGIN IMMEDIATE; {s} INSERT INTO schema_migrations(version) VALUES({d}); COMMIT;",
                .{ migration, version },
            );
            defer self.allocator.free(sql);
            try self.execute(sql);
        }
    }

    fn run(self: *Database, sql: []const u8) ![]u8 {
        // sqlite3 is spawned per operation, so connection-scoped safety
        // pragmas must be enabled for every invocation (not only migration).
        const guarded_sql = try std.fmt.allocPrint(self.allocator, "PRAGMA foreign_keys=ON; {s}", .{sql});
        defer self.allocator.free(guarded_sql);
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "sqlite3", "-batch", "-bail", self.path, guarded_sql },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                self.allocator.free(result.stdout);
                return error.SqliteFailure;
            },
            else => {
                self.allocator.free(result.stdout);
                return error.SqliteFailure;
            },
        }
        return result.stdout;
    }
};

fn quoteText(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (value) |byte| {
        try quoted.append(allocator, byte);
        if (byte == '\'') try quoted.append(allocator, '\'');
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn quoteOptionalText(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    return if (value) |present| quoteText(allocator, present) else allocator.dupe(u8, "NULL");
}

fn quoteJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(value, .{}, &encoded.writer);
    return quoteText(allocator, encoded.written());
}

fn openTestDatabase(tmp: *std.testing.TmpDir) !Database {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ buffer[0..length], "state.db" });
    defer std.testing.allocator.free(path);
    return Database.open(std.testing.allocator, std.testing.io, path);
}

test "migrations create every non-secret state table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try openTestDatabase(&tmp);
    defer database.deinit();
    try std.testing.expectEqual(@as(u32, migrations.len), try database.migrationVersion());
    const output = try database.run("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('schema_migrations','profiles','library_items','local_files','download_jobs','playback_positions','bookmarks','settings');");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("8\n", output);
}

test "reopening an existing database preserves data and does not replay migrations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ buffer[0..length], "upgrade.db" });
    defer std.testing.allocator.free(path);

    {
        var original = try Database.open(std.testing.allocator, std.testing.io, path);
        defer original.deinit();
        try original.putSetting("upgrade-sentinel", "preserved");
    }
    {
        var reopened = try Database.open(std.testing.allocator, std.testing.io, path);
        defer reopened.deinit();
        try std.testing.expectEqual(@as(u32, migrations.len), try reopened.migrationVersion());
        const value = (try reopened.getSetting(std.testing.allocator, "upgrade-sentinel")).?;
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings("preserved", value);
        const applied = try reopened.run("SELECT count(*) FROM schema_migrations;");
        defer std.testing.allocator.free(applied);
        try std.testing.expectEqualStrings("1\n", applied);
    }
}

test "setting writes are transactional, escaped, and replaceable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try openTestDatabase(&tmp);
    defer database.deinit();
    try database.putSetting("theme'name", "dark'value");
    try database.putSetting("theme'name", "light'value");
    const value = (try database.getSetting(std.testing.allocator, "theme'name")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("light'value", value);
}

test "explicit transaction rollback does not persist state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try openTestDatabase(&tmp);
    defer database.deinit();
    try database.execute("BEGIN IMMEDIATE; INSERT INTO settings(key,value) VALUES('temporary','value'); ROLLBACK;");
    try std.testing.expectEqual(@as(?[]u8, null), try database.getSetting(std.testing.allocator, "temporary"));
}

test "playback positions and bookmarks persist per profile and title" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try openTestDatabase(&tmp);
    defer database.deinit();

    try database.putPlaybackPosition("reader", "B00TEST001", "Book's title", 123.5, 600);
    const saved = (try database.getPlaybackPosition("reader", "B00TEST001")).?;
    try std.testing.expectApproxEqAbs(@as(f64, 123.5), saved.position_seconds, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 600), saved.duration_seconds, 0.001);

    const first = try database.addBookmark("reader", "B00TEST001", "Book's title", 90, "good | part\nnext");
    _ = try database.addBookmark("reader", "B00TEST001", "Book's title", 30, null);
    const bookmarks = try database.listBookmarks(std.testing.allocator, "reader", "B00TEST001");
    defer {
        for (bookmarks) |bookmark| bookmark.deinit(std.testing.allocator);
        std.testing.allocator.free(bookmarks);
    }
    try std.testing.expectEqual(@as(usize, 2), bookmarks.len);
    try std.testing.expectApproxEqAbs(@as(f64, 30), bookmarks[0].position_seconds, 0.001);
    try std.testing.expectEqualStrings("good | part\nnext", bookmarks[1].label.?);
    try database.deleteBookmark("reader", first);
    const remaining = try database.listBookmarks(std.testing.allocator, "reader", "B00TEST001");
    defer {
        for (remaining) |bookmark| bookmark.deinit(std.testing.allocator);
        std.testing.allocator.free(remaining);
    }
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
}

test "profiles library files jobs and selected profile are durably mirrored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try openTestDatabase(&tmp);
    defer database.deinit();

    try database.putProfile("reader's profile", "audible.ca", "ca");
    try database.setSelectedProfile("reader's profile");
    const selected = (try database.getSelectedProfile(std.testing.allocator)).?;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("reader's profile", selected);

    const Item = struct {
        asin: []const u8,
        title: []const u8,
        authors: []const []const u8,
        narrators: []const []const u8,
        coverUrl: ?[]const u8,
        releaseDate: ?[]const u8,
        durationSeconds: f64,
        downloaded: bool,
        localPath: ?[]const u8,
    };
    const items = [_]Item{.{
        .asin = "B00DB00001",
        .title = "Durable | Book",
        .authors = &.{"A. Writer"},
        .narrators = &.{"A. Voice"},
        .coverUrl = "https://example.invalid/cover.jpg",
        .releaseDate = "2026-09-03",
        .durationSeconds = 123.9,
        .downloaded = true,
        .localPath = "/tmp/Durable Book.aaxc",
    }};
    try database.upsertLibraryItems("reader's profile", &items);
    try database.putLocalFile("reader's profile", "B00DB00001", "Durable | Book", "cover", "/tmp/cover's.jpg", 42, "sha256:test");
    try database.putDownloadJob(.{
        .id = "job|1",
        .profile = "reader's profile",
        .asin = "B00DB00001",
        .title = "Durable | Book",
        .kind = "audible",
        .destination = "/tmp/Durable Book.aaxc",
        .status = "running",
        .bytes_downloaded = 64,
        .total_bytes = 128,
        .created_at = 10,
        .updated_at = 20,
    });
    try database.putDownloadJob(.{
        .id = "job|1",
        .profile = "reader's profile",
        .asin = "B00DB00001",
        .title = "Durable | Book",
        .kind = "audible",
        .destination = "/tmp/Durable Book.aaxc",
        .status = "completed",
        .bytes_downloaded = 128,
        .total_bytes = 128,
        .created_at = 10,
        .updated_at = 30,
    });

    const counts = try database.run("SELECT (SELECT count(*) FROM profiles)||'|'||(SELECT count(*) FROM library_items)||'|'||(SELECT count(*) FROM local_files)||'|'||(SELECT count(*) FROM download_jobs);");
    defer std.testing.allocator.free(counts);
    try std.testing.expectEqualStrings("1|1|2|1\n", counts);
    const job = try database.run("SELECT status||'|'||bytes_downloaded||'|'||total_bytes FROM download_jobs WHERE id='job|1';");
    defer std.testing.allocator.free(job);
    try std.testing.expectEqualStrings("completed|128|128\n", job);

    try database.removeProfileState("reader's profile");
    try std.testing.expectEqual(@as(?[]u8, null), try database.getSelectedProfile(std.testing.allocator));
    const empty = try database.run("SELECT (SELECT count(*) FROM library_items)||'|'||(SELECT count(*) FROM local_files)||'|'||(SELECT count(*) FROM download_jobs);");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("0|0|0\n", empty);
}
