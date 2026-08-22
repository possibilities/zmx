const std = @import("std");
const cross = @import("cross.zig");
const socket = @import("socket.zig");
const lib_posix = @import("posix.zig");

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    Switch = 11,
    Write = 12,
    TaskComplete = 13,
    LabelGet = 14,
    LabelSet = 15,
    LabelClear = 16,
    LabelData = 17,
    Send = 18,
    Hello = 19,
    Welcome = 20,
    RestoreBegin = 21,
    Ready = 22,
    Exit = 23,
    // Upstream tags 19..22 overlap the published Companion v1 contract.
    // Keep that contract stable and assign new operations unused values.
    EnvGet = 26,
    EnvSet = 27,
    EnvData = 28,
    /// Scoped history: the active screen plus a bounded number of
    /// preceding scrollback rows. Request payload is `Capture`.
    Capture = 29,
    // Non-exhaustive: this enum comes off the wire via bytesToValue and
    // @enumFromInt, so out-of-range values are representable
    // rather than UB. Switches must handle `_` (unknown tag).
    _,
};

comptime {
    if (@typeInfo(Tag).@"enum".is_exhaustive) @compileError(
        "ipc.Tag must stay non-exhaustive -- old daemons rely on `_` to ignore unknown tags",
    );
}

/// Frame envelope. On the wire it is exactly `header_len` bytes: the tag
/// byte, the payload length as a u32 little-endian, then `header_reserved`
/// zero bytes. Encoding is explicit (`encodeHeader`/`decodeHeader`) so the
/// layout is a contract rather than whatever `packed struct` emits on the
/// host; see the frozen-bytes tests below.
pub const Header = struct {
    tag: Tag,
    len: u32,
};

pub const header_len = 8;
const header_reserved = header_len - 1 - @sizeOf(u32);

/// Largest payload a frame may carry. A header announcing more is a protocol
/// violation: the reader fails instead of accumulating bytes toward it.
/// Sized for one restoration snapshot (the largest frame either side sends
/// today); make it configurable when scrollback becomes configurable.
pub const max_payload_len: u32 = 16 * 1024 * 1024;

pub fn encodeHeader(tag: Tag, len: u32) [header_len]u8 {
    var out = [_]u8{0} ** header_len;
    out[0] = @intFromEnum(tag);
    std.mem.writeInt(u32, out[1..5], len, .little);
    return out;
}

/// Reserved bytes are ignored on decode so a future revision can claim them
/// without this reader rejecting the frame.
pub fn decodeHeader(bytes: *const [header_len]u8) Header {
    return .{
        .tag = @enumFromInt(bytes[0]),
        .len = std.mem.readInt(u32, bytes[1..5], .little),
    };
}

/// Terminal size. On the wire: rows, cols, xpixel, ypixel, each a u16
/// little-endian, `resize_len` bytes total.
pub const Resize = struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,

    pub fn winsize(self: Resize) cross.c.struct_winsize {
        return .{ .ws_row = self.rows, .ws_col = self.cols, .ws_xpixel = self.xpixel, .ws_ypixel = self.ypixel };
    }
};

/// Request payload for `Tag.Capture`. `format` is a `util.HistoryFormat`
/// and `rows` is how many scrollback rows to include above the active
/// screen; zero returns only the screen.
pub const Capture = struct {
    format: u8,
    rows: u32,
};

/// Format byte, u32 little-endian rows, then three reserved zero bytes.
pub const capture_len = 8;

pub fn encodeCapture(request: Capture) [capture_len]u8 {
    var out = [_]u8{0} ** capture_len;
    out[0] = request.format;
    std.mem.writeInt(u32, out[1..5], request.rows, .little);
    return out;
}

pub fn decodeCapture(bytes: []const u8) error{BadLength}!Capture {
    if (bytes.len != capture_len) return error.BadLength;
    return .{ .format = bytes[0], .rows = std.mem.readInt(u32, bytes[1..5], .little) };
}

