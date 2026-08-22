const std = @import("std");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const socket = @import("socket.zig");
const ipc = @import("ipc.zig");
const assert = std.debug.assert;
const log = @import("log.zig");
const cross = @import("cross.zig");

const Cmd = struct {
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
};

pub fn createCmdZ(def_shell: []const u8, is_task_mode: bool, command: ?[]const []const u8) !Cmd {
    const gpa = std.heap.c_allocator;

    if (command) |cmd_args| {
        const argv = try gpa.allocSentinel(?[*:0]const u8, cmd_args.len, null);
        for (cmd_args, 0..) |arg, i| {
            argv[i] = try gpa.dupeZ(u8, arg);
        }
        return .{
            .file = argv[0].?,
            .argv_ptr = argv.ptr,
        };
    }

    const z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{def_shell}, 0);
    const shell: [:0]const u8 = if (is_task_mode) "bash" else z;

    // Use "-shellname" as argv[0] to signal login shell (traditional method)
    const login_shell = try std.fmt.allocPrintSentinel(gpa, "-{s}", .{std.fs.path.basename(shell)}, 0);
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = login_shell.ptr;

    return .{
        .file = shell,
        .argv_ptr = argv,
    };
}

/// What the creating process learns about the session it asked for. The
/// daemon writes it once to the startup pipe after the pty child has crossed
/// `exec` (or failed to), so the creator returns on an acknowledged fact
/// rather than a sleep. It crosses the pipe as one byte of kind, four bytes
/// of little-endian pid, then the error name when there is one.
pub const Startup = union(enum) {
    /// The child is running; this is its pid.
    ready: i32,
    /// The child could not be started; the name says why (e.g.
    /// `FileNotFound`). The daemon still runs its teardown, so nothing is
    /// left behind.
    exec_failed: []const u8,
    /// The daemon closed the pipe without reporting: it died before the
    /// pty was set up. Its own error path removes the socket.
    daemon_failed,
    /// No report within the deadline. The session may still come up, so
    /// the creator must not remove anything.
    timeout,

    const kind_ready: u8 = 0;
    const kind_exec_failed: u8 = 1;
    /// Enough for the kind, the pid, and any Zig error name.
    pub const max_len = 1 + 4 + 64;
};

pub const Outcome = union(enum) {
    /// This process is the daemon and owns the pty.
    daemon: PtyInfo,
    /// This process asked for the session; this is what it was told.
    creator: Startup,
};

/// Runs in the forked child. Either execs or returns an error (caller
/// must exit on error -- returning would fall through to parent code).
fn exec(sesh_name: []const u8, cmd: Cmd) !noreturn {
    const gpa = std.heap.c_allocator;

    // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
    // exec. Restore the default so the shell and its children behave
    // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
    const dfl: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.DFL },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);

    const session_env = try std.fmt.allocPrintSentinel(
        gpa,
        "ZMX_SESSION={s}",
        .{sesh_name},
        0,
    );
    _ = cross.c.putenv(session_env.ptr);

    if (cross.c.getenv("TERM")) |term_env| {
        if (std.mem.eql(u8, std.mem.span(term_env), "dumb")) {
            _ = cross.c.putenv(@constCast("TERM=xterm-256color"));
        }
    } else {
        _ = cross.c.putenv(@constCast("TERM=xterm-256color"));
    }

    const err = lib_posix.execvpeZ(cmd.file, cmd.argv_ptr, std.c.environ);
    std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd.file, @errorName(err) });
    return err;
}

pub const PtyInfo = struct {
    master_fd: c_int = undefined,
    pid: c_int = undefined,
    /// The child's error name when it reported a failed exec instead of
    /// crossing it; empty when it is running. A child that failed has
    /// already exited, and the daemon runs its ordinary teardown.
    exec_err: []const u8 = "",
};

