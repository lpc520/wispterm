const std = @import("std");

pub const DirectoryWatcher = struct {
    dir: std.fs.Dir,
    kq_fd: i32,
    active: bool,

    pub fn initPath(dir_path: []const u8) ?DirectoryWatcher {
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return null;
        errdefer dir.close();

        const kq_fd = std.posix.kqueue() catch return null;
        errdefer std.posix.close(kq_fd);

        var self = DirectoryWatcher{
            .dir = dir,
            .kq_fd = kq_fd,
            .active = false,
        };
        self.startWatch();
        return self;
    }

    fn startWatch(self: *DirectoryWatcher) void {
        const NOTE = std.c.NOTE;
        const EV = std.c.EV;
        const changes = [1]std.posix.Kevent{.{
            .ident = @bitCast(@as(isize, self.dir.fd)),
            .filter = std.c.EVFILT.VNODE,
            .flags = EV.ADD | EV.ENABLE | EV.CLEAR,
            .fflags = NOTE.DELETE | NOTE.WRITE | NOTE.EXTEND | NOTE.ATTRIB | NOTE.RENAME | NOTE.REVOKE,
            .data = 0,
            .udata = 0,
        }};
        _ = std.posix.kevent(self.kq_fd, &changes, &.{}, null) catch {
            self.active = false;
            return;
        };
        self.active = true;
    }

    pub fn hasChanged(self: *DirectoryWatcher) bool {
        if (!self.active) return false;

        var timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        var events: [8]std.posix.Kevent = undefined;
        const count = std.posix.kevent(self.kq_fd, &.{}, &events, &timeout) catch {
            self.active = false;
            return false;
        };
        return count > 0;
    }

    pub fn deinit(self: *DirectoryWatcher) void {
        std.posix.close(self.kq_fd);
        self.dir.close();
    }
};
