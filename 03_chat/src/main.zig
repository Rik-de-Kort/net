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
                    std.debug.print("Trying to read from {any}, {any}\n", .{ i, poll_fd.fd });
                    const buf = try fifo.writableWithSize(512);
                    const n_bytes = try std.posix.read(poll_fd.fd, buf);
                    fifo.update(n_bytes);
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
            } else {
                std.debug.print("These events? {any}\n", .{poll_fd.revents});
            }
        }
        std.debug.print("finished poll, posting {any}, {any}\n", .{ result.new_data.items, result.disconnected.items });
        return result;
    }

    pub fn broadcast(self: BlockingPoller, from: ?usize, msg: []const u8) !void {
        for (0.., self.streams) |i, stream| {
            if (i == from) continue;
            try stream.writeAll(msg);
        }
    }

    pub fn send(self: BlockingPoller, to: usize, msg: []const u8) !void {
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
        _ = self.pollfds.orderedRemove(index);
        self.fifos.items[index].deinit();
        _ = self.fifos.orderedRemove(index);
        self.streams[index].close();
        _ = self.streams.orderedRemove(index);
    }
};

const BroadcastMessage = struct {
    msg: []const u8,
    sender: ?usize,
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
    name: []const u8,
};

const UserType = enum { connected, joined };

const User = union(UserType) {
    connected: ConnectedUser,
    joined: JoinedUser,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{server});

    var poller = try BlockingPoller.init(allocator, server.stream);
    defer poller.deinit();

    var users = std.ArrayList(User).init(allocator);
    while (true) {
        const poll_info = try poller.poll();
        var send_info = std.ArrayList(Message).init(allocator);
        for (poll_info.new_data.items) |index| {
            if (index == 0) {
                const connection = try server.accept();
                const new_index = try poller.add(connection.stream);
                try send_info.append(Message{ .direct = .{ .msg = "welcome to budget chat. What's your name?\n", .to = new_index } });
                try users.append(User{ .connected = .{ .index = new_index } });
                std.debug.print("added user {any}\n", .{users.items[users.items.len - 1]});
            }
        }
        for (send_info.items) |message| {
            switch (message) {
                MessageTag.direct => try poller.send(message.direct.to, message.direct.msg),
                MessageTag.broadcast => for (users.items) |user| {
                    switch (user) {
                        UserType.joined => try poller.send(user.joined.index, message.broadcast.msg),
                        UserType.connected => {},
                    }
                },
            }
        }
    }
}