pub const resize_len = 8;

pub fn encodeResize(size: Resize) [resize_len]u8 {
    var out: [resize_len]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], size.rows, .little);
    std.mem.writeInt(u16, out[2..4], size.cols, .little);
    std.mem.writeInt(u16, out[4..6], size.xpixel, .little);
    std.mem.writeInt(u16, out[6..8], size.ypixel, .little);
    return out;
}

pub fn decodeResize(bytes: []const u8) error{BadLength}!Resize {
    if (bytes.len != resize_len) return error.BadLength;
    return .{
        .rows = std.mem.readInt(u16, bytes[0..2], .little),
        .cols = std.mem.readInt(u16, bytes[2..4], .little),
        .xpixel = std.mem.readInt(u16, bytes[4..6], .little),
        .ypixel = std.mem.readInt(u16, bytes[6..8], .little),
    };
}

pub fn getTerminalSize(fd: i32) Resize {
    var ws: cross.c.struct_winsize = undefined;
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
    }
    inline for (.{ lib_posix.STDOUT_FILENO, lib_posix.STDIN_FILENO, lib_posix.STDERR_FILENO }) |fallback_fd| {
        if (fallback_fd != fd) {
            if (cross.c.ioctl(fallback_fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
                return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
            }
        }
    }
    if (lib_posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |tty_fd| {
        defer lib_posix.close(tty_fd);
        if (cross.c.ioctl(tty_fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
        }
    } else |_| {}
    return .{ .rows = 24, .cols = 120 };
}

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

/// Frozen wire shape. Do NOT add fields! New stats go in new `Tag` values
/// so old daemons (whose `_` arm ignores unknown tags) stay reachable.
/// Changing `@sizeOf(Info)` breaks `zmx list` against running daemons.
/// Version of the negotiated client contract: the frame envelope above plus
/// Hello/Welcome and the attached-client lifecycle. Bump when a client that
/// speaks only the previous version could misread the daemon.
pub const protocol_version: u16 = 1;
pub const min_protocol_version: u16 = 1;

/// First message from a client that wants the versioned contract. A client
/// that never sends one is a legacy client and gets pre-negotiation
/// behavior. On the wire: min_version u16, max_version u16, capabilities
/// u32 (all little-endian), then the client name as UTF-8, at most
/// `max_client_name_len` bytes.
pub const Hello = struct {
    min_version: u16,
    max_version: u16,
    capabilities: u32 = 0,
    client: []const u8,
};

pub const hello_fixed_len = 8;
pub const max_client_name_len = 64;
pub const max_hello_len = hello_fixed_len + max_client_name_len;

pub fn encodeHello(buf: *[max_hello_len]u8, hello: Hello) error{NameTooLong}![]const u8 {
    if (hello.client.len > max_client_name_len) return error.NameTooLong;
    std.mem.writeInt(u16, buf[0..2], hello.min_version, .little);
    std.mem.writeInt(u16, buf[2..4], hello.max_version, .little);
    std.mem.writeInt(u32, buf[4..8], hello.capabilities, .little);
    @memcpy(buf[hello_fixed_len..][0..hello.client.len], hello.client);
    return buf[0 .. hello_fixed_len + hello.client.len];
}

pub fn decodeHello(bytes: []const u8) error{ BadLength, NameTooLong }!Hello {
    if (bytes.len < hello_fixed_len) return error.BadLength;
    if (bytes.len > max_hello_len) return error.NameTooLong;
    return .{
        .min_version = std.mem.readInt(u16, bytes[0..2], .little),
        .max_version = std.mem.readInt(u16, bytes[2..4], .little),
        .capabilities = std.mem.readInt(u32, bytes[4..8], .little),
        .client = bytes[hello_fixed_len..],
    };
}

/// The daemon's answer to Hello. `version` is the one both sides will
/// speak, or 0 when the ranges do not overlap, in which case the daemon
/// closes the connection after sending it; `min_version`/`max_version` are
/// what the daemon speaks so the client can say why. On the wire: version
/// u16, min_version u16, max_version u16, capabilities u32, little-endian.
pub const Welcome = struct {
    version: u16,
    min_version: u16 = min_protocol_version,
    max_version: u16 = protocol_version,
    capabilities: u32 = 0,

    pub fn accepted(self: Welcome) bool {
        return self.version != 0;
    }
};

pub const welcome_len = 10;

pub fn encodeWelcome(welcome: Welcome) [welcome_len]u8 {
    var out: [welcome_len]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], welcome.version, .little);
    std.mem.writeInt(u16, out[2..4], welcome.min_version, .little);
    std.mem.writeInt(u16, out[4..6], welcome.max_version, .little);
    std.mem.writeInt(u32, out[6..10], welcome.capabilities, .little);
    return out;
}

