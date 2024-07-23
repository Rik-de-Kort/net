const std = @import("std");
const net = @import("std.net");

const Server = struct {
    allocator: std.mem.Allocator,
    users: std.ArrayList(User),

    pub const UserType = enum { server, connected, joined };

    const User = struct {
        kind: UserType,
        stream: std.net.Stream,
        fifo: std.io.PollFifo,
        name: std.ArrayList(u8),

        pub fn deinit(self: *User) void {
            self.stream.close();
            self.fifo.deinit();
            self.name.deinit();
        }
    };

    const PollInfo = struct {
        new_data: std.ArrayList(usize),
        disconnected: std.ArrayList(usize),
    };

    pub fn init(allocator: std.mem.Allocator, server: std.net.Stream) !Server {
        var self = Server{
            .allocator = allocator,
            .users = std.ArrayList(User).init(allocator),
        };

        var name = std.ArrayList(u8).init(allocator);
        try name.appendSlice("SERVER");
        try self.users.append(User{ .kind = UserType.server, .stream = server, .name = name, .fifo = std.io.PollFifo.init(self.allocator) });
        return self;
    }

    pub fn deinit(self: *Server) void {
        for (self.users.items) |*user| {
            user.deinit();
        }
        self.users.deinit();
    }

    pub fn connect(self: *Server, stream: std.net.Stream) !usize {
        var name = std.ArrayList(u8).init(self.allocator);
        try name.appendSlice("[NO NAME]");
        try self.users.append(User{
            .kind = UserType.connected,
            .stream = stream,
            .fifo = std.io.PollFifo.init(self.allocator),
            .name = name,
        });
        return self.users.items.len - 1;
    }

    pub fn join(self: *Server, index: usize, name: std.ArrayList(u8)) !void {
        self.users.items[index].kind = UserType.joined;
        self.users.items[index].name = name;
    }

    pub fn debugGetName(self: Server, index: usize) []const u8 {
        return self.users.items[index].name.items;
    }

    pub fn debugPrintBufferStates(self: Server) void {
        std.debug.print("Here are the buffer states:\n", .{});
        for (0.., self.users.items) |i, *user| {
            const name = switch (user.kind) {
                .server => "server",
                .connected => "connected",
                .joined => self.debugGetName(i),
            };
            std.debug.print("{any} [{s}]: {s}\n", .{ i, name, user.fifo.readableSliceOfLen(user.fifo.count) });
        }
        std.debug.print("\n", .{});
    }

    pub fn poll(self: *Server, allocator: std.mem.Allocator) !PollInfo {
        var result = PollInfo{
            .new_data = std.ArrayList(usize).init(allocator),
            .disconnected = std.ArrayList(usize).init(allocator),
        };

        std.debug.print("\nPolling. ", .{});
        self.debugPrintBufferStates();

        var pollfds = try std.ArrayList(std.posix.pollfd).initCapacity(allocator, self.users.items.len);
        defer pollfds.deinit();

        const events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.OUT;
        for (self.users.items) |user| {
            pollfds.appendAssumeCapacity(.{ .fd = user.stream.handle, .events = events, .revents = 0 });
        }
        const events_len = try std.posix.poll(pollfds.items, -1);
        if (events_len == 0) {
            std.debug.print("No events\n", .{});
            return result;
        }

        for (0.., pollfds.items, self.users.items) |i, *poll_fd, *user| {
            std.debug.print("[{any}] IN: {any} OUT {any} HUP: {any} ERR: {any}\n", .{
                i,
                poll_fd.revents & std.posix.POLL.IN,
                poll_fd.revents & std.posix.POLL.OUT,
                poll_fd.revents & std.posix.POLL.HUP,
                poll_fd.revents & std.posix.POLL.ERR,
            });

            if (poll_fd.revents & std.posix.POLL.HUP != 0) {
                const buf = try user.fifo.writableWithSize(512);
                const n_bytes = try std.posix.read(poll_fd.fd, buf);
                if (n_bytes > 0) {
                    user.fifo.update(n_bytes);
                    try result.new_data.append(i);
                }
                try result.disconnected.append(i);
                std.debug.print("Disconnecting {any}\n", .{i});
            } else if (poll_fd.revents & std.posix.POLL.ERR != 0) {
                std.debug.print("Got error with poll {any}\n", .{poll_fd});
            } else if (poll_fd.revents & std.posix.POLL.IN != 0) {
                // Got a jammy bastard!
                if (i > 0) {
                    std.debug.print("Trying to read from {any} ({s})\n", .{ i, user.name.items });
                    const original_count = user.fifo.count;

                    const file_handle = std.fs.File{ .handle = poll_fd.fd };
                    const reader = file_handle.reader();
                    const writer = user.fifo.writer();
                    reader.streamUntilDelimiter(writer, '\n', null) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (user.fifo.count == original_count) { // No bytes, must be disconnected
                                try result.disconnected.append(i);
                                std.debug.print("Got no bytes, maybe disconnect {s}!\n", .{self.debugGetName(i)});
                            }
                            continue;
                        },
                        else => |e| return e,
                    };
                }
                try result.new_data.append(i);
            } else if (poll_fd.revents != 0) {
                std.debug.print("These events? {any}\n", .{poll_fd.revents});
            }
        }

        std.debug.print("\nFinished polling. ", .{});
        self.debugPrintBufferStates();
        return result;
    }

    pub fn broadcast(self: Server, from: ?usize, msg: []const u8) !void {
        for (0.., self.users.items) |i, user| {
            switch (user.kind) {
                .connected => continue,
                .server => continue,
                .joined => {
                    if (i == from) continue;
                    try self.send(i, msg);
                },
            }
        }
    }

    pub fn send(self: Server, to: usize, msg: []const u8) !void {
        std.debug.print("Sending message '{s}' to {any}\n", .{ msg, to });
        self.users.items[to].stream.writeAll(msg) catch |err| switch (err) {
            else => |e| {
                std.debug.print("Got error {any} to {s}\n", .{ err, self.debugGetName(to) });
                return e;
            },
        };
    }

    pub fn orderedRemove(self: *Server, index: usize) void {
        std.debug.print("Removing {any}\n", .{index});
        self.users.items[index].deinit();
        _ = self.users.orderedRemove(index);
    }
};

