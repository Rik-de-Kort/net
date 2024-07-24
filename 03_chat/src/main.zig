const std = @import("std");
const net = @import("std.net");

const Server = struct {
    allocator: std.mem.Allocator,
    users: std.ArrayList(User),

    pub const UserType = enum { server, connected, joined };

    const User = struct {
        id: u32,
        kind: UserType,
        stream: std.net.Stream,
        fifo: std.io.PollFifo,
        name: []const u8,

        pub fn deinit(self: *User) void {
            self.stream.close();
            self.fifo.deinit();
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

        try self.users.append(User{ .id = 0, .kind = UserType.server, .stream = server, .name = "SERVER", .fifo = std.io.PollFifo.init(self.allocator) });
        return self;
    }

    pub fn deinit(self: *Server) void {
        for (self.users.items) |*user| {
            user.deinit();
        }
        self.users.deinit();
    }

    pub fn connect(self: *Server, stream: std.net.Stream) !u32 {
        var new_id: u32 = 0;
        for (self.users.items) |user| {
            new_id = @max(new_id, user.id + 1);
        }

        try self.users.append(User{
            .id = new_id,
            .kind = UserType.connected,
            .stream = stream,
            .fifo = std.io.PollFifo.init(self.allocator),
            .name = "[NO NAME]",
        });
        return new_id;
    }

    pub fn get_user(self: Server, id: u32) ?*User {
        for (self.users.items) |*user| {
            if (user.id == id) return user;
        }
        return null;
    }

    pub fn join(self: *Server, id: u32, name: []const u8) !void {
        var user = self.get_user(id) orelse unreachable;

        const name_buf = try self.allocator.alloc(u8, name.len);
        std.mem.copyForwards(u8, name_buf, name);
        user.name = name_buf;

        user.kind = UserType.joined;
    }

    pub fn debugGetName(self: Server, id: u32) []const u8 {
        const user = self.get_user(id) orelse unreachable;
        return user.name;
    }

    pub fn debugPrintBufferStates(self: Server) void {
        std.debug.print("\nBUFFER STATES:\n", .{});
        for (self.users.items) |*user| {
            std.debug.print("{any} [{s}]: {s}\n", .{ user.id, user.name, user.fifo.readableSliceOfLen(user.fifo.count) });
        }
        std.debug.print("\n", .{});
    }

    pub fn get_pollfds(self: *Server, state: *ServerState) !std.ArrayList(std.posix.pollfd) {
        var pollfds = std.ArrayList(std.posix.pollfd).init(state.allocator);

        const base_events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
        for (self.users.items) |user| {
            var events: i16 = base_events;
            for (state.out.items) |out_msg| {
                if (out_msg.to == user.id) events = events | std.posix.POLL.OUT;
            }
            try pollfds.append(.{ .fd = user.stream.handle, .events = events, .revents = 0 });
        }
        return pollfds;
    }

    pub const ServerState = struct {
        allocator: std.mem.Allocator,
        in: std.ArrayList(InMessage),
        out: std.ArrayList(OutMessage),
        connect: bool,
        disconnect: std.ArrayList(u32),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .in = std.ArrayList(InMessage).init(allocator),
                .out = std.ArrayList(OutMessage).init(allocator),
                .connect = false,
                .disconnect = std.ArrayList(u32).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.in.deinit();
            self.out.deinit();
            self.disconnect.deinit();
        }

        pub fn debugPrint(self: Self) void {
            std.debug.print("\nSERVER STATE:\n", .{});
            std.debug.print("in:\n", .{});
            for (self.in.items) |in_msg| {
                std.debug.print("from: {any} msg: {s}\n", .{ in_msg.from, in_msg.msg });
            }
            std.debug.print("out:\n", .{});
            for (self.out.items) |out_msg| {
                std.debug.print("to: {any} msg: {s}\n", .{ out_msg.to, out_msg.msg });
            }
            std.debug.print("disconnect:\n{any}\n", .{self.disconnect.items});
            std.debug.print("pending connect: {any}\n\n", .{self.connect});
        }
    };

    /// Send messages, receive messages. Returns an owned slice of InMessages, caller is responsible for freeing.
    pub fn communicate(self: *Server, state: *ServerState) !void {
        std.debug.print("COMMUNICATE START\n", .{});
        state.debugPrint();
        self.debugPrintBufferStates();

        const pollfds = try self.get_pollfds(state);
        const n_events = try std.posix.poll(pollfds.items, -1);
        if (n_events == 0) {
            return;
        }

        var sent_messages = std.ArrayList(usize).init(state.allocator);

        for (pollfds.items, self.users.items) |*pollfd, *user| {
            const poll_in = pollfd.revents & std.posix.POLL.IN;
            const poll_out = pollfd.revents & std.posix.POLL.OUT;
            const poll_hup = pollfd.revents & std.posix.POLL.HUP;
            const poll_err = pollfd.revents & std.posix.POLL.ERR;
            std.debug.print("[{s}] ({any}) IN: {any} OUT {any} HUP: {any} ERR: {any}\n", .{
                user.name,
                user.id,
                poll_in,
                poll_out,
                poll_hup,
                poll_err,
            });

            if (poll_in != 0) {
                // Handle read
                if (user.kind != .server) {
                    std.debug.print("Trying to read from {s} ({any})\n", .{ user.name, user.id });
                    const original_count = user.fifo.count;

                    const file_handle = std.fs.File{ .handle = pollfd.fd };
                    const reader = file_handle.reader();
                    const writer = user.fifo.writer();
                    reader.streamUntilDelimiter(writer, '\n', null) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (user.fifo.count == original_count) { // No bytes, must be disconnected
                                std.debug.print("No bytes, disconnecting {s} ({any})\n", .{ user.name, user.id });
                                try state.disconnect.append(user.id);
                            }
                            continue;
                        },
                        error.WouldBlock => {
                            std.debug.print("{s} ({any}) is a lying bastard, no data here\n", .{ user.name, user.id });
                            continue;
                        },
                        else => |e| return e,
                    };
                    const msg_buf: []u8 = try state.allocator.alloc(u8, user.fifo.count);
                    const n_bytes = user.fifo.read(msg_buf);
                    if (n_bytes <= user.fifo.count) {
                        return error.FailedtoRead;
                    }
                    try state.in.append(InMessage{ .from = user.id, .msg = msg_buf });
                } else {
                    state.connect = true;
                }
            }

            if (poll_out != 0) {
                // Handle write
                for (0.., state.out.items) |index_out, out_message| {
                    if (out_message.to != user.id) continue;
                    try user.stream.writeAll(out_message.msg);
                    try sent_messages.append(index_out);
                }
            }

            if (poll_hup != 0 or poll_err != 0) {
                // Handle disconnect
                try state.disconnect.append(user.id);
            }
        }

        // Filter out sent messages from out messages
        var remaining_messages = std.ArrayList(OutMessage).init(state.allocator);
        filter: for (0.., state.out.items) |index_out, out_message| {
            for (sent_messages.items) |index_sent| {
                if (index_sent == index_out) continue :filter;
            }
            try remaining_messages.append(out_message);
        }
        state.out = remaining_messages;

        std.debug.print("COMMUNICATE END\n", .{});
        state.debugPrint();
        self.debugPrintBufferStates();
        return;
    }

    pub fn orderedRemove(self: *Server, index: usize) void {
        std.debug.print("Removing {any}\n", .{index});
        self.users.items[index].deinit();
        _ = self.users.orderedRemove(index);
    }
};