pub fn decodeWelcome(bytes: []const u8) error{BadLength}!Welcome {
    if (bytes.len != welcome_len) return error.BadLength;
    return .{
        .version = std.mem.readInt(u16, bytes[0..2], .little),
        .min_version = std.mem.readInt(u16, bytes[2..4], .little),
        .max_version = std.mem.readInt(u16, bytes[4..6], .little),
        .capabilities = std.mem.readInt(u32, bytes[6..10], .little),
    };
}

/// Pick the highest version both sides speak; `version` is 0 when there is
/// none. Capabilities are the intersection (none are defined yet).
pub fn negotiate(hello: Hello) Welcome {
    const low = @max(hello.min_version, min_protocol_version);
    const high = @min(hello.max_version, protocol_version);
    return .{
        .version = if (low <= high and low != 0) high else 0,
        .capabilities = hello.capabilities & 0,
    };
}

/// How a session's child ended, sent to attached clients before the daemon
/// closes their sockets. `code` and `signal` are what `waitpid` reported --
/// a signalled child has a non-zero `signal` and a `code` of 0 -- while
/// `reason` says what brought it about. On the wire: code u8, signal u8,
/// reason u8, then five reserved zero bytes.
pub const Exit = struct {
    code: u8 = 0,
    signal: u8 = 0,
    reason: Reason = .natural,

    /// Kept as explicit integers: these cross the socket.
    pub const Reason = enum(u8) {
        /// The child ended on its own, by exiting or by a signal nobody here sent.
        natural = 0,
        /// Someone asked the daemon to end the session.
        requested = 1,
        /// The daemon could not continue and took the child with it.
        daemon_failure = 2,
        /// The child never started: exec failed.
        exec_failure = 3,
        _,
    };
};

pub const exit_len = 8;

pub fn encodeExit(status: Exit) [exit_len]u8 {
    var out = [_]u8{0} ** exit_len;
    out[0] = status.code;
    out[1] = status.signal;
    out[2] = @intFromEnum(status.reason);
    return out;
}

pub fn decodeExit(bytes: []const u8) error{BadLength}!Exit {
    if (bytes.len != exit_len) return error.BadLength;
    return .{
        .code = bytes[0],
        .signal = bytes[1],
        .reason = @enumFromInt(bytes[2]),
    };
}

/// Split a POSIX wait status into what the wire carries.
pub fn exitFromWaitStatus(status: u32, reason: Exit.Reason) Exit {
    // The low 7 bits name a signal; a zero there means the child exited and
    // the next 8 bits are its code.
    const sig: u8 = @truncate(status & 0x7f);
    if (sig != 0) return .{ .code = 0, .signal = sig, .reason = reason };
    return .{ .code = @truncate((status >> 8) & 0xff), .signal = 0, .reason = reason };
}

pub const Info = extern struct {
    clients_len: u64,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [MAX_CMD_LEN]u8,
    cwd: [MAX_CWD_LEN]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
};

