const std = @import("std");
const provider_model = @import("../providers/model.zig");

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

pub const ProviderDownloadJob = struct {
    id: []const u8,
    account: provider_model.AccountIdentity,
    item_id: []const u8,
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

pub const OwnedAccountIdentity = struct {
    provider_id: []u8,
    account_id: []u8,

    pub fn deinit(self: OwnedAccountIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.account_id);
    }
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
    ,
    \\CREATE TABLE providers (
    \\ id TEXT PRIMARY KEY, display_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()), updated_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE TABLE provider_accounts (
    \\ provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE, account_id TEXT NOT NULL,
    \\ display_name TEXT NOT NULL, marketplace TEXT, locale TEXT, metadata_json TEXT,
    \\ is_default INTEGER NOT NULL DEFAULT 0 CHECK(is_default IN (0,1)),
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()), updated_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ PRIMARY KEY(provider_id,account_id)
    \\);
    \\CREATE UNIQUE INDEX provider_accounts_one_default ON provider_accounts(is_default) WHERE is_default=1;
    \\CREATE TABLE provider_items (
    \\ provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE, item_id TEXT NOT NULL,
    \\ title TEXT NOT NULL, subtitle TEXT, creators_json TEXT NOT NULL DEFAULT '[]',
    \\ narrators_json TEXT NOT NULL DEFAULT '[]', cover_url TEXT, duration_seconds INTEGER,
    \\ release_date TEXT, metadata_json TEXT, updated_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ PRIMARY KEY(provider_id,item_id)
    \\);
    \\CREATE INDEX provider_items_title ON provider_items(provider_id,title COLLATE NOCASE);
    \\CREATE TABLE account_library_items (
    \\ provider_id TEXT NOT NULL, account_id TEXT NOT NULL, item_id TEXT NOT NULL,
    \\ acquired_at INTEGER, updated_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ PRIMARY KEY(provider_id,account_id,item_id),
    \\ FOREIGN KEY(provider_id,account_id) REFERENCES provider_accounts(provider_id,account_id) ON DELETE CASCADE,
    \\ FOREIGN KEY(provider_id,item_id) REFERENCES provider_items(provider_id,item_id) ON DELETE CASCADE
    \\);
    \\CREATE TABLE provider_local_files (
    \\ id INTEGER PRIMARY KEY, provider_id TEXT NOT NULL, account_id TEXT NOT NULL, item_id TEXT NOT NULL,
    \\ kind TEXT NOT NULL, path TEXT NOT NULL UNIQUE, size_bytes INTEGER, checksum TEXT, completed_at INTEGER,
    \\ FOREIGN KEY(provider_id,account_id,item_id) REFERENCES account_library_items(provider_id,account_id,item_id) ON DELETE CASCADE
    \\);
    \\CREATE TABLE provider_download_jobs (
    \\ provider_id TEXT NOT NULL, id TEXT NOT NULL, account_id TEXT NOT NULL, item_id TEXT NOT NULL,
    \\ kind TEXT NOT NULL, destination TEXT NOT NULL,
    \\ status TEXT NOT NULL CHECK(status IN ('queued','running','paused','completed','failed','cancelled')),
    \\ bytes_downloaded INTEGER NOT NULL DEFAULT 0 CHECK(bytes_downloaded>=0), total_bytes INTEGER,
    \\ etag TEXT, last_modified TEXT, error_message TEXT,
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()), updated_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ PRIMARY KEY(provider_id,id),
    \\ FOREIGN KEY(provider_id,account_id,item_id) REFERENCES account_library_items(provider_id,account_id,item_id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX provider_download_jobs_status ON provider_download_jobs(provider_id,status,updated_at);
    \\CREATE TABLE provider_playback_positions (
    \\ provider_id TEXT NOT NULL, account_id TEXT NOT NULL, item_id TEXT NOT NULL,
    \\ position_seconds REAL NOT NULL DEFAULT 0 CHECK(position_seconds>=0), duration_seconds REAL,
    \\ updated_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(provider_id,account_id,item_id),
    \\ FOREIGN KEY(provider_id,account_id,item_id) REFERENCES account_library_items(provider_id,account_id,item_id) ON DELETE CASCADE
    \\);
    \\CREATE TABLE provider_bookmarks (
    \\ id INTEGER PRIMARY KEY, provider_id TEXT NOT NULL, account_id TEXT NOT NULL, item_id TEXT NOT NULL,
    \\ position_seconds REAL NOT NULL CHECK(position_seconds>=0), label TEXT,
    \\ created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\ FOREIGN KEY(provider_id,account_id,item_id) REFERENCES account_library_items(provider_id,account_id,item_id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX provider_bookmarks_item_position ON provider_bookmarks(provider_id,account_id,item_id,position_seconds);
    \\INSERT INTO providers(id,display_name) VALUES('audible','Audible');
    \\INSERT INTO provider_accounts(provider_id,account_id,display_name,marketplace,locale,is_default,created_at,updated_at)
    \\ SELECT 'audible',name,name,marketplace,locale,is_default,created_at,updated_at FROM profiles;
    \\INSERT INTO provider_items(provider_id,item_id,title,subtitle,creators_json,narrators_json,cover_url,duration_seconds,release_date,metadata_json,updated_at)
    \\ SELECT 'audible',asin,MAX(title),MAX(subtitle),MAX(authors_json),MAX(narrators_json),MAX(cover_url),MAX(duration_seconds),MAX(release_date),MAX(metadata_json),MAX(updated_at)
    \\ FROM library_items GROUP BY asin;
    \\INSERT INTO account_library_items(provider_id,account_id,item_id,updated_at)
    \\ SELECT 'audible',p.name,l.asin,l.updated_at FROM library_items l JOIN profiles p ON p.id=l.profile_id;
    \\INSERT INTO provider_local_files(id,provider_id,account_id,item_id,kind,path,size_bytes,checksum,completed_at)
    \\ SELECT f.id,'audible',p.name,f.asin,f.kind,f.path,f.size_bytes,f.checksum,f.completed_at FROM local_files f JOIN profiles p ON p.id=f.profile_id;
    \\INSERT INTO provider_download_jobs(provider_id,id,account_id,item_id,kind,destination,status,bytes_downloaded,total_bytes,etag,last_modified,error_message,created_at,updated_at)
    \\ SELECT 'audible',j.id,p.name,j.asin,j.kind,j.destination,j.status,j.bytes_downloaded,j.total_bytes,j.etag,j.last_modified,j.error_message,j.created_at,j.updated_at FROM download_jobs j JOIN profiles p ON p.id=j.profile_id;
    \\INSERT INTO provider_playback_positions(provider_id,account_id,item_id,position_seconds,duration_seconds,updated_at)
    \\ SELECT 'audible',p.name,x.asin,x.position_seconds,x.duration_seconds,x.updated_at FROM playback_positions x JOIN profiles p ON p.id=x.profile_id;
    \\INSERT INTO provider_bookmarks(id,provider_id,account_id,item_id,position_seconds,label,created_at)
    \\ SELECT b.id,'audible',p.name,b.asin,b.position_seconds,b.label,b.created_at FROM bookmarks b JOIN profiles p ON p.id=b.profile_id;
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

    pub fn putProvider(self: *Database, provider_id: []const u8, display_name: []const u8) !void {
        try provider_model.validateId(provider_id);
        const q_provider = try quoteText(self.allocator, provider_id);
        defer self.allocator.free(q_provider);
        const q_display = try quoteText(self.allocator, display_name);
        defer self.allocator.free(q_display);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO providers(id,display_name,updated_at) VALUES({s},{s},unixepoch()) " ++
                "ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,updated_at=excluded.updated_at;",
            .{ q_provider, q_display },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putAccount(self: *Database, account: provider_model.Account) !void {
        try account.identity.validate();
        const q_provider = try quoteText(self.allocator, account.identity.provider_id);
        defer self.allocator.free(q_provider);
        const q_provider_name = try quoteText(self.allocator, account.identity.provider_id);
        defer self.allocator.free(q_provider_name);
        const q_account = try quoteText(self.allocator, account.identity.account_id);
        defer self.allocator.free(q_account);
        const q_display = try quoteText(self.allocator, account.display_name);
        defer self.allocator.free(q_display);
        const q_marketplace = try quoteOptionalText(self.allocator, account.marketplace);
        defer self.allocator.free(q_marketplace);
        const q_locale = try quoteOptionalText(self.allocator, account.locale);
        defer self.allocator.free(q_locale);
        const q_metadata = try quoteOptionalText(self.allocator, account.metadata_json);
        defer self.allocator.free(q_metadata);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; INSERT INTO providers(id,display_name) VALUES({s},{s}) ON CONFLICT(id) DO NOTHING; " ++
                "INSERT INTO provider_accounts(provider_id,account_id,display_name,marketplace,locale,metadata_json,updated_at) " ++
                "VALUES({s},{s},{s},{s},{s},{s},unixepoch()) ON CONFLICT(provider_id,account_id) DO UPDATE SET " ++
                "display_name=excluded.display_name,marketplace=COALESCE(excluded.marketplace,provider_accounts.marketplace)," ++
                "locale=COALESCE(excluded.locale,provider_accounts.locale),metadata_json=COALESCE(excluded.metadata_json,provider_accounts.metadata_json),updated_at=excluded.updated_at; COMMIT;",
            .{ q_provider, q_provider_name, q_provider, q_account, q_display, q_marketplace, q_locale, q_metadata },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn setSelectedAccount(self: *Database, identity: provider_model.AccountIdentity) !void {
        try identity.validate();
        const q_provider = try quoteText(self.allocator, identity.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, identity.account_id);
        defer self.allocator.free(q_account);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; UPDATE provider_accounts SET is_default=0 WHERE is_default=1; " ++
                "UPDATE provider_accounts SET is_default=1,updated_at=unixepoch() WHERE provider_id={s} AND account_id={s}; COMMIT;",
            .{ q_provider, q_account },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
        try self.putSetting("account.selected.provider", identity.provider_id);
        try self.putSetting("account.selected.id", identity.account_id);
    }

    pub fn getSelectedAccount(self: *Database, allocator: std.mem.Allocator) !?OwnedAccountIdentity {
        const output = try self.run("SELECT hex(provider_id)||'|'||hex(account_id) FROM provider_accounts WHERE is_default=1 LIMIT 1;");
        defer self.allocator.free(output);
        const row = std.mem.trim(u8, output, "\r\n");
        if (row.len == 0) return null;
        var fields = std.mem.splitScalar(u8, row, '|');
        const provider_hex = fields.next() orelse return error.SqliteFailure;
        const account_hex = fields.next() orelse return error.SqliteFailure;
        const provider_id = try decodeHex(allocator, provider_hex);
        errdefer allocator.free(provider_id);
        return .{
            .provider_id = provider_id,
            .account_id = try decodeHex(allocator, account_hex),
        };
    }

    pub fn putProviderItem(self: *Database, account: provider_model.AccountIdentity, item: provider_model.LibraryItem) !void {
        try account.validate();
        try item.identity.validate();
        if (!std.mem.eql(u8, account.provider_id, item.identity.provider_id)) return error.InvalidProviderIdentity;
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item.identity.item_id);
        defer self.allocator.free(q_item);
        const q_title = try quoteText(self.allocator, item.title);
        defer self.allocator.free(q_title);
        const q_subtitle = try quoteOptionalText(self.allocator, item.subtitle);
        defer self.allocator.free(q_subtitle);
        const q_creators = try quoteText(self.allocator, item.creators_json);
        defer self.allocator.free(q_creators);
        const q_narrators = try quoteText(self.allocator, item.narrators_json);
        defer self.allocator.free(q_narrators);
        const q_cover = try quoteOptionalText(self.allocator, item.cover_url);
        defer self.allocator.free(q_cover);
        const q_release = try quoteOptionalText(self.allocator, item.release_date);
        defer self.allocator.free(q_release);
        const q_metadata = try quoteOptionalText(self.allocator, item.metadata_json);
        defer self.allocator.free(q_metadata);
        const duration = try sqlOptionalInteger(self.allocator, item.duration_seconds);
        defer self.allocator.free(duration);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; INSERT INTO provider_items(provider_id,item_id,title,subtitle,creators_json,narrators_json,cover_url,duration_seconds,release_date,metadata_json,updated_at) " ++
                "VALUES({s},{s},{s},{s},{s},{s},{s},{s},{s},{s},unixepoch()) ON CONFLICT(provider_id,item_id) DO UPDATE SET " ++
                "title=excluded.title,subtitle=excluded.subtitle,creators_json=excluded.creators_json,narrators_json=excluded.narrators_json," ++
                "cover_url=excluded.cover_url,duration_seconds=excluded.duration_seconds,release_date=excluded.release_date,metadata_json=excluded.metadata_json,updated_at=excluded.updated_at; " ++
                "INSERT INTO account_library_items(provider_id,account_id,item_id,updated_at) VALUES({s},{s},{s},unixepoch()) " ++
                "ON CONFLICT(provider_id,account_id,item_id) DO UPDATE SET updated_at=excluded.updated_at; COMMIT;",
            .{ q_provider, q_item, q_title, q_subtitle, q_creators, q_narrators, q_cover, duration, q_release, q_metadata, q_provider, q_account, q_item },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putProviderLocalFile(self: *Database, account: provider_model.AccountIdentity, item_id: []const u8, title: []const u8, kind: []const u8, path: []const u8, size_bytes: ?u64, checksum: ?[]const u8) !void {
        try self.ensureProviderItem(account, item_id, title);
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item_id);
        defer self.allocator.free(q_item);
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
            "INSERT INTO provider_local_files(provider_id,account_id,item_id,kind,path,size_bytes,checksum,completed_at) " ++
                "VALUES({s},{s},{s},{s},{s},{s},{s},unixepoch()) ON CONFLICT(path) DO UPDATE SET provider_id=excluded.provider_id," ++
                "account_id=excluded.account_id,item_id=excluded.item_id,kind=excluded.kind,size_bytes=excluded.size_bytes,checksum=excluded.checksum,completed_at=excluded.completed_at;",
            .{ q_provider, q_account, q_item, q_kind, q_path, size, q_checksum },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putProviderDownloadJob(self: *Database, job: ProviderDownloadJob) !void {
        try self.ensureProviderItem(job.account, job.item_id, job.title);
        const q_provider = try quoteText(self.allocator, job.account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, job.account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, job.item_id);
        defer self.allocator.free(q_item);
        const q_id = try quoteText(self.allocator, job.id);
        defer self.allocator.free(q_id);
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
            "INSERT INTO provider_download_jobs(provider_id,id,account_id,item_id,kind,destination,status,bytes_downloaded,total_bytes,error_message,created_at,updated_at) " ++
                "VALUES({s},{s},{s},{s},{s},{s},{s},{d},{s},{s},{d},{d}) ON CONFLICT(provider_id,id) DO UPDATE SET " ++
                "account_id=excluded.account_id,item_id=excluded.item_id,kind=excluded.kind,destination=excluded.destination,status=excluded.status," ++
                "bytes_downloaded=excluded.bytes_downloaded,total_bytes=excluded.total_bytes,error_message=excluded.error_message,updated_at=excluded.updated_at;",
            .{ q_provider, q_id, q_account, q_item, q_kind, q_destination, q_status, job.bytes_downloaded, total, q_error, job.created_at, job.updated_at },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putProviderPlaybackPosition(self: *Database, account: provider_model.AccountIdentity, item_id: []const u8, title: []const u8, position: f64, duration: f64) !void {
        try self.ensureProviderItem(account, item_id, title);
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item_id);
        defer self.allocator.free(q_item);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO provider_playback_positions(provider_id,account_id,item_id,position_seconds,duration_seconds,updated_at) " ++
                "VALUES({s},{s},{s},{d},{d},unixepoch()) ON CONFLICT(provider_id,account_id,item_id) DO UPDATE SET " ++
                "position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,updated_at=excluded.updated_at;",
            .{ q_provider, q_account, q_item, @max(0, position), @max(0, duration) },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn getProviderPlaybackPosition(self: *Database, account: provider_model.AccountIdentity, item_id: []const u8) !?PlaybackPosition {
        try account.validate();
        try provider_model.validateId(item_id);
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item_id);
        defer self.allocator.free(q_item);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT position_seconds,COALESCE(duration_seconds,0) FROM provider_playback_positions WHERE provider_id={s} AND account_id={s} AND item_id={s};",
            .{ q_provider, q_account, q_item },
        );
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        const row = std.mem.trim(u8, output, "\r\n");
        if (row.len == 0) return null;
        var fields = std.mem.splitScalar(u8, row, '|');
        return .{
            .position_seconds = std.fmt.parseFloat(f64, fields.next() orelse return error.SqliteFailure) catch return error.SqliteFailure,
            .duration_seconds = std.fmt.parseFloat(f64, fields.next() orelse return error.SqliteFailure) catch return error.SqliteFailure,
        };
    }

    pub fn addProviderBookmark(self: *Database, account: provider_model.AccountIdentity, item_id: []const u8, title: []const u8, position: f64, label: ?[]const u8) !i64 {
        try self.ensureProviderItem(account, item_id, title);
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item_id);
        defer self.allocator.free(q_item);
        const q_label = try quoteOptionalText(self.allocator, label);
        defer self.allocator.free(q_label);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO provider_bookmarks(provider_id,account_id,item_id,position_seconds,label) VALUES({s},{s},{s},{d},{s}); SELECT last_insert_rowid();",
            .{ q_provider, q_account, q_item, @max(0, position), q_label },
        );
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        return std.fmt.parseInt(i64, std.mem.trim(u8, output, "\r\n"), 10) catch error.SqliteFailure;
    }

    pub fn deleteProviderBookmark(self: *Database, account: provider_model.AccountIdentity, id: i64) !void {
        try account.validate();
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM provider_bookmarks WHERE id={d} AND provider_id={s} AND account_id={s};", .{ id, q_provider, q_account });
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn listProviderBookmarks(self: *Database, allocator: std.mem.Allocator, account: provider_model.AccountIdentity, item_id: []const u8) ![]Bookmark {
        try account.validate();
        try provider_model.validateId(item_id);
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item_id);
        defer self.allocator.free(q_item);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT id,position_seconds,hex(COALESCE(label,'')),label IS NOT NULL FROM provider_bookmarks " ++
                "WHERE provider_id={s} AND account_id={s} AND item_id={s} ORDER BY position_seconds,id;",
            .{ q_provider, q_account, q_item },
        );
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        return parseBookmarks(allocator, output);
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
        try self.putAccount(.{
            .identity = .{ .provider_id = provider_model.audible_id, .account_id = name },
            .display_name = name,
            .marketplace = marketplace,
            .locale = locale,
        });
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
        try self.setSelectedAccount(.{ .provider_id = provider_model.audible_id, .account_id = name });
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
            "BEGIN IMMEDIATE; DELETE FROM profiles WHERE name={s}; DELETE FROM provider_accounts WHERE provider_id='audible' AND account_id={s}; " ++
                "DELETE FROM settings WHERE key='profile.selected' AND value={s}; COMMIT;",
            .{ q_name, q_name, q_name },
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
            try batch.writer.print(
                "INSERT INTO provider_items(provider_id,item_id,title,creators_json,narrators_json,cover_url,duration_seconds,release_date,metadata_json,updated_at) " ++
                    "VALUES('audible',{s},{s},{s},{s},{s},{d},{s},{s},unixepoch()) ON CONFLICT(provider_id,item_id) DO UPDATE SET " ++
                    "title=excluded.title,creators_json=excluded.creators_json,narrators_json=excluded.narrators_json,cover_url=excluded.cover_url," ++
                    "duration_seconds=excluded.duration_seconds,release_date=excluded.release_date,metadata_json=excluded.metadata_json,updated_at=excluded.updated_at; " ++
                    "INSERT INTO account_library_items(provider_id,account_id,item_id,updated_at) VALUES('audible',{s},{s},unixepoch()) " ++
                    "ON CONFLICT(provider_id,account_id,item_id) DO UPDATE SET updated_at=excluded.updated_at;",
                .{ q_asin, q_title, q_authors, q_narrators, q_cover, @as(i64, @intFromFloat(@max(0, item.durationSeconds))), q_release, q_metadata, q_profile, q_asin },
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
                "size_bytes=excluded.size_bytes,checksum=excluded.checksum,completed_at=excluded.completed_at; " ++
                "INSERT INTO provider_items(provider_id,item_id,title) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,item_id) DO UPDATE SET title=excluded.title; " ++
                "INSERT INTO account_library_items(provider_id,account_id,item_id) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,account_id,item_id) DO NOTHING; " ++
                "INSERT INTO provider_local_files(provider_id,account_id,item_id,kind,path,size_bytes,checksum,completed_at) " ++
                "VALUES('audible',{s},{s},{s},{s},{s},{s},unixepoch()) ON CONFLICT(path) DO UPDATE SET provider_id=excluded.provider_id," ++
                "account_id=excluded.account_id,item_id=excluded.item_id,kind=excluded.kind,size_bytes=excluded.size_bytes,checksum=excluded.checksum,completed_at=excluded.completed_at; COMMIT;",
            .{ q_profile, q_asin, q_title, q_profile, q_asin, q_kind, q_path, size, q_checksum, q_asin, q_title, q_profile, q_asin, q_profile, q_asin, q_kind, q_path, size, q_checksum },
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
                "total_bytes=excluded.total_bytes,error_message=excluded.error_message,updated_at=excluded.updated_at; " ++
                "INSERT INTO provider_items(provider_id,item_id,title) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,item_id) DO UPDATE SET title=excluded.title; " ++
                "INSERT INTO account_library_items(provider_id,account_id,item_id) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,account_id,item_id) DO NOTHING; " ++
                "INSERT INTO provider_download_jobs(provider_id,id,account_id,item_id,kind,destination,status,bytes_downloaded,total_bytes,error_message,created_at,updated_at) " ++
                "VALUES('audible',{s},{s},{s},{s},{s},{s},{d},{s},{s},{d},{d}) ON CONFLICT(provider_id,id) DO UPDATE SET account_id=excluded.account_id," ++
                "item_id=excluded.item_id,kind=excluded.kind,destination=excluded.destination,status=excluded.status,bytes_downloaded=excluded.bytes_downloaded," ++
                "total_bytes=excluded.total_bytes,error_message=excluded.error_message,updated_at=excluded.updated_at; COMMIT;",
            .{ q_profile, q_asin, q_title, q_id, q_profile, q_asin, q_kind, q_destination, q_status, job.bytes_downloaded, total, q_error, job.created_at, job.updated_at, q_asin, q_title, q_profile, q_asin, q_id, q_profile, q_asin, q_kind, q_destination, q_status, job.bytes_downloaded, total, q_error, job.created_at, job.updated_at },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn putPlaybackPosition(self: *Database, profile: []const u8, asin: []const u8, title: []const u8, position: f64, duration: f64) !void {
        try self.putProfile(profile, null, null);
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
            "ON CONFLICT(profile_id,asin) DO UPDATE SET position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,updated_at=excluded.updated_at; " ++
            "INSERT INTO provider_items(provider_id,item_id,title) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,item_id) DO UPDATE SET title=excluded.title; " ++
            "INSERT INTO account_library_items(provider_id,account_id,item_id) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,account_id,item_id) DO NOTHING; " ++
            "INSERT INTO provider_playback_positions(provider_id,account_id,item_id,position_seconds,duration_seconds,updated_at) VALUES('audible',{s},{s},{d},{d},unixepoch()) " ++
            "ON CONFLICT(provider_id,account_id,item_id) DO UPDATE SET position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,updated_at=excluded.updated_at; COMMIT;", .{ q_profile, q_profile, q_asin, q_title, q_profile, q_asin, @max(0, position), @max(0, duration), q_asin, q_title, q_profile, q_asin, q_profile, q_asin, @max(0, position), @max(0, duration) });
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
        try self.putProfile(profile, null, null);
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
            "INSERT INTO provider_items(provider_id,item_id,title) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,item_id) DO UPDATE SET title=excluded.title; " ++
            "INSERT INTO account_library_items(provider_id,account_id,item_id) VALUES('audible',{s},{s}) ON CONFLICT(provider_id,account_id,item_id) DO NOTHING; " ++
            "INSERT INTO bookmarks(profile_id,asin,position_seconds,label) VALUES((SELECT id FROM profiles WHERE name={s}),{s},{d},{s}); " ++
            "INSERT INTO provider_bookmarks(id,provider_id,account_id,item_id,position_seconds,label) VALUES(last_insert_rowid(),'audible',{s},{s},{d},{s}); " ++
            "SELECT last_insert_rowid(); COMMIT;", .{ q_profile, q_profile, q_asin, q_title, q_asin, q_title, q_profile, q_asin, q_profile, q_asin, @max(0, position), q_label, q_profile, q_asin, @max(0, position), q_label });
        defer self.allocator.free(sql);
        const output = try self.run(sql);
        defer self.allocator.free(output);
        return std.fmt.parseInt(i64, std.mem.trim(u8, output, "\r\n"), 10) catch error.SqliteFailure;
    }

    pub fn deleteBookmark(self: *Database, profile: []const u8, id: i64) !void {
        const q_profile = try quoteText(self.allocator, profile);
        defer self.allocator.free(q_profile);
        const sql = try std.fmt.allocPrint(self.allocator, "BEGIN IMMEDIATE; DELETE FROM bookmarks WHERE id={d} AND profile_id=(SELECT id FROM profiles WHERE name={s}); DELETE FROM provider_bookmarks WHERE id={d} AND provider_id='audible' AND account_id={s}; COMMIT;", .{ id, q_profile, id, q_profile });
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
        return parseBookmarks(allocator, output);
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

    /// Ensures artifact/progress writes have a referentially valid item without
    /// erasing catalog metadata previously supplied by `putProviderItem`.
    fn ensureProviderItem(self: *Database, account: provider_model.AccountIdentity, item_id: []const u8, title: []const u8) !void {
        try account.validate();
        try provider_model.validateId(item_id);
        const q_provider = try quoteText(self.allocator, account.provider_id);
        defer self.allocator.free(q_provider);
        const q_account = try quoteText(self.allocator, account.account_id);
        defer self.allocator.free(q_account);
        const q_item = try quoteText(self.allocator, item_id);
        defer self.allocator.free(q_item);
        const q_title = try quoteText(self.allocator, title);
        defer self.allocator.free(q_title);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "BEGIN IMMEDIATE; INSERT INTO provider_items(provider_id,item_id,title,updated_at) VALUES({s},{s},{s},unixepoch()) " ++
                "ON CONFLICT(provider_id,item_id) DO UPDATE SET title=excluded.title,updated_at=excluded.updated_at; " ++
                "INSERT INTO account_library_items(provider_id,account_id,item_id,updated_at) VALUES({s},{s},{s},unixepoch()) " ++
                "ON CONFLICT(provider_id,account_id,item_id) DO UPDATE SET updated_at=excluded.updated_at; COMMIT;",
            .{ q_provider, q_item, q_title, q_provider, q_account, q_item },
        );
        defer self.allocator.free(sql);
        try self.execute(sql);
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

fn parseBookmarks(allocator: std.mem.Allocator, output: []const u8) ![]Bookmark {
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
        const label = if (has_label) try decodeHex(allocator, label_hex) else null;
        try result.append(allocator, .{ .id = id, .position_seconds = position, .label = label });
    }
    return result.toOwnedSlice(allocator);
}

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

fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.SqliteFailure;
    const value = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(value);
    _ = std.fmt.hexToBytes(value, hex) catch return error.SqliteFailure;
    return value;
}

