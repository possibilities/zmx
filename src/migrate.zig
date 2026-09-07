//! Handing a live session to another build of zmx.
//!
//! A session's pty master is an open file description, not a name: the child
//! is attached to the other end of it and knows nothing about which process
//! is holding this end. So a daemon can pass that descriptor -- and the
//! listening socket clients reach it by -- to a freshly executed binary over
//! a Unix-domain socket, and the new process becomes the session. The child
//! is never signalled, never re-parented onto a new terminal, and never
//! learns that anything happened.
//!
//! What cannot cross is parenthood. The new daemon did not fork the child,
//! so it cannot `waitid` for it and cannot report its exit code; from then
//! on the session's end is observed by probing the pid, and the `Exit` frame
//! says the status is unknown rather than inventing a zero. Everything else
//! -- the shadow terminal, labels, the working directory, the session
//! lifecycle policy, bytes queued for the child -- travels in the manifest
//! below.
//!
//! The two sides speak a private protocol on a private socket, not the
//! session protocol: it exists for one exchange between two processes that
//! already trust each other, and it is deliberately not something a client
//! can speak.

const std = @import("std");
const builtin = @import("builtin");
const lib_posix = @import("posix.zig");
const cross = @import("cross.zig");

/// Bumped when the manifest's meaning changes in a way a reader of the
/// previous version would get wrong. The importer refuses a version it does
/// not know, which is what makes a handoff to an incompatible build fail
/// loudly on the source's side rather than half-succeed.
pub const manifest_version: u16 = 1;

pub const magic = "ZMXH";

/// A manifest is dominated by the shadow terminal's serialized scrollback,
/// which `--scrollback-lines` can make large. This bounds what an importer
/// will allocate on one line's say-so.
pub const max_manifest_len: u32 = 64 * 1024 * 1024;

/// How long each side waits for the other at every step. A failed handoff
/// stalls the session for at most a couple of these, because the daemon is
/// single-threaded and runs the exchange inline; it never loses the session.
pub const step_timeout_ms: i32 = 5000;

/// The final acknowledgement is advisory -- the importer already owns
/// everything by then -- so the source does not hold the session open
/// waiting for it.
pub const owned_timeout_ms: i32 = 500;

/// Words the two sides exchange. Two bytes each so a short read is never
/// mistaken for a different word.
pub const word_len = 2;
pub const word_validated = "OK".*;
pub const word_refused = "NO".*;
pub const word_restored = "RS".*;
pub const word_committed = "CM".*;
pub const word_owned = "OW".*;

pub const token_len = 32;

/// Explicit integers: these cross a socket between two different builds.
pub const flag_has_pty_output: u32 = 1 << 0;
pub const flag_has_had_client: u32 = 1 << 1;
pub const flag_has_terminal_client: u32 = 1 << 2;
pub const flag_exit_on_last_client: u32 = 1 << 3;
pub const flag_exit_on_last_client_armed: u32 = 1 << 4;
pub const flag_record_exit: u32 = 1 << 5;
pub const flag_is_task_mode: u32 = 1 << 6;
pub const flag_has_command: u32 = 1 << 7;
pub const flag_has_task_exit_code: u32 = 1 << 8;
pub const flag_has_task_ended_at: u32 = 1 << 9;
/// Set when the sending daemon is itself not the child's parent, so a
/// session that has been handed on twice still reports honestly.
pub const flag_child_adopted: u32 = 1 << 10;
// CUP cannot express pending wrap. Preserve it separately for both screens.
pub const flag_primary_pending_wrap: u32 = 1 << 11;
pub const flag_alternate_pending_wrap: u32 = 1 << 12;
pub const flag_primary_saved_wrap: u32 = 1 << 13;
pub const flag_alternate_saved_wrap: u32 = 1 << 14;