pub fn expectedLength(data: []const u8) ?usize {
    if (data.len < header_len) return null;
    const header = decodeHeader(data[0..header_len]);
    // A length past the cap is refused by the reader before it gets here;
    // returning null rather than a sum keeps the arithmetic in range even
    // where usize is 32 bits, where header_len + 0xFFFFFFFF would wrap.
    if (header.len > max_payload_len) return null;
    return @as(usize, header_len) + @as(usize, header.len);
}

fn payloadLen(data: []const u8) error{FrameTooLarge}!u32 {
    if (data.len > max_payload_len) return error.FrameTooLarge;
    return @intCast(data.len);
}

pub fn send(fd: i32, tag: Tag, data: []const u8) !void {
    const header_bytes = encodeHeader(tag, try payloadLen(data));
    try writeAll(fd, &header_bytes);
    if (data.len > 0) {
        try writeAll(fd, data);
    }
}

pub fn appendMessage(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tag: Tag,
    data: []const u8,
) !void {
    const header_bytes = encodeHeader(tag, try payloadLen(data));
    // Guarantee capacity for header + payload in one check to avoid
    // intermediate realloc between the two appends on the hot path.
    try list.ensureTotalCapacity(gpa, list.items.len + header_len + data.len);
    list.appendSliceAssumeCapacity(&header_bytes);
    if (data.len > 0) {
        list.appendSliceAssumeCapacity(data);
    }
}

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try lib_posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

pub const Message = struct {
    tag: Tag,
    data: []u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) {
            alloc.free(self.data);
        }
    }
};

pub const SocketMsg = struct {
    header: Header,
    payload: []const u8,
};

pub const SocketBuffer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
            .head = 0,
        };
    }

    pub fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    /// Reads from fd into buffer.
    /// Returns number of bytes read.
    /// Propagates error.WouldBlock and other errors to caller.
    /// Returns 0 on EOF.
    /// Returns error.FrameTooLarge once the pending frame's header announces
    /// a payload over `max_payload_len`; the caller should drop the peer.
    pub fn read(self: *SocketBuffer, fd: i32) !usize {
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try lib_posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
            try self.checkPendingFrame();
        }
        return n;
    }

    /// Rejects an oversized frame the moment its header has arrived, whichever
    /// frame in the buffer it belongs to: one read can carry several frames,
    /// and checking only the one at `head` would let a violating header sit
    /// unnoticed behind a valid frame until some later read happened to look.
    fn checkPendingFrame(self: *SocketBuffer) error{FrameTooLarge}!void {
        var offset = self.head;
        while (self.buf.items.len - offset >= header_len) {
            const header = decodeHeader(self.buf.items[offset..][0..header_len]);
            if (header.len > max_payload_len) return error.FrameTooLarge;
            const total = header_len + @as(usize, header.len);
            if (self.buf.items.len - offset < total) return;
            offset += total;
        }
    }

    /// Returns the next complete message or `null` when none available.
    /// `buf` is advanced automatically; caller keeps the returned slices
    /// valid until the following `next()` (or `deinit`).
    pub fn next(self: *SocketBuffer) ?SocketMsg {
        const available = self.buf.items[self.head..];
        const total = expectedLength(available) orelse return null;
        if (available.len < total) return null;

        const hdr = decodeHeader(available[0..header_len]);
        const pay = available[header_len..total];

        self.head += total;
        return .{ .header = hdr, .payload = pay };
    }
};

const ConnectError = error{
    ConnectionRefused,
    Unexpected,
};

/// Connect-only liveness check. Callers that don't read `Info` should use
/// this (not `probeSession`) so they survive `Info` shape changes.
pub fn connectSession(socket_path: []const u8) ConnectError!i32 {
    return socket.sessionConnect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
}

const SessionProbeError = error{
    Timeout,
    ConnectionRefused,
    Unexpected,
    InfoSizeMismatch,
};