/// Writes every byte or gives up: a short pipe write here would hand the
/// reader a truncated error name, which is worse than none.
fn writeAll(fd: i32, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = lib_posix.write(fd, rest) catch return;
        if (n == 0) return;
        rest = rest[n..];
    }
}

/// Reads until EOF or the buffer is full. EOF is the signal on both pipes:
/// the exec pipe closes when the child execs (CLOEXEC) or exits, the startup
/// pipe when the daemon has said its piece.
fn readUntilEof(fd: i32, buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len) {
        const n = lib_posix.read(fd, buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    return len;
}

/// spawnPty runs forkpty() and executes the shell or shell command the user
/// provides.
///
/// This is the second fork in the double-fork technique explained in the
/// daemonize() comment.
pub fn spawnPty(sesh_name: []const u8, cmd: Cmd, size: ipc.Resize, exec_err_buf: *[Startup.max_len]u8) !PtyInfo {
    var ws: cross.c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    // Close-on-exec, so a successful exec closes the write end and the
    // daemon reads EOF; a failed one writes its error name first. This is
    // how the daemon knows the child crossed exec rather than guessing.
    const exec_pipe = try lib_posix.pipe2(.{ .CLOEXEC = true });

    var master_fd: c_int = undefined;
    const pid = cross.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) {
        lib_posix.close(exec_pipe[0]);
        lib_posix.close(exec_pipe[1]);
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        lib_posix.close(exec_pipe[0]);
        // In the forked child, ANY error must exit rather than propagate:
        // a returned error falls through to the parent code path below,
        // running a second daemon on the same socket (or worse, hitting
        // errdefers that delete the parent's socket file).
        exec(sesh_name, cmd) catch |err| {
            std.log.err("child setup failed: {s}", .{@errorName(err)});
            writeAll(exec_pipe[1], @errorName(err));
            lib_posix.exit(1);
        };
        unreachable; // exec() either execs or exits, never returns ok
    }
    // master pid code path
    lib_posix.close(exec_pipe[1]);
    const exec_err_len = readUntilEof(exec_pipe[0], exec_err_buf);
    lib_posix.close(exec_pipe[0]);
    const exec_err = exec_err_buf[0..exec_err_len];
    if (exec_err.len > 0) {
        std.log.err(
            "pty child failed to exec session={s} pid={d} err={s}",
            .{ sesh_name, pid, exec_err },
        );
    } else {
        std.log.info("pty spawned session={s} pid={d}", .{ sesh_name, pid });
    }

    // make pty non-blocking
    const flags = try lib_posix.fcntl(master_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(master_fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);

    return .{
        .master_fd = master_fd,
        .pid = pid,
        .exec_err = exec_err,
    };
}

/// Encodes what the daemon tells its creator. `exec_err` is the child's
/// error name when the exec failed, empty otherwise.
fn encodeStartup(buf: *[Startup.max_len]u8, pid: i32, exec_err: []const u8) []const u8 {
    buf[0] = if (exec_err.len > 0) Startup.kind_exec_failed else Startup.kind_ready;
    std.mem.writeInt(u32, buf[1..5], @bitCast(pid), .little);
    const name_len = @min(exec_err.len, buf.len - 5);
    @memcpy(buf[5 .. 5 + name_len], exec_err[0..name_len]);
    return buf[0 .. 5 + name_len];
}

/// Waits on the startup pipe for the daemon's report, no longer than
/// `timeout_ms`. `name_buf` receives the error name, so the returned
/// `Startup` can point into it.
fn awaitStartup(fd: i32, timeout_ms: u32, name_buf: *[Startup.max_len]u8) Startup {
    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const ready = lib_posix.poll(&poll_fds, @intCast(timeout_ms)) catch return .daemon_failed;
    if (ready == 0) return .timeout;

    var raw: [Startup.max_len]u8 = undefined;
    const len = readUntilEof(fd, &raw);
    if (len < 5) return .daemon_failed;
    const pid: i32 = @bitCast(std.mem.readInt(u32, raw[1..5], .little));
    switch (raw[0]) {
        Startup.kind_ready => return .{ .ready = pid },
        Startup.kind_exec_failed => {
            const name_len = len - 5;
            @memcpy(name_buf[0..name_len], raw[5..len]);
            return .{ .exec_failed = name_buf[0..name_len] };
        },
        else => return .daemon_failed,
    }
}

test "startup report round-trips ready and a failed exec" {
    var buf: [Startup.max_len]u8 = undefined;
    const ready = encodeStartup(&buf, 4242, "");
    try std.testing.expectEqual(@as(usize, 5), ready.len);
    try std.testing.expectEqual(Startup.kind_ready, ready[0]);
    try std.testing.expectEqual(@as(u32, 4242), std.mem.readInt(u32, ready[1..5], .little));

    const failed = encodeStartup(&buf, 7, "FileNotFound");
    try std.testing.expectEqual(Startup.kind_exec_failed, failed[0]);
    try std.testing.expectEqualStrings("FileNotFound", failed[5..]);
}

test "startup report crosses a real pipe and honours its deadline" {
    const fds = try lib_posix.pipe2(.{ .CLOEXEC = true });
    var name_buf: [Startup.max_len]u8 = undefined;

    // Nothing written yet: the deadline, not a hang.
    try std.testing.expectEqual(Startup.timeout, awaitStartup(fds[0], 20, &name_buf));

    var buf: [Startup.max_len]u8 = undefined;
    writeAll(fds[1], encodeStartup(&buf, 99, "AccessDenied"));
    lib_posix.close(fds[1]);
    const report = awaitStartup(fds[0], 1000, &name_buf);
    try std.testing.expectEqualStrings("AccessDenied", report.exec_failed);
    lib_posix.close(fds[0]);

    // A daemon that dies before reporting closes the pipe empty.
    const empty = try lib_posix.pipe2(.{ .CLOEXEC = true });
    lib_posix.close(empty[1]);
    try std.testing.expectEqual(Startup.daemon_failed, awaitStartup(empty[0], 1000, &name_buf));
    lib_posix.close(empty[0]);
}

/// daemonize is the first fork in a double-fork technique to create a
/// completely disconnected session (container of process groups).
///
/// When launching a daemon, you normally set the child process of the fork to
/// be the session leader via setsid() which creates a new session that removes
/// the current controlling terminal. This is important because we don't want a
/// controlling terminal for our daemon or else it could receive signals to
/// shutdown when the controlling terminal closes.
///
/// However, if the first fork's child process is also the daemon process, then
/// it's technically possible for the daemon to open a terminal device (e.g.
/// open("/dev/console", O_RDWR)) and then it would acquire a controlling
/// terminal! A controlling terminal would expose the daemon to
/// terminal-generated signals (e.g. SIGINT) or SIGHUP from terminal disconnect
/// which could kill the daemon.
///
/// The first fork produces a child guaranteed not to be a group leader, so
/// setsid() will succeed.  By forking a second time, the grandchild process
/// (the daemon) is not the session leader. Per POSIX, only a process that is
/// the session leader can acquire a controlling terminal.
///
/// Apparently this is "a bit paranoid" and on Linux it is arguable since a
/// session leader only acquires a controlling terminal under
/// implementation-defined conditions. But the double-fork is the portable way
/// to guarantee the daemon can never acquire one, regardless of how a given
/// POSIX implementation behaves. So we baked it into zmx.
///
/// PID=42  SID=10  PGID=10  ← original (PG leader, has tty)
///     │
///     │  fork #1
///     ├──────────┐
///     │ exit     │ PID=55  SID=10  PGID=10  (not a PG leader)
///     ✝          │
///                │ setsid()
///                ▼
///               PID=55  SID=55  PGID=55  (session leader, no tty)
///                 │
///                 │  fork #2
///                 ├──────────┐
///                 │ exit     │ PID=73  SID=55  PGID=55
///                 ✝          │ PID≠SID → can't get a tty
///                            ▼
///                          DAEMON ✓
///
/// The creating process does not return until the daemon has reported over a
/// startup pipe that the pty child crossed `exec` (or how it failed), or until
/// `startup_timeout_ms` has passed. Returning on a fixed sleep instead meant a
/// release build could reach the child before the first client connected, and
/// a command that could not start looked exactly like one that could.
pub fn daemonize(
    sesh_name: []const u8,
    cmd: Cmd,
    keep_fds_open: []const i32,
    startup_timeout_ms: u32,
    name_buf: *[Startup.max_len]u8,
) !Outcome {
    const startup = try lib_posix.pipe2(.{ .CLOEXEC = true });

    // creates the daemon
    const pid = lib_posix.fork() catch |err| {
        lib_posix.close(startup[0]);
        lib_posix.close(startup[1]);
        return err;
    };
    assert(pid != -1);

    if (pid > 0) { // parent (client)
        lib_posix.close(startup[1]);
        defer lib_posix.close(startup[0]);
        return .{ .creator = awaitStartup(startup[0], startup_timeout_ms, name_buf) };
    }

    assert(pid == 0); // child (daemon's parent in double-fork)
    lib_posix.close(startup[0]);
    // Closed on every path out of here: an empty close tells the creator the
    // daemon died before the pty was set up.
    defer lib_posix.close(startup[1]);

    // The creator's keep list plus the pipe it is waiting on.
    var keep_buf: [16]i32 = undefined;
    assert(keep_fds_open.len < keep_buf.len);
    @memcpy(keep_buf[0..keep_fds_open.len], keep_fds_open);
    keep_buf[keep_fds_open.len] = startup[1];
    const keep_all = keep_buf[0 .. keep_fds_open.len + 1];

    // becomes the session leader and detaches process from its controlling terminal
    _ = try lib_posix.setsid();

    // Fetch terminal size before redirecting stdio FDs to /dev/null.
    const term_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);

    // Redirect stdin/stdout/stderr to /dev/null. The daemon
    // communicates via its unix socket, not stdio. Without
    // this, any pipe on FDs 0-2 (e.g. from bats' `run`
    // keyword) stays open for the daemon's lifetime, causing
    // the caller to hang waiting for EOF.
    {
        const devnull = lib_posix.open(
            "/dev/null",
            .{ .ACCMODE = .RDWR },
            0,
        ) catch |err| {
            std.log.warn("failed to open /dev/null: {s}", .{@errorName(err)});
            return err;
        };
        inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |fd| {
            _ = lib_posix.dup2(devnull, fd) catch |err| {
                std.log.warn("dup2 /dev/null -> {d}: {s}", .{ fd, @errorName(err) });
                return err;
            };
        }
        var found = false;
        for (keep_all) |fd| {
            if (devnull == fd) found = true;
        }
        if (devnull > 2 and !found) lib_posix.close(devnull);
    }

    // Close file descriptors inherited from the parent that the
    // daemon doesn't need. This prevents test harnesses (like
    // bats) from hanging: they wait for their internal FDs (3+)
    // to close before exiting.
    //
    // Skip any fds that the caller wants to keep open, e.g. server_sock_fd
    // (needed for IPC) and dir.fd (needed to delete the socket file on
    // shutdown).
    {
        var fd: i32 = 3;
        while (fd < 64) : (fd += 1) {
            var found = false;
            for (keep_all) |kfd| {
                if (fd == kfd) found = true;
            }
            if (!found) _ = std.c.close(fd);
        }
    }

    const pty_info = try spawnPty(sesh_name, cmd, term_size, name_buf);
    var report_buf: [Startup.max_len]u8 = undefined;
    writeAll(startup[1], encodeStartup(&report_buf, pty_info.pid, pty_info.exec_err));
    return .{ .daemon = pty_info };
}