/// Everything the receiving daemon needs to be the session, other than the
/// two descriptors that follow it. Fixed-width header, then length-prefixed
/// blobs in a frozen order; the golden test below is the contract.
pub const Manifest = struct {
    /// What the source speaks, so a mismatch is legible in the log rather
    /// than appearing later as a client that cannot negotiate.
    protocol_version: u16,
    flags: u32 = 0,
    /// The child. Its parent is the source daemon, and after the handoff it
    /// has none of ours: it is re-parented to init when the source exits.
    pid: i32,
    created_at: u64,
    terminal_activity_sequence: u64,
    max_scrollback_lines: u64,
    task_ended_at: u64 = 0,
    task_exit_code: u8 = 0,
    task_id: [4]u8 = .{ 0, 0, 0, 0 },

    session_name: []const u8,
    socket_path: []const u8,
    /// The session's cwd in OSC 7 form, as the daemon holds it.
    cwd: []const u8 = "",
    /// Argv as NUL-separated strings; empty when the session runs the
    /// default shell. Argv strings are C strings, so NUL cannot occur
    /// inside one.
    command: []const u8 = "",
    shell: []const u8 = "",
    /// Labels in `zmx set` form, applied by the importer as if it were
    /// creating the session with them.
    labels: []const u8 = "",
    /// Bytes accepted for the child that the pty had not taken yet. They
    /// would otherwise be dropped by the process that accepted them.
    pty_input: []const u8 = "",
    /// The shadow terminal as VT bytes, replayed into the new daemon's
    /// terminal before it reads anything from the pty.
    snapshot: []const u8 = "",

    pub fn has(self: Manifest, flag: u32) bool {
        return self.flags & flag != 0;
    }
};

const header_len = 56;

fn putBlob(gpa: std.mem.Allocator, out: *std.ArrayList(u8), blob: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(blob.len), .little);
    try out.appendSlice(gpa, &len_bytes);
    try out.appendSlice(gpa, blob);
}

/// Caller owns the returned bytes.
pub fn encodeManifest(gpa: std.mem.Allocator, m: Manifest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var head: [header_len]u8 = @splat(0);
    @memcpy(head[0..4], magic);
    std.mem.writeInt(u16, head[4..6], manifest_version, .little);
    std.mem.writeInt(u16, head[6..8], m.protocol_version, .little);
    std.mem.writeInt(u32, head[8..12], m.flags, .little);
    std.mem.writeInt(i32, head[12..16], m.pid, .little);
    std.mem.writeInt(u64, head[16..24], m.created_at, .little);
    std.mem.writeInt(u64, head[24..32], m.terminal_activity_sequence, .little);
    std.mem.writeInt(u64, head[32..40], m.max_scrollback_lines, .little);
    std.mem.writeInt(u64, head[40..48], m.task_ended_at, .little);
    head[48] = m.task_exit_code;
    @memcpy(head[49..53], &m.task_id);
    try out.appendSlice(gpa, &head);

    // Frozen order. A new field is a new blob at the end, and the version
    // above says whether it is there.
    try putBlob(gpa, &out, m.session_name);
    try putBlob(gpa, &out, m.socket_path);
    try putBlob(gpa, &out, m.cwd);
    try putBlob(gpa, &out, m.command);
    try putBlob(gpa, &out, m.shell);
    try putBlob(gpa, &out, m.labels);
    try putBlob(gpa, &out, m.pty_input);
    try putBlob(gpa, &out, m.snapshot);

    return out.toOwnedSlice(gpa);
}

pub const DecodeError = error{
    NotAManifest,
    UnsupportedVersion,
    Truncated,
};

const BlobReader = struct {
    bytes: []const u8,
    offset: usize,

    fn next(self: *BlobReader) DecodeError![]const u8 {
        if (self.bytes.len - self.offset < 4) return error.Truncated;
        const len = std.mem.readInt(u32, self.bytes[self.offset..][0..4], .little);
        self.offset += 4;
        if (self.bytes.len - self.offset < len) return error.Truncated;
        const blob = self.bytes[self.offset..][0..len];
        self.offset += len;
        return blob;
    }
};