const SessionProbeResult = struct {
    fd: i32,
    info: Info,
    labels: ?[]const u8,
    /// What the daemon answered to a Hello spanning every version this
    /// build speaks; null from a daemon that predates negotiation.
    protocol: ?Welcome,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *const SessionProbeResult) void {
        if (self.labels) |lbl| self.alloc.free(lbl);
        lib_posix.close(self.fd);
    }
};

pub fn probeSession(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
) SessionProbeError!SessionProbeResult {
    const timeout_ms = 1000;
    const fd = try connectSession(socket_path);
    errdefer lib_posix.close(fd);

    send(fd, .Info, "") catch return error.Unexpected;
    send(fd, .LabelGet, "") catch {};
    // Last, so a daemon that did not know the tag has already answered the
    // two it did. (A daemon ignores a tag it does not know; this only
    // orders the replies.) The range is everything this build speaks, so
    // the Welcome says what the daemon does, not whether we overlap.
    var hello_buf: [max_hello_len]u8 = undefined;
    if (encodeHello(&hello_buf, .{
        .min_version = min_protocol_version,
        .max_version = protocol_version,
        .client = "probe",
    })) |hello| {
        send(fd, .Hello, hello) catch {};
    } else |_| {}

    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const poll_result = lib_posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) {
        return error.Timeout;
    }

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    var info_result: ?Info = null;
    var labels: ?[]const u8 = null;
    var protocol: ?Welcome = null;
    errdefer if (labels) |lbl| alloc.free(lbl);

    while (true) {
        if (sb.next()) |msg| {
            if (msg.header.tag == .Info) {
                if (msg.payload.len != @sizeOf(Info)) return error.InfoSizeMismatch;
                info_result = std.mem.bytesToValue(Info, msg.payload[0..@sizeOf(Info)]);
            }
            if (msg.header.tag == .LabelData) {
                labels = alloc.dupe(u8, msg.payload) catch null;
            }
            if (msg.header.tag == .Welcome) {
                protocol = decodeWelcome(msg.payload) catch null;
            }

            if (info_result != null and labels != null and protocol != null) break;
            continue;
        }

        // No complete message available, wait for more data. A daemon
        // answers everything it understands in one flush, so once Info and
        // labels are here a Welcome that has not arrived is not coming
        // (the daemon predates it): one short poll, not the full wait,
        // or every old session would cost 50 ms per list.
        const wait_ms: i32 = if (info_result != null and labels != null) 2 else 50;
        const more = lib_posix.poll(&poll_fds, wait_ms) catch break;
        if (more == 0) break;
        const n_read = sb.read(fd) catch break;
        if (n_read == 0) break;
    }

    if (info_result) |info| {
        return .{
            .fd = fd,
            .info = info,
            .labels = labels,
            .protocol = protocol,
            .alloc = alloc,
        };
    }
    return error.Unexpected;
}

//  WIRE PROTOCOL FREEZE: read before "fixing" any test below.
//
//  Changing these constants does not fix the test; it breaks every
//  running daemon for every user until they `pkill -f zmx`.
//
//  Need a new field?   → add a new `Tag` value (next free integer).
//  Need to remove one? → don't. Reserve the integer, stop sending it.
test "Info wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 552), @sizeOf(Info));
    // The 8-byte envelope predates the explicit codec: packed struct{u8,u32}
    // backed to u40 and @sizeOf rounded to 8, so the codec keeps 3 reserved
    // zero bytes rather than shrinking the header.
    try std.testing.expectEqual(@as(usize, 8), header_len);
}