const OutMessage = struct {
    msg: []const u8,
    to: u32,
};

const InMessage = struct {
    msg: []const u8,
    from: u32,
};

// Todo:
// - Run this on protohackers and probably deal with edge cases: disconnects of non-joined users and the like
// - User user id instead of indices

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true, .force_nonblocking = true });
    std.debug.print("{any}\n", .{listener});

    var server = try Server.init(allocator, listener.stream);
    defer server.deinit();

    var state = Server.ServerState.init(allocator);

    while (true) {
        try server.communicate(&state);

        if (state.connect) {
            const connection = try listener.accept();
            const timeout = std.posix.timeval{ .tv_sec = 0, .tv_usec = 25000 };
            try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

            const new_id = try server.connect(connection.stream);

            try state.out.append(.{ .to = new_id, .msg = "welcome to budget chat. What's your name?\n" });
            state.connect = false;
        }
        for (state.in.items) |in_message| {
            const user = server.get_user(in_message.from) orelse unreachable;
            switch (user.kind) {
                .server => unreachable,
                .connected => {
                    if (in_message.msg.len <= 0 or 17 <= in_message.msg.len) {
                        try state.disconnect.append(in_message.from);
                    }
                    for (in_message.msg) |c| {
                        if (!std.ascii.isAlphanumeric(c)) {
                            try state.disconnect.append(in_message.from);
                        }
                    }
                    var join_msg = try std.ArrayList(u8).initCapacity(state.allocator, in_message.msg.len + 23);
                    try std.fmt.format(join_msg.writer(), "* {s} has joined the room\n", .{in_message.msg});
                    for (server.users.items) |recipient| {
                        if (recipient.kind != .joined) continue;
                        try state.out.append(.{ .to = recipient.id, .msg = join_msg.items });
                    }

                    // Send "room contains a, b, c" to joined user
                    var presence_msg = std.ArrayList(u8).init(allocator);
                    var just_names = try std.ArrayList([]const u8).initCapacity(allocator, server.users.items.len);
                    for (server.users.items) |present_user| {
                        if (present_user.kind != .joined) continue;
                        try just_names.append(present_user.name);
                    }
                    const user_list = try std.mem.join(allocator, ", ", just_names.items);

                    try std.fmt.format(presence_msg.writer(), "* active users are {s}\n", .{user_list});
                    try state.out.append(.{ .to = in_message.from, .msg = presence_msg.items });

                    // Turn user into joined user
                    try server.join(in_message.from, in_message.msg);
                },
                .joined => {
                    if (in_message.msg.len > 1000) {
                        try state.disconnect.append(in_message.from);
                        continue;
                    }

                    var sent_msg = std.ArrayList(u8).init(allocator);
                    try std.fmt.format(sent_msg.writer(), "[{s}] {s}\n", .{ user.name, in_message.msg });
                    for (server.users.items) |recipient| {
                        if (recipient.kind != .joined or recipient.id == in_message.from) continue;
                        try state.out.append(.{ .to = recipient.id, .msg = sent_msg.items });
                    }
                },
            }
        }
        // Handled all messages, clear them
        state.in.clearAndFree();

        // Disconnect users.
        var remaining_users = std.ArrayList(Server.User).init(server.allocator);
        filter: for (server.users.items) |*user| {
            for (state.disconnect.items) |disconnected_id| {
                if (disconnected_id != user.id) continue;

                if (user.kind == .joined) {
                    var disconnect_msg = std.ArrayList(u8).init(state.allocator);
                    try std.fmt.format(disconnect_msg.writer(), "* {s} disconnected\n", .{user.name});
                    for (server.users.items) |recipient| {
                        if (recipient.kind != .joined) continue;
                        try state.out.append(.{ .to = recipient.id, .msg = disconnect_msg.items });
                    }
                }
                user.deinit();
                continue :filter;
            }
            try remaining_users.append(user.*);
        }
        server.users = remaining_users;

        // Drop messages to disconnected users
        var remaining_messages = std.ArrayList(OutMessage).init(state.allocator);
        filter: for (state.out.items) |out_message| {
            for (state.disconnect.items) |disconnected_id| {
                if (disconnected_id == out_message.to) {
                    continue :filter;
                }
            }
            try remaining_messages.append(out_message);
        }

        state.disconnect.clearAndFree();
        state.out = remaining_messages;
    }
}