/// The returned `Manifest`'s slices point into `bytes`, which the caller
/// keeps alive for as long as it uses them.
pub fn decodeManifest(bytes: []const u8) DecodeError!Manifest {
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotAManifest;
    if (std.mem.readInt(u16, bytes[4..6], .little) != manifest_version) return error.UnsupportedVersion;

    var reader = BlobReader{ .bytes = bytes, .offset = header_len };
    var m = Manifest{
        .protocol_version = std.mem.readInt(u16, bytes[6..8], .little),
        .flags = std.mem.readInt(u32, bytes[8..12], .little),
        .pid = std.mem.readInt(i32, bytes[12..16], .little),
        .created_at = std.mem.readInt(u64, bytes[16..24], .little),
        .terminal_activity_sequence = std.mem.readInt(u64, bytes[24..32], .little),
        .max_scrollback_lines = std.mem.readInt(u64, bytes[32..40], .little),
        .task_ended_at = std.mem.readInt(u64, bytes[40..48], .little),
        .task_exit_code = bytes[48],
        .session_name = "",
        .socket_path = "",
    };
    m.task_id = bytes[49..53].*;
    m.session_name = try reader.next();
    m.socket_path = try reader.next();
    m.cwd = try reader.next();
    m.command = try reader.next();
    m.shell = try reader.next();
    m.labels = try reader.next();
    m.pty_input = try reader.next();
    m.snapshot = try reader.next();
    return m;
}

/// Splits the manifest's argv blob. Caller owns the slice of slices; the
/// strings themselves point into the blob.
pub fn splitCommand(gpa: std.mem.Allocator, blob: []const u8) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    // An empty blob is no command at all. Within one, an empty element is a
    // real argument -- `sh -c ''` is three of them -- so only the whole-blob
    // case is special.
    if (blob.len == 0) return argv.toOwnedSlice(gpa);
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |arg| try argv.append(gpa, arg);
    return argv.toOwnedSlice(gpa);
}

/// Joins argv for the manifest. Caller owns the result.
pub fn joinCommand(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(gpa, 0);
        try out.appendSlice(gpa, arg);
    }
    return out.toOwnedSlice(gpa);
}

// ===========================================================================
// The exchange
// ===========================================================================

pub const StepError = error{
    Timeout,
    PeerClosed,
    /// The peer said something other than the word this step expects,
    /// including its explicit refusal.
    Unexpected,
} || lib_posix.ReadError || lib_posix.WriteError;