// Measured with `std.mem.asBytes` on aarch64 and x86_64 little-endian in
// Debug, ReleaseSafe, and ReleaseFast before the explicit codec existed:
// Header is tag byte, u32 little-endian length, three zero bytes; Resize is
// four u16 little-endian fields. These bytes are the wire contract now, not
// whatever `packed struct` happens to emit.
test "Header wire bytes are frozen" {
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00 },
        &encodeHeader(.Resize, 0x01020304),
    );
    const decoded = decodeHeader(&.{ 0x01, 0x05, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(Tag.Output, decoded.tag);
    try std.testing.expectEqual(@as(u32, 5), decoded.len);
    // Reserved bytes are ignored on decode.
    const padded = decodeHeader(&.{ 0x01, 0x05, 0, 0, 0, 0xde, 0xad, 0xbe });
    try std.testing.expectEqual(@as(u32, 5), padded.len);
    // An integer outside the enum decodes to itself; `_` arms must handle it.
    const unknown = decodeHeader(&.{ 200, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 200), @intFromEnum(unknown.tag));
}

test "Resize wire bytes are frozen" {
    const size = Resize{ .rows = 24, .cols = 80, .xpixel = 0x0102, .ypixel = 0x0304 };
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x18, 0x00, 0x50, 0x00, 0x02, 0x01, 0x04, 0x03 },
        &encodeResize(size),
    );
    const decoded = try decodeResize(&.{ 0x18, 0x00, 0x50, 0x00, 0x02, 0x01, 0x04, 0x03 });
    try std.testing.expectEqual(size, decoded);
    try std.testing.expectError(error.BadLength, decodeResize(&.{ 0x18, 0x00, 0x50 }));
    try std.testing.expectError(error.BadLength, decodeResize(&([_]u8{0} ** 9)));
}