fn sqlOptionalInteger(allocator: std.mem.Allocator, value: ?i64) ![]u8 {
    return if (value) |present| std.fmt.allocPrint(allocator, "{d}", .{present}) else allocator.dupe(u8, "NULL");
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
    const neutral = try database.run("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('providers','provider_accounts','provider_items','account_library_items','provider_local_files','provider_download_jobs','provider_playback_positions','provider_bookmarks');");
    defer std.testing.allocator.free(neutral);
    try std.testing.expectEqualStrings("8\n", neutral);
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
        try std.testing.expectEqualStrings("2\n", applied);
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

test "version one Audible state migrates into provider identities without data loss" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{ buffer[0..length], "legacy.db" });
    defer std.testing.allocator.free(path);
    var legacy = Database{ .allocator = std.testing.allocator, .io = std.testing.io, .path = try std.testing.allocator.dupe(u8, path) };
    {
        defer legacy.deinit();
        const bootstrap = try std.fmt.allocPrint(
            std.testing.allocator,
            "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL DEFAULT(unixepoch())); BEGIN IMMEDIATE; {s} INSERT INTO schema_migrations(version) VALUES(1); COMMIT;",
            .{migrations[0]},
        );
        defer std.testing.allocator.free(bootstrap);
        try legacy.execute(bootstrap);
        try legacy.execute(
            "BEGIN IMMEDIATE; " ++
                "INSERT INTO profiles(id,name,marketplace,locale,is_default) VALUES(7,'legacy-reader','audible.ca','ca',1); " ++
                "INSERT INTO library_items(profile_id,asin,title,authors_json,narrators_json,cover_url,duration_seconds,release_date,metadata_json) VALUES(7,'B012345678','Legacy Book','[\"Writer\"]','[\"Voice\"]','https://example.invalid/cover',321,'2026-01-02','{\"source\":\"legacy\"}'); " ++
                "INSERT INTO local_files(id,profile_id,asin,kind,path,size_bytes,checksum,completed_at) VALUES(8,7,'B012345678','audio','/tmp/legacy.aaxc',99,'sum',10); " ++
                "INSERT INTO download_jobs(id,profile_id,asin,kind,destination,status,bytes_downloaded,total_bytes,created_at,updated_at) VALUES('legacy-job',7,'B012345678','audible','/tmp/legacy.aaxc','completed',99,99,1,2); " ++
                "INSERT INTO playback_positions(profile_id,asin,position_seconds,duration_seconds) VALUES(7,'B012345678',12.5,321); " ++
                "INSERT INTO bookmarks(id,profile_id,asin,position_seconds,label) VALUES(9,7,'B012345678',10,'chapter'); COMMIT;",
        );
    }

    var database = try Database.open(std.testing.allocator, std.testing.io, path);
    defer database.deinit();
    try std.testing.expectEqual(@as(u32, 2), try database.migrationVersion());
    const migrated = try database.run(
        "SELECT (SELECT count(*) FROM provider_accounts WHERE provider_id='audible' AND account_id='legacy-reader')||'|'||" ++
            "(SELECT count(*) FROM provider_items WHERE provider_id='audible' AND item_id='B012345678')||'|'||" ++
            "(SELECT count(*) FROM account_library_items)||'|'||(SELECT count(*) FROM provider_local_files)||'|'||" ++
            "(SELECT count(*) FROM provider_download_jobs)||'|'||(SELECT count(*) FROM provider_playback_positions)||'|'||(SELECT count(*) FROM provider_bookmarks);",
    );
    defer std.testing.allocator.free(migrated);
    try std.testing.expectEqualStrings("1|1|1|1|1|1|1\n", migrated);
    const legacy_unchanged = try database.run("SELECT name||'|'||asin||'|'||title FROM profiles JOIN library_items ON profiles.id=library_items.profile_id;");
    defer std.testing.allocator.free(legacy_unchanged);
    try std.testing.expectEqualStrings("legacy-reader|B012345678|Legacy Book\n", legacy_unchanged);
}