/// A whole step's budget, not one system call's.
///
/// The daemon runs this exchange inline, so every wait here is the session
/// frozen: nothing reads the pty, writes to the child, or serves a client
/// until the step returns. A timeout that bounded only the first poll would
/// bound nothing at all -- a peer that connects, echoes the token, and then
/// reads a byte at a time keeps every individual wait short while holding
/// the session for as long as it likes. The deadline is taken once and every
/// wait is measured against it.
const Deadline = struct {
    end_ms: i64,

    fn init(budget_ms: i32) Deadline {
        return .{ .end_ms = nowMs() + budget_ms };
    }

    /// Milliseconds left, or null when the budget is spent.
    fn remaining(self: Deadline) ?i32 {
        const left = self.end_ms - nowMs();
        if (left <= 0) return null;
        return if (left > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(left);
    }

    fn nowMs() i64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
};

fn waitFor(fd: i32, events: i16, deadline: Deadline) StepError!void {
    const left = deadline.remaining() orelse return error.Timeout;
    var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const n = lib_posix.poll(&fds, left) catch return error.Timeout;
    if (n == 0) return error.Timeout;
}

pub fn waitReadable(fd: i32, timeout_ms: i32) StepError!void {
    return waitFor(fd, lib_posix.POLL.IN, Deadline.init(timeout_ms));
}

pub fn readExact(fd: i32, buf: []u8, timeout_ms: i32) StepError!void {
    const deadline = Deadline.init(timeout_ms);
    var read: usize = 0;
    while (read < buf.len) {
        try waitFor(fd, lib_posix.POLL.IN, deadline);
        const n = lib_posix.read(fd, buf[read..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.PeerClosed;
        read += n;
    }
}

pub fn writeExact(fd: i32, bytes: []const u8, timeout_ms: i32) StepError!void {
    const deadline = Deadline.init(timeout_ms);
    var written: usize = 0;
    while (written < bytes.len) {
        try waitFor(fd, lib_posix.POLL.OUT, deadline);
        const n = lib_posix.write(fd, bytes[written..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.PeerClosed;
        written += n;
    }
}

/// Descriptors, on the same terms as everything else here: the socket is
/// non-blocking, so a peer that has stopped reading costs a timeout rather
/// than the session.
pub fn sendFdsWithin(fd: i32, fds: []const lib_posix.fd_t, timeout_ms: i32) !void {
    const deadline = Deadline.init(timeout_ms);
    while (true) {
        try waitFor(fd, lib_posix.POLL.OUT, deadline);
        lib_posix.sendFds(fd, fds) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        return;
    }
}

pub fn sendWord(fd: i32, word: [word_len]u8) StepError!void {
    try writeExact(fd, &word, step_timeout_ms);
}

pub fn awaitWord(fd: i32, want: [word_len]u8, timeout_ms: i32) StepError!void {
    var got: [word_len]u8 = undefined;
    try readExact(fd, &got, timeout_ms);
    if (!std.mem.eql(u8, &got, &want)) return error.Unexpected;
}

pub fn sendManifest(fd: i32, bytes: []const u8) StepError!void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(bytes.len), .little);
    try writeExact(fd, &len_bytes, step_timeout_ms);
    try writeExact(fd, bytes, step_timeout_ms);
}

/// Caller owns the returned bytes.
pub fn readManifest(gpa: std.mem.Allocator, fd: i32) ![]u8 {
    var len_bytes: [4]u8 = undefined;
    try readExact(fd, &len_bytes, step_timeout_ms);
    const len = std.mem.readInt(u32, &len_bytes, .little);
    if (len == 0 or len > max_manifest_len) return error.NotAManifest;
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    try readExact(fd, bytes, step_timeout_ms);
    return bytes;
}

/// Every descriptor in the exchange is non-blocking, and deliberately so: on
/// a blocking socket a single `write` returns only once the peer has taken
/// every byte, so a manifest larger than the send buffer -- which a
/// scrollback makes ordinary -- would hold the daemon for exactly as long as
/// the peer felt like not reading, whatever timeout was written around it.
/// An accepted connection inherits the listener's flag on Darwin but not on
/// Linux, so it is set rather than assumed.
pub fn setNonBlocking(fd: i32) !void {
    const flags = try lib_posix.fcntl(fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
}

/// A token the importer must echo before it is told anything. The socket's
/// mode is what actually keeps other users out; this closes the narrower
/// window where something else in this user's own session directory connects
/// first and receives a manifest meant for the importer.
pub fn newToken() ![token_len]u8 {
    const alphabet = "0123456789abcdef";
    var raw: [token_len / 2]u8 = undefined;
    const fd = try lib_posix.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, 0);
    defer lib_posix.close(fd);
    var read: usize = 0;
    while (read < raw.len) {
        const n = try lib_posix.read(fd, raw[read..]);
        if (n == 0) return error.EndOfStream;
        read += n;
    }
    var token: [token_len]u8 = undefined;
    for (raw, 0..) |byte, i| {
        token[i * 2] = alphabet[byte >> 4];
        token[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return token;
}

/// Where the two sides meet. Kept in the log directory rather than beside
/// the sessions, because everything in the session directory is a session
/// name and discovery would report this as one. The pid is the source
/// daemon's, which is unique among live daemons, and the name is short:
/// macOS caps a Unix socket path near 104 bytes.
pub fn socketPath(buf: []u8, log_dir: []const u8, pid: i32) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/h-{d}.sock", .{ log_dir, pid });
}

/// Binds the handoff socket 0600 before anything is listening for it, so
/// there is no moment where another user could connect.
pub fn bindHandoffSocket(path: [:0]const u8) !lib_posix.socket_t {
    // Whatever a crashed handoff left at this name is ours: the name carries
    // this daemon's own pid.
    _ = cross.c.unlink(path.ptr);
    // Non-blocking, so the accept that follows a poll cannot wedge the
    // daemon if the connection is gone by the time it runs.
    const fd = try lib_posix.socket(
        lib_posix.AF.UNIX,
        lib_posix.SOCK.STREAM | lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
        0,
    );
    errdefer lib_posix.close(fd);
    var addr = try lib_posix.initUnix(path);
    try lib_posix.bind(fd, &addr.any, addr.getOsSockLen());
    try lib_posix.listen(fd, 1);
    // Only this user, and only after the name exists: a mode set later would
    // leave a window where the socket is bound and open to everyone.
    if (std.c.chmod(path.ptr, 0o600) != 0) {
        // The errdefer above closes the descriptor; closing it here as well
        // would hand back a number the next open is free to reuse.
        _ = cross.c.unlink(path.ptr);
        return error.AccessDenied;
    }
    return fd;
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// The path of the binary running this code, resolved through symlinks.
///
/// `zmx migrate` defaults its target to this, which is what makes an upgrade
/// read the way it happens: the newly installed binary is the one asked to
/// take the sessions, and it hands its own path to the daemons.
pub fn selfExePath(out: []u8) ![]const u8 {
    var raw: [std.fs.max_path_bytes]u8 = undefined;
    if (comptime builtin.os.tag.isDarwin()) {
        var size: u32 = @intCast(raw.len);
        if (_NSGetExecutablePath(&raw, &size) != 0) return error.NameTooLong;
    } else {
        const n = std.c.readlink("/proc/self/exe", &raw, raw.len - 1);
        if (n <= 0) return error.FileNotFound;
        raw[@intCast(n)] = 0;
    }
    return realPath(@ptrCast(&raw), out);
}

/// Resolves what a person typed into something a daemon in another working
/// directory can execute.
pub fn resolveExe(target: ?[]const u8, out: []u8) ![]const u8 {
    const given = target orelse return selfExePath(out);
    var raw: [std.fs.max_path_bytes]u8 = undefined;
    if (given.len >= raw.len) return error.NameTooLong;
    @memcpy(raw[0..given.len], given);
    raw[given.len] = 0;
    return realPath(@ptrCast(&raw), out);
}

fn realPath(path: [*:0]const u8, out: []u8) ![]const u8 {
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const got = cross.c.realpath(path, &resolved) orelse return error.FileNotFound;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(got)));
    if (span.len >= out.len) return error.NameTooLong;
    @memcpy(out[0..span.len], span);
    return out[0..span.len];
}

/// The importer is executed, not forked into: a handoff exists to replace
/// the running code, so the new session must be the new binary from its
/// first instruction.
///
/// One fork is enough to detach it. A daemon is deliberately not a session
/// leader -- `daemonize` gives up that role precisely so no zmx process can
/// acquire a controlling terminal -- and a child of one is not a session
/// leader either, so the importer inherits that guarantee. When the source
/// exits moments later, init adopts the importer.
pub fn spawnImporter(exe_path: []const u8, socket_path_arg: [:0]const u8, token: []const u8) !lib_posix.fd_t {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    var token_buf: [token_len + 1]u8 = undefined;
    if (exe_path.len >= exe_buf.len or socket_path_arg.len >= sock_buf.len) return error.NameTooLong;
    if (token.len != token_len) return error.InvalidToken;
    @memcpy(exe_buf[0..exe_path.len], exe_path);
    exe_buf[exe_path.len] = 0;
    @memcpy(sock_buf[0..socket_path_arg.len], socket_path_arg);
    sock_buf[socket_path_arg.len] = 0;
    @memcpy(token_buf[0..token_len], token);
    token_buf[token_len] = 0;

    const exe_z: [*:0]const u8 = @ptrCast(&exe_buf);
    const sock_z: [*:0]const u8 = @ptrCast(&sock_buf);
    const token_z: [*:0]const u8 = @ptrCast(&token_buf);
    const subcommand: [*:0]const u8 = import_subcommand;

    var argv = [_:null]?[*:0]const u8{ exe_z, subcommand, sock_z, token_z };

    const pid = try lib_posix.fork();
    if (pid > 0) return pid;

    // The importer connects to the handoff socket by name, so it needs
    // nothing of ours: every descriptor is closed and stdio is /dev/null,
    // exactly as `daemonize` leaves a daemon.
    if (lib_posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0)) |devnull| {
        inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |fd| {
            lib_posix.dup2(devnull, fd) catch {};
        }
        if (devnull > 2) lib_posix.close(devnull);
    } else |_| {}
    var fd: i32 = 3;
    while (fd < 64) : (fd += 1) _ = std.c.close(fd);

    const exec_err = lib_posix.execvpeZ(exe_z, &argv, std.c.environ);
    // Reached only when exec failed. Returning would run the daemon's own
    // code in a second process holding its session, so this exits instead
    // and the source's handshake times out and rolls back. The codes are a
    // shell's: 127 for a command that is not there, 126 for one that is but
    // could not be run.
    lib_posix.exit(if (exec_err == error.FileNotFound) 127 else 126);
}

/// The hidden verb the source executes. Not in help or completions: it is
/// never something a person runs, and its arguments are meaningless without
/// a source daemon waiting on the other end.
pub const import_subcommand = "__migrate-import";

/// What the source daemon answers a `migrate` request with: a status byte
/// and, when refused, a reason a person can read.
pub const ack_ok: u8 = 0;
pub const ack_refused: u8 = 1;

test "manifest round-trips through its frozen layout" {
    const gpa = std.testing.allocator;
    const bytes = try encodeManifest(gpa, .{
        .protocol_version = 1,
        .flags = flag_has_pty_output | flag_record_exit,
        .pid = 4242,
        .created_at = 1_700_000_000,
        .terminal_activity_sequence = 9,
        .max_scrollback_lines = 2000,
        .task_ended_at = 0,
        .task_exit_code = 0,
        .task_id = "abcd".*,
        .session_name = "work",
        .socket_path = "/tmp/zmx/work",
        .cwd = "file://host/home/me",
        .command = "sh\x00-c\x00echo hi",
        .shell = "/bin/zsh",
        .labels = "role=agent",
        .pty_input = "ls\r",
        .snapshot = "\x1b[2Jhello",
    });
    defer gpa.free(bytes);

    const m = try decodeManifest(bytes);
    try std.testing.expectEqual(@as(u16, 1), m.protocol_version);
    try std.testing.expectEqual(@as(i32, 4242), m.pid);
    try std.testing.expectEqual(@as(u64, 1_700_000_000), m.created_at);
    try std.testing.expectEqual(@as(u64, 9), m.terminal_activity_sequence);
    try std.testing.expectEqual(@as(u64, 2000), m.max_scrollback_lines);
    try std.testing.expectEqualStrings("abcd", &m.task_id);
    try std.testing.expect(m.has(flag_has_pty_output));
    try std.testing.expect(m.has(flag_record_exit));
    try std.testing.expect(!m.has(flag_is_task_mode));
    try std.testing.expectEqualStrings("work", m.session_name);
    try std.testing.expectEqualStrings("/tmp/zmx/work", m.socket_path);
    try std.testing.expectEqualStrings("file://host/home/me", m.cwd);
    try std.testing.expectEqualStrings("/bin/zsh", m.shell);
    try std.testing.expectEqualStrings("role=agent", m.labels);
    try std.testing.expectEqualStrings("ls\r", m.pty_input);
    try std.testing.expectEqualStrings("\x1b[2Jhello", m.snapshot);

    const argv = try splitCommand(gpa, m.command);
    defer gpa.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("echo hi", argv[2]);
}

test "manifest header bytes are frozen" {
    const gpa = std.testing.allocator;
    const bytes = try encodeManifest(gpa, .{
        .protocol_version = 1,
        .pid = 1,
        .created_at = 0,
        .terminal_activity_sequence = 0,
        .max_scrollback_lines = 0,
        .session_name = "a",
        .socket_path = "",
    });
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, "ZMXH", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bytes[12..16], .little));
    // Header, then the first blob: a four-byte length and one byte of name.
    try std.testing.expectEqual(@as(usize, header_len), 56);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[56..60], .little));
    try std.testing.expectEqualStrings("a", bytes[60..61]);
}