test "appendMessage frames a payload and SocketBuffer reassembles it" {
    const alloc = std.testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(alloc);
    try appendMessage(alloc, &wire, .Output, "hello");
    try appendMessage(alloc, &wire, .Detach, "");
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x05, 0, 0, 0, 0, 0, 0, 'h', 'e', 'l', 'l', 'o', 0x03, 0, 0, 0, 0, 0, 0, 0 },
        wire.items,
    );

    // Feed the bytes through the reader one byte at a time: frames must
    // only surface once complete, and must survive any fragmentation.
    var sb = try SocketBuffer.init(alloc);
    defer sb.deinit();
    var seen: usize = 0;
    for (wire.items, 0..) |b, i| {
        try sb.buf.append(alloc, b);
        try sb.checkPendingFrame();
        while (sb.next()) |msg| {
            seen += 1;
            if (seen == 1) {
                try std.testing.expectEqual(Tag.Output, msg.header.tag);
                try std.testing.expectEqualStrings("hello", msg.payload);
                try std.testing.expectEqual(@as(usize, 12), i);
            } else {
                try std.testing.expectEqual(Tag.Detach, msg.header.tag);
                try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
                try std.testing.expectEqual(@as(usize, 20), i);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "oversized frame header is rejected before its payload arrives" {
    const alloc = std.testing.allocator;
    var sb = try SocketBuffer.init(alloc);
    defer sb.deinit();
    try sb.buf.appendSlice(alloc, &encodeHeader(.Output, max_payload_len));
    try sb.checkPendingFrame();
    sb.buf.clearRetainingCapacity();
    try sb.buf.appendSlice(alloc, &encodeHeader(.Output, max_payload_len + 1));
    try std.testing.expectError(error.FrameTooLarge, sb.checkPendingFrame());

    // A violating header hiding behind a complete frame is caught in the
    // same read, not left for a later one that may never come.
    sb.buf.clearRetainingCapacity();
    try appendMessage(alloc, &sb.buf, .Output, "hi");
    try sb.buf.appendSlice(alloc, &encodeHeader(.Output, max_payload_len + 1));
    try std.testing.expectError(error.FrameTooLarge, sb.checkPendingFrame());
    // And an oversized length never reaches expectedLength's arithmetic.
    try std.testing.expectEqual(@as(?usize, null), expectedLength(&encodeHeader(.Output, max_payload_len + 1)));
    // The encoder refuses to announce what the reader would reject.
    var too_big: []const u8 = &.{};
    too_big.len = max_payload_len + 1;
    try std.testing.expectError(error.FrameTooLarge, payloadLen(too_big));
}

test "Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Input, 0 },         .{ Tag.Output, 1 },        .{ Tag.Resize, 2 },
        .{ Tag.Detach, 3 },        .{ Tag.DetachAll, 4 },     .{ Tag.Kill, 5 },
        .{ Tag.Info, 6 },          .{ Tag.Init, 7 },          .{ Tag.History, 8 },
        .{ Tag.Run, 9 },           .{ Tag.Ack, 10 },          .{ Tag.Switch, 11 },
        .{ Tag.Write, 12 },        .{ Tag.TaskComplete, 13 }, .{ Tag.LabelGet, 14 },
        .{ Tag.LabelSet, 15 },     .{ Tag.LabelClear, 16 },   .{ Tag.LabelData, 17 },
        .{ Tag.Send, 18 },         .{ Tag.Hello, 19 },        .{ Tag.Welcome, 20 },
        .{ Tag.RestoreBegin, 21 }, .{ Tag.Ready, 22 },        .{ Tag.Exit, 23 },
        .{ Tag.EnvGet, 26 }, .{ Tag.EnvSet, 27 }, .{ Tag.EnvData, 28 }, .{ Tag.Capture, 29 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @intFromEnum(p[0]));
}

test "Capture wire bytes are explicit little endian" {
    const bytes = [_]u8{ 2, 0x78, 0x56, 0x34, 0x12, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &bytes, &encodeCapture(.{ .format = 2, .rows = 0x12345678 }));
    const decoded = try decodeCapture(&bytes);
    try std.testing.expectEqual(@as(u8, 2), decoded.format);
    try std.testing.expectEqual(@as(u32, 0x12345678), decoded.rows);
    try std.testing.expectError(error.BadLength, decodeCapture(bytes[0..7]));
}

test "Exit wire bytes are frozen" {
    try std.testing.expectEqualSlices(
        u8,
        &.{ 7, 0, 0, 0, 0, 0, 0, 0 },
        &encodeExit(.{ .code = 7 }),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 9, 1, 0, 0, 0, 0, 0 },
        &encodeExit(.{ .signal = 9, .reason = .requested }),
    );
    const decoded = try decodeExit(&.{ 7, 0, 3, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 7), decoded.code);
    try std.testing.expectEqual(Exit.Reason.exec_failure, decoded.reason);
    // An unknown reason decodes rather than trapping: this enum comes off the wire.
    const future = try decodeExit(&.{ 0, 0, 200, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u8, 200), @intFromEnum(future.reason));
    try std.testing.expectError(error.BadLength, decodeExit(&.{ 0, 0, 0 }));
}

test "wait status splits into code or signal" {
    // Exited with 7: code in the high byte, no signal.
    const exited = exitFromWaitStatus(7 << 8, .natural);
    try std.testing.expectEqual(@as(u8, 7), exited.code);
    try std.testing.expectEqual(@as(u8, 0), exited.signal);
    // Killed by SIGKILL: signal in the low bits, code zero.
    const killed = exitFromWaitStatus(9, .requested);
    try std.testing.expectEqual(@as(u8, 0), killed.code);
    try std.testing.expectEqual(@as(u8, 9), killed.signal);
    try std.testing.expectEqual(Exit.Reason.requested, killed.reason);
}

test "Hello wire bytes are frozen" {
    var buf: [max_hello_len]u8 = undefined;
    const bytes = try encodeHello(&buf, .{ .min_version = 1, .max_version = 0x0102, .capabilities = 0x04030201, .client = "fmx" });
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x00, 0x02, 0x01, 0x01, 0x02, 0x03, 0x04, 'f', 'm', 'x' },
        bytes,
    );
    const decoded = try decodeHello(bytes);
    try std.testing.expectEqual(@as(u16, 1), decoded.min_version);
    try std.testing.expectEqual(@as(u16, 0x0102), decoded.max_version);
    try std.testing.expectEqual(@as(u32, 0x04030201), decoded.capabilities);
    try std.testing.expectEqualStrings("fmx", decoded.client);
    // A nameless client is legal.
    const bare = try decodeHello(&.{ 1, 0, 1, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), bare.client.len);
    try std.testing.expectError(error.BadLength, decodeHello(&.{ 1, 0, 1, 0 }));
    try std.testing.expectError(error.NameTooLong, decodeHello(&([_]u8{0} ** (max_hello_len + 1))));
    try std.testing.expectError(error.NameTooLong, encodeHello(&buf, .{ .min_version = 1, .max_version = 1, .client = "x" ** (max_client_name_len + 1) }));
}

