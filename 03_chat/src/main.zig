const std = @import("std");
const net = @import("std.net");

const BlockingPoller = struct {
    allocator: std.mem.Allocator,
    users: std.ArrayList(User),
    user_names: std.AutoHashMap(usize, std.ArrayList(u8)),

    pub const UserType = enum { server, connected, joined };

    const User = struct {
        kind: UserType,
        stream: std.net.Stream,
        fifo: std.io.PollFifo,

        pub fn deinit(self: *User) void {
            self.stream.close();
            self.fifo.deinit();
        }
    };

    const PollInfo = struct {
        new_data: std.ArrayList(usize),
        disconnected: std.ArrayList(usize),
    };

    pub fn init(allocator: std.mem.Allocator, server: std.net.Stream) !BlockingPoller {
        var self = BlockingPoller{
            .allocator = allocator,
            .users = std.ArrayList(User).init(allocator),
            .user_names = std.AutoHashMap(usize, std.ArrayList(u8)).init(allocator),
        };

        try self.users.append(User{ .kind = UserType.server, .stream = server, .fifo = std.io.PollFifo.init(self.allocator) });
        return self;
    }

    pub fn deinit(self: *BlockingPoller) void {
        for (self.users.items) |*user| {
            user.deinit();
        }
        self.users.deinit();
    }

    pub fn connect(self: *BlockingPoller, stream: std.net.Stream) !usize {
        try self.users.append(User{ .kind = UserType.connected, .stream = stream, .fifo = std.io.PollFifo.init(self.allocator) });
        return self.users.items.len - 1;
    }

    pub fn join(self: *BlockingPoller, index: usize, name: std.ArrayList(u8)) !void {
        self.users.items[index].kind = UserType.joined;
        try self.user_names.put(index, name);
    }

    pub fn poll(self: *BlockingPoller, allocator: std.mem.Allocator) !PollInfo {
        var result = PollInfo{
            .new_data = std.ArrayList(usize).init(allocator),
            .disconnected = std.ArrayList(usize).init(allocator),
        };

        std.debug.print("\nPolling, here are the buffer states:\n", .{});
        for (0.., self.users.items) |i, *user| {
            const name = switch (user.kind) {
                .server => "server",
                .connected => "connected",
                .joined => (self.user_names.get(i) orelse unreachable).items,
            };
            std.debug.print("{any} [{s}]: {s}\n", .{ i, name, user.fifo.readableSliceOfLen(user.fifo.count) });
        }
        std.debug.print("\n", .{});

        var pollfds = try std.ArrayList(std.posix.pollfd).initCapacity(allocator, self.users.items.len);
        defer pollfds.deinit();
        for (self.users.items) |user| {
            pollfds.appendAssumeCapacity(.{ .fd = user.stream.handle, .events = std.posix.POLL.IN, .revents = 0 });
        }
        const events_len = try std.posix.poll(pollfds.items, -1);
        if (events_len == 0) {
            std.debug.print("No events\n", .{});
            return result;
        }

        for (0.., pollfds.items, self.users.items) |i, *poll_fd, *user| {
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                // Got a jammy bastard!
                if (i > 0) {
                    std.debug.print("Trying to read from {any}, {any} bytes in buffer\n", .{ i, user.fifo.count });
                    const original_count = user.fifo.count;

                    const file_handle = std.fs.File{ .handle = poll_fd.fd };
                    const reader = file_handle.reader();
                    const writer = user.fifo.writer();
                    reader.streamUntilDelimiter(writer, '\n', null) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (user.fifo.count == original_count) { // No bytes, must be disconnected
                                std.debug.print("Got no bytes, disconnecting!\n", .{});
                                try result.disconnected.append(i);
                            }
                            std.debug.print("Read from {any}, {any} bytes in buffer: {s}\n", .{ i, user.fifo.count, user.fifo.readableSliceOfLen(user.fifo.count) });
                            continue;
                        },
                        else => |e| return e,
                    };
                    std.debug.print("Read from {any}, {any} bytes in buffer: {s}\n", .{ i, user.fifo.count, user.fifo.readableSliceOfLen(user.fifo.count) });
                }
                try result.new_data.append(i);
            } else if (poll_fd.revents & std.posix.POLL.ERR != 0) {
                std.debug.print("Got error with poll {any}\n", .{poll_fd});
            } else if (poll_fd.revents & std.posix.POLL.HUP != 0) {
                const buf = try user.fifo.writableWithSize(512);
                const n_bytes = try std.posix.read(poll_fd.fd, buf);
                if (n_bytes > 0) {
                    user.fifo.update(n_bytes);
                    try result.new_data.append(i);
                }
                try result.disconnected.append(i);
                std.debug.print("Disconnected {any}\n", .{poll_fd});
            } else if (poll_fd.revents != 0) {
                std.debug.print("These events? {any}\n", .{poll_fd.revents});
            }
        }
        return result;
    }

    pub fn broadcast(self: BlockingPoller, from: ?usize, msg: []const u8) !void {
        for (0.., self.users.items) |i, user| {
            switch (user.kind) {
                .connected => continue,
                .server => continue,
                .joined => {
                    if (i == from) continue;
                    try user.stream.writeAll(msg);
                },
            }
        }
    }

    pub fn send(self: BlockingPoller, to: usize, msg: []const u8) !void {
        std.debug.print("Sending message '{s}' to {any}\n", .{ msg, to });
        try self.users.items[to].stream.writeAll(msg);
    }

    pub fn orderedRemove(self: *BlockingPoller, index: usize) void {
        std.debug.print("Removing {any}\n", .{index});
        _ = self.user_names.remove(index);
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{server});

    var poller = try BlockingPoller.init(allocator, server.stream);
    defer poller.deinit();

    while (true) {
        var poll_info = try poller.poll(allocator);
        var send_info = std.ArrayList(Message).init(allocator);
        defer send_info.deinit();

        for (poll_info.new_data.items) |index| {
            const this_user = poller.users.items[index];
            switch (this_user.kind) {
                .server => {
                    const connection = try server.accept();
                    const new_index = try poller.connect(connection.stream);
                    try send_info.append(Message{ .direct = .{ .msg = "welcome to budget chat. What's your name?\n", .to = new_index } });
                },
                .connected => {
                    var name_buf: [17]u8 = undefined;
                    const n_bytes = poller.users.items[index].fifo.read(&name_buf);
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
                    var just_names = try std.ArrayList([]const u8).initCapacity(allocator, poller.users.items.len);
                    for (0.., poller.users.items) |i, user| {
                        switch (user.kind) {
                            .server => {},
                            .connected => {},
                            .joined => just_names.appendAssumeCapacity((poller.user_names.get(i) orelse unreachable).items),
                        }
                    }
                    const user_list = try std.mem.join(allocator, ", ", just_names.items);

                    try std.fmt.format(presence_msg.writer(), "* active users are {s}\n", .{user_list});
                    try send_info.append(Message{ .direct = .{ .msg = presence_msg.items, .to = index } });

                    // Turn user into joined user
                    try poller.join(index, name);
                },
                .joined => {
                    var message_buf: [1024]u8 = undefined;
                    const n_bytes = poller.users.items[index].fifo.read(&message_buf);
                    if (n_bytes > 1000) {
                        try poll_info.disconnected.append(index);
                        continue;
                    }

                    var sent_msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(sent_msg.writer(), "[{s}] {s}\n", .{ (poller.user_names.get(index) orelse unreachable).items, message_buf[0..n_bytes] });
                    try send_info.append(Message{ .broadcast = .{ .msg = sent_msg.items, .from = index } });
                },
            }
        }

        var seen = std.ArrayList(usize).init(allocator);
        for (poll_info.disconnected.items) |index| {
            // Make sure to deduplicate
            for (seen.items) |seen_index| {
                if (seen_index == index) continue; // Already disconnected
            }
            try seen.append(index);

            const user = poller.users.items[index];
            switch (user.kind) {
                .joined => {
                    var msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(msg.writer(), "* {s} disconnected\n", .{(poller.user_names.get(index) orelse unreachable).items});
                    try send_info.append(Message{ .broadcast = .{ .from = index, .msg = msg.items } });
                },
                else => {},
            }
            _ = poller.orderedRemove(index);
        }
        for (send_info.items) |message| {
            switch (message) {
                MessageTag.direct => {
                    try poller.send(message.direct.to, message.direct.msg);
                },
                MessageTag.broadcast => try poller.broadcast(message.broadcast.from, message.broadcast.msg),
            }
        }
    }
}