test "a manifest a build does not understand is refused, not guessed at" {
    const gpa = std.testing.allocator;
    const bytes = try encodeManifest(gpa, .{
        .protocol_version = 1,
        .pid = 1,
        .created_at = 0,
        .terminal_activity_sequence = 0,
        .max_scrollback_lines = 0,
        .session_name = "a",
        .socket_path = "",
    });
    defer gpa.free(bytes);

    try std.testing.expectError(error.Truncated, decodeManifest(bytes[0 .. bytes.len - 1]));
    try std.testing.expectError(error.Truncated, decodeManifest(bytes[0..10]));

    const wrong_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong_magic);
    wrong_magic[0] = 'X';
    try std.testing.expectError(error.NotAManifest, decodeManifest(wrong_magic));

    const wrong_version = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong_version);
    std.mem.writeInt(u16, wrong_version[4..6], manifest_version + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, decodeManifest(wrong_version));
}

test "a token is hex and does not repeat" {
    const a = try newToken();
    const b = try newToken();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    for (a) |c| try std.testing.expect(std.ascii.isHex(c));
}

test "argv keeps an empty argument that the command really has" {
    const gpa = std.testing.allocator;
    const joined = try joinCommand(gpa, &.{ "sh", "-c", "" });
    defer gpa.free(joined);
    const argv = try splitCommand(gpa, joined);
    defer gpa.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("", argv[2]);
}

