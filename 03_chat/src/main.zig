const std = @import("std");
const net = @import("std.net");

const BlockingPoller = struct {
    allocator: std.mem.Allocator,
    pollfds: std.ArrayList(std.posix.pollfd),
    streams: std.ArrayList(std.net.Stream),
    fifos: std.ArrayList(std.io.PollFifo),

    const PollInfo = struct {
        new_data: std.ArrayList(usize),
        disconnected: std.ArrayList(usize),
    };

    pub fn init(allocator: std.mem.Allocator, server: std.net.Stream) !BlockingPoller {
        var self = BlockingPoller{ .allocator = allocator, .streams = std.ArrayList(std.net.Stream).init(allocator), .pollfds = std.ArrayList(std.posix.pollfd).init(allocator), .fifos = std.ArrayList(std.io.PollFifo).init(allocator) };
        _ = try self.add(server);
        return self;
    }

    pub fn deinit(self: *BlockingPoller) void {
        self.pollfds.deinit();
        self.streams.deinit();
        self.fifos.deinit();
    }

    pub fn poll(self: *BlockingPoller) !PollInfo {
        var result = PollInfo{
            .new_data = std.ArrayList(usize).init(self.allocator),
            .disconnected = std.ArrayList(usize).init(self.allocator),
        };

        const events_len = try std.posix.poll(self.pollfds.items, -1);
        if (events_len == 0) {
            return result;
        }

        for (0.., self.pollfds.items, self.fifos.items) |i, *poll_fd, *fifo| {
            if (poll_fd.revents & std.posix.POLL.IN != 0) {
                // Got a jammy bastard!
                if (i > 0) {
                    std.debug.print("Trying to read from {any}, {any} bytes in buffer\n", .{ i, fifo.count });
                    const original_count = fifo.count;

                    const file_handle = std.fs.File{ .handle = poll_fd.fd };
                    const reader = file_handle.reader();
                    const writer = fifo.writer();
                    reader.streamUntilDelimiter(writer, '\n', null) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (fifo.count == original_count) { // No bytes, must be disconnected
                                try result.disconnected.append(i);
                            }
                            continue;
                        },
                        else => |e| return e,
                    };
                    std.debug.print("Read from {any}, {any} bytes in buffer\n", .{ i, fifo.count });
                }
                try result.new_data.append(i);
            } else if (poll_fd.revents & std.posix.POLL.ERR != 0) {
                std.debug.print("Got error with poll {any}\n", .{poll_fd});
            } else if (poll_fd.revents & std.posix.POLL.HUP != 0) {
                const buf = try fifo.writableWithSize(512);
                const n_bytes = try std.posix.read(poll_fd.fd, buf);
                if (n_bytes > 0) {
                    fifo.update(n_bytes);
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
        for (0.., self.streams.items) |i, stream| {
            if (i == from or i == 0) continue;
            try stream.writeAll(msg);
        }
    }

    pub fn send(self: BlockingPoller, to: usize, msg: []const u8) !void {
        std.debug.print("Sending message '{s}' to {any}\n", .{ msg, to });
        try self.streams.items[to].writeAll(msg);
    }

    pub fn add(self: *BlockingPoller, stream: std.net.Stream) !usize {
        try self.pollfds.append(std.posix.pollfd{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 });
        errdefer _ = self.pollfds.pop();
        try self.fifos.append(std.io.PollFifo.init(self.allocator));
        errdefer _ = self.fifos.pop();
        try self.streams.append(stream);
        return self.streams.items.len - 1;
    }

    pub fn orderedRemove(self: *BlockingPoller, index: usize) void {
        std.debug.print("Removing {any}\n", .{index});
        _ = self.pollfds.orderedRemove(index);
        self.fifos.items[index].deinit();
        _ = self.fifos.orderedRemove(index);
        self.streams.items[index].close();
        _ = self.streams.orderedRemove(index);
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

const ConnectedUser = struct {
    index: usize,
};

const JoinedUser = struct {
    index: usize,
    name: std.ArrayList(u8),
};

const ServerUser = struct {};

const UserType = enum { server, connected, joined };

const User = union(UserType) {
    server: ServerUser,
    connected: ConnectedUser,
    joined: JoinedUser,
};

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

    var users = std.ArrayList(User).init(allocator);
    try users.append(User{ .server = .{} });
    while (true) {
        var poll_info = try poller.poll();
        var send_info = std.ArrayList(Message).init(allocator);
        defer send_info.deinit();

        for (poll_info.new_data.items) |index| {
            const this_user = users.items[index];
            switch (this_user) {
                User.server => {
                    const connection = try server.accept();
                    const new_index = try poller.add(connection.stream);
                    try send_info.append(Message{ .direct = .{ .msg = "welcome to budget chat. What's your name?\n", .to = new_index } });
                    try users.append(User{ .connected = .{ .index = new_index } });
                    std.debug.print("added user {any}\n", .{users.items[users.items.len - 1]});
                },
                User.connected => {
                    var name_buf: [17]u8 = undefined;
                    const n_bytes = poller.fifos.items[index].read(&name_buf);
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
                    var just_names = try std.ArrayList([]const u8).initCapacity(allocator, users.items.len);
                    for (users.items) |user| {
                        switch (user) {
                            User.server => {},
                            User.connected => {},
                            User.joined => just_names.appendAssumeCapacity(user.joined.name.items),
                        }
                    }
                    const user_list = try std.mem.join(allocator, ", ", just_names.items);

                    try std.fmt.format(presence_msg.writer(), "* active users are {s}\n", .{user_list});
                    try send_info.append(Message{ .direct = .{ .msg = presence_msg.items, .to = index } });

                    // Turn user into joined user
                    users.items[index] = User{ .joined = .{ .index = index, .name = name } };
                },
                User.joined => |user| {
                    std.debug.print("Joined user\n", .{});

                    var message_buf: [1024]u8 = undefined;
                    const n_bytes = poller.fifos.items[index].read(&message_buf);
                    if (n_bytes > 1000) {
                        try poll_info.disconnected.append(index);
                        continue;
                    }

                    var sent_msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(sent_msg.writer(), "[{s}] {s}\n", .{ user.name.items, message_buf[0..n_bytes] });
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

            switch (users.items[index]) {
                User.joined => |user| {
                    var msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(msg.writer(), "* {s} disconnected\n", .{user.name.items});
                    try send_info.append(Message{ .broadcast = .{ .from = index, .msg = msg.items } });
                },
                else => {},
            }
            _ = poller.orderedRemove(index);
            _ = users.orderedRemove(index);
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