const BroadcastMessage = struct {
    msg: []const u8,
    from: ?usize,
};

const DirectMessage = struct {
    msg: []const u8,
    to: usize,
};

const MessageTag = enum { broadcast, direct };
const Message = union(MessageTag) { broadcast: BroadcastMessage, direct: DirectMessage };

// Todo:
// - Run this on protohackers and probably deal with edge cases: disconnects of non-joined users and the like
// - Refactor to use "communicate" instead of "poll" with pending messages

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{listener});

    var server = try Server.init(allocator, listener.stream);
    defer server.deinit();

    while (true) {
        var poll_info = try server.poll(allocator);
        var send_info = std.ArrayList(Message).init(allocator);
        defer send_info.deinit();

        for (poll_info.new_data.items) |index| {
            const this_user = server.users.items[index];
            switch (this_user.kind) {
                .server => {
                    const connection = try listener.accept();
                    const new_index = try server.connect(connection.stream);
                    try send_info.append(Message{ .direct = .{ .msg = "welcome to budget chat. What's your name?\n", .to = new_index } });
                },
                .connected => {
                    var name_buf: [17]u8 = undefined;
                    const n_bytes = server.users.items[index].fifo.read(&name_buf);
                    std.debug.print("Got {any} bytes {s}\n", .{ n_bytes, name_buf[0..n_bytes] });
                    if (n_bytes <= 0 or 17 <= n_bytes) {
                        try poll_info.disconnected.append(index);
                    }
                    for (name_buf[0..n_bytes]) |c| {
                        if (!std.ascii.isAlphanumeric(c)) {
                            try poll_info.disconnected.append(index);
                        }
                    }

                    // Fish out name so we can wrangle strings
                    var name = try std.ArrayList(u8).initCapacity(allocator, n_bytes);
                    try name.writer().writeAll(name_buf[0..n_bytes]);

                    // Send "x has joined the room" to everyone
                    var join_msg = try std.ArrayList(u8).initCapacity(allocator, n_bytes + 23);
                    try std.fmt.format(join_msg.writer(), "* {s} has joined the room\n", .{name_buf[0..n_bytes]});
                    try send_info.append(Message{ .broadcast = .{ .msg = join_msg.items, .from = index } });

                    // Send "room contains a, b, c" to joined user
                    var presence_msg = std.ArrayList(u8).init(allocator);
                    var just_names = try std.ArrayList([]const u8).initCapacity(allocator, server.users.items.len);
                    for (server.users.items) |user| {
                        switch (user.kind) {
                            .joined => try just_names.append(user.name.items),
                            else => {},
                        }
                    }
                    const user_list = try std.mem.join(allocator, ", ", just_names.items);

                    try std.fmt.format(presence_msg.writer(), "* active users are {s}\n", .{user_list});
                    try send_info.append(Message{ .direct = .{ .msg = presence_msg.items, .to = index } });

                    // Turn user into joined user
                    try server.join(index, name);
                },
                .joined => {
                    var message_buf: [1024]u8 = undefined;
                    const n_bytes = server.users.items[index].fifo.read(&message_buf);
                    if (n_bytes > 1000) {
                        try poll_info.disconnected.append(index);
                        continue;
                    }

                    var sent_msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(sent_msg.writer(), "[{s}] {s}\n", .{ server.users.items[index].name.items, message_buf[0..n_bytes] });
                    try send_info.append(Message{ .broadcast = .{ .msg = sent_msg.items, .from = index } });
                },
            }
        }

        for (send_info.items) |message| {
            switch (message) {
                MessageTag.direct => {
                    try server.send(message.direct.to, message.direct.msg);
                },
                MessageTag.broadcast => try server.broadcast(message.broadcast.from, message.broadcast.msg),
            }
        }

        var seen = std.ArrayList(usize).init(allocator);
        for (poll_info.disconnected.items) |index| {
            // Make sure to deduplicate
            for (seen.items) |seen_index| {
                if (seen_index == index) continue; // Already disconnected
            }
            try seen.append(index);

            const user = server.users.items[index];
            switch (user.kind) {
                .joined => {
                    var msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(msg.writer(), "* {s} disconnected\n", .{user.name.items});
                    try send_info.append(Message{ .broadcast = .{ .from = index, .msg = msg.items } });
                },
                else => {},
            }
            _ = server.orderedRemove(index);
        }
    }
}