test "argv joins and splits without inventing an empty argument" {
    const gpa = std.testing.allocator;
    const joined = try joinCommand(gpa, &.{ "bash", "-lc", "echo" });
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("bash\x00-lc\x00echo", joined);

    const none = try joinCommand(gpa, &.{});
    defer gpa.free(none);
    try std.testing.expectEqualStrings("", none);
    const empty = try splitCommand(gpa, none);
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "the words two sides exchange cross a socketpair intact" {
    var pair: [2]lib_posix.fd_t = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer lib_posix.close(pair[0]);
    defer lib_posix.close(pair[1]);

    try sendWord(pair[0], word_validated);
    try awaitWord(pair[1], word_validated, step_timeout_ms);

    try sendWord(pair[0], word_refused);
    try std.testing.expectError(error.Unexpected, awaitWord(pair[1], word_restored, step_timeout_ms));

    // Nothing said, nothing waited for beyond the deadline.
    try std.testing.expectError(error.Timeout, awaitWord(pair[1], word_owned, 20));
}

test "a manifest crosses a socketpair whole" {
    const gpa = std.testing.allocator;
    var pair: [2]lib_posix.fd_t = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer lib_posix.close(pair[0]);
    defer lib_posix.close(pair[1]);

    const bytes = try encodeManifest(gpa, .{
        .protocol_version = 1,
        .pid = 7,
        .created_at = 5,
        .terminal_activity_sequence = 0,
        .max_scrollback_lines = 100,
        .session_name = "sesh",
        .socket_path = "/tmp/sesh",
        .snapshot = "x" ** 5000,
    });
    defer gpa.free(bytes);

    try sendManifest(pair[0], bytes);
    const got = try readManifest(gpa, pair[1]);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, bytes, got);

    const m = try decodeManifest(got);
    try std.testing.expectEqualStrings("sesh", m.session_name);
    try std.testing.expectEqual(@as(usize, 5000), m.snapshot.len);
}