test "Welcome wire bytes are frozen" {
    const welcome = Welcome{ .version = 1, .min_version = 1, .max_version = 0x0102, .capabilities = 0x04030201 };
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x00, 0x01, 0x00, 0x02, 0x01, 0x01, 0x02, 0x03, 0x04 },
        &encodeWelcome(welcome),
    );
    try std.testing.expectEqual(welcome, try decodeWelcome(&encodeWelcome(welcome)));
    try std.testing.expectError(error.BadLength, decodeWelcome(&.{ 1, 0 }));
    try std.testing.expect(!(Welcome{ .version = 0 }).accepted());
    // The refusal a client must be able to recognize, byte for byte.
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 },
        &encodeWelcome(.{ .version = 0 }),
    );
    // Constants fmx pins on its side of the wire.
    try std.testing.expectEqual(@as(u16, 1), protocol_version);
    try std.testing.expectEqual(@as(u16, 1), min_protocol_version);
    try std.testing.expectEqual(@as(usize, 64), max_client_name_len);
    try std.testing.expectEqual(@as(u32, 16 * 1024 * 1024), max_payload_len);
    try std.testing.expectEqual(@as(usize, 8), exit_len);
}

test "negotiate picks the highest shared version or rejects" {
    const exact = negotiate(.{ .min_version = 1, .max_version = 1, .client = "" });
    try std.testing.expectEqual(protocol_version, exact.version);
    try std.testing.expect(exact.accepted());
    // A client that also speaks newer versions lands on ours.
    try std.testing.expectEqual(protocol_version, negotiate(.{ .min_version = 1, .max_version = 9, .client = "" }).version);
    // A client that only speaks newer versions is rejected, and told ours.
    const newer = negotiate(.{ .min_version = protocol_version + 1, .max_version = protocol_version + 2, .client = "" });
    try std.testing.expect(!newer.accepted());
    try std.testing.expectEqual(min_protocol_version, newer.min_version);
    try std.testing.expectEqual(protocol_version, newer.max_version);
    // Version 0 is "rejected", never a version a client may claim.
    try std.testing.expect(!negotiate(.{ .min_version = 0, .max_version = 0, .client = "" }).accepted());
    // Inverted ranges are rejected.
    try std.testing.expect(!negotiate(.{ .min_version = 2, .max_version = 1, .client = "" }).accepted());
}

pub fn roundTripForTag(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    request_tag: Tag,
    payload: []const u8,
    expected_tag: Tag,
) SessionProbeError![]u8 {
    const timeout_ms = 1000;
    const fd = try connectSession(socket_path);
    defer lib_posix.close(fd);

    send(fd, request_tag, payload) catch return error.Unexpected;

    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const poll_result = lib_posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) return error.Timeout;

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    while (sb.next()) |msg| {
        if (msg.header.tag == expected_tag) {
            return alloc.dupe(u8, msg.payload) catch return error.Unexpected;
        }
    }
    return error.Unexpected;
}

test "zeroed Info has no stack garbage in wire bytes" {
    var info = std.mem.zeroes(Info);
    info.clients_len = 3;
    info.pid = 999;
    info.task_exit_code = 7;
    const bytes = std.mem.asBytes(&info);
    // Tail padding after task_exit_code must be zero (asBytes ships it).
    const last_field_end = @offsetOf(Info, "task_exit_code") + @sizeOf(u8);
    for (bytes[last_field_end..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