test "provider-neutral accounts items jobs files and playback coexist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try openTestDatabase(&tmp);
    defer database.deinit();
    const account: provider_model.AccountIdentity = .{ .provider_id = "cards", .account_id = "family" };
    try database.putProvider("cards", "Card Library");
    try database.putAccount(.{ .identity = account, .display_name = "Family Library", .locale = "en-CA" });
    try database.putProviderItem(account, .{
        .identity = .{ .provider_id = "cards", .item_id = "card:42" },
        .title = "A Provider-Neutral Story",
        .creators_json = "[\"Writer\"]",
        .duration_seconds = 600,
    });
    try database.setSelectedAccount(account);
    const selected = (try database.getSelectedAccount(std.testing.allocator)).?;
    defer selected.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cards", selected.provider_id);
    try std.testing.expectEqualStrings("family", selected.account_id);
    try database.putProviderLocalFile(account, "card:42", "A Provider-Neutral Story", "audio", "/tmp/card-42.opus", 100, null);
    try database.putProviderDownloadJob(.{
        .id = "job-42",
        .account = account,
        .item_id = "card:42",
        .title = "A Provider-Neutral Story",
        .kind = "provider",
        .destination = "/tmp/card-42.opus",
        .status = "completed",
        .bytes_downloaded = 100,
        .total_bytes = 100,
        .created_at = 1,
        .updated_at = 2,
    });
    try database.putProviderPlaybackPosition(account, "card:42", "A Provider-Neutral Story", 45, 600);
    const position = (try database.getProviderPlaybackPosition(account, "card:42")).?;
    try std.testing.expectApproxEqAbs(@as(f64, 45), position.position_seconds, 0.001);
    const bookmark_id = try database.addProviderBookmark(account, "card:42", "A Provider-Neutral Story", 30, "favorite");
    const bookmarks = try database.listProviderBookmarks(std.testing.allocator, account, "card:42");
    defer {
        for (bookmarks) |bookmark| bookmark.deinit(std.testing.allocator);
        std.testing.allocator.free(bookmarks);
    }
    try std.testing.expectEqual(@as(usize, 1), bookmarks.len);
    try std.testing.expectEqualStrings("favorite", bookmarks[0].label.?);
    try database.deleteProviderBookmark(account, bookmark_id);
    const counts = try database.run("SELECT (SELECT display_name FROM providers WHERE id='cards')||'|'||(SELECT count(*) FROM provider_accounts WHERE provider_id='cards')||'|'||(SELECT count(*) FROM provider_items WHERE provider_id='cards')||'|'||(SELECT count(*) FROM provider_local_files WHERE provider_id='cards')||'|'||(SELECT count(*) FROM provider_download_jobs WHERE provider_id='cards')||'|'||(SELECT count(*) FROM profiles);");
    defer std.testing.allocator.free(counts);
    try std.testing.expectEqualStrings("Card Library|1|1|1|1|0\n", counts);
    const preserved_metadata = try database.run("SELECT creators_json||'|'||duration_seconds FROM provider_items WHERE provider_id='cards' AND item_id='card:42';");
    defer std.testing.allocator.free(preserved_metadata);
    try std.testing.expectEqualStrings("[\"Writer\"]|600\n", preserved_metadata);
}