test "an oversized manifest is refused before allocation" {
    var pair: [2]lib_posix.fd_t = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer lib_posix.close(pair[0]);
    defer lib_posix.close(pair[1]);
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, max_manifest_len + 1, .little);
    try writeExact(pair[0], &length, 100);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.NotAManifest, readManifest(failing.allocator(), pair[1]));
    try std.testing.expect(!failing.has_induced_failure);
}

comptime {
    // The importer is spawned with exactly these three arguments; a change
    // to either side without the other would leave a source daemon waiting
    // on a process that exits immediately.
    if (import_subcommand.len == 0) @compileError("the import verb must have a name");
    if (builtin.os.tag == .windows) @compileError("handoff needs Unix descriptor passing");
}

test "a peer that stops reading costs a timeout, not the session" {
    var pair: [2]lib_posix.fd_t = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer lib_posix.close(pair[0]);
    defer lib_posix.close(pair[1]);
    try setNonBlocking(pair[0]);

    // Far more than any socket's send buffer, and nobody is reading the other
    // end. On a blocking descriptor this is where the daemon used to stop
    // being a session for as long as the peer felt like it.
    const gpa = std.testing.allocator;
    const flood = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(flood);
    @memset(flood, 'x');

    const started = Deadline.nowMs();
    try std.testing.expectError(error.Timeout, writeExact(pair[0], flood, 100));
    const elapsed = Deadline.nowMs() - started;
    // It gave up on its own budget rather than on the peer's goodwill.
    try std.testing.expect(elapsed < 3000);
}

test "a deadline bounds a peer that dribbles rather than stalls" {
    var pair: [2]lib_posix.fd_t = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer lib_posix.close(pair[0]);
    defer lib_posix.close(pair[1]);

    // Nothing is ever sent, so every wait is a full wait: the budget is spent
    // once in total, not once per poll.
    const started = Deadline.nowMs();
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.Timeout, readExact(pair[0], &buf, 150));
    const elapsed = Deadline.nowMs() - started;
    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 3000);
}
