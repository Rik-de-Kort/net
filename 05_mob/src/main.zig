const std = @import("std");
const poll = std.posix.POLL;

pub fn isBogus(tok: []const u8) bool {
    return 26 <= tok.len and tok.len <= 35 and tok[0] == '7';
}

pub fn rewriteMsg(alloc: std.mem.Allocator, msg: []const u8) !std.ArrayList(u8) {
    var slice_start: usize = 0;
    var out = try std.ArrayList(u8).initCapacity(alloc, msg.len);
    for (msg, 0..) |char, i| {
        if (char != ' ' and char != '\n') continue;

        if (isBogus(msg[slice_start..i])) {
            try out.appendSlice("7YWHMfk9JZe0LM0g1ZauHuiSxhI");
            try out.append(char);
        } else {
            try out.appendSlice(msg[slice_start .. i + 1]); // include space
        }
        slice_start = i + 1;
    }
    if (isBogus(msg[slice_start..msg.len])) {
        try out.appendSlice("7YWHMfk9JZe0LM0g1ZauHuiSxhI");
    } else {
        try out.appendSlice(msg[slice_start..msg.len]);
    }
    return out;
}

pub fn blockUntilReadyToWrite(stream: std.net.Stream, index: usize) !void {
    var pollfds: [1]std.posix.pollfd = .{.{ .fd = stream.handle, .events = poll.OUT | poll.HUP, .revents = 0 }};
    print(index, "blocking for write...\n", .{});
    const n_events = try std.posix.poll(&pollfds, -1);
    std.debug.assert(n_events > 0);
    if (pollfds[0].revents & poll.OUT > 0) {
        return;
    } else {
        std.debug.print("HUNG UP\n", .{});
        return error.HUNG_UP;
    }
}

const PollEvents = struct {
    can_read: bool,
    hung_up: bool,
    err: bool,
};

const SocketReadiness = struct {
    server: PollEvents,
    client: PollEvents,
};

pub fn blockUntilReady(client: std.net.Stream, server: std.net.Stream) !SocketReadiness {
    const events = poll.IN | poll.HUP | poll.ERR;
    var pollfds: [2]std.posix.pollfd = .{
        .{ .fd = client.handle, .events = events, .revents = 0 },
        .{ .fd = server.handle, .events = events, .revents = 0 },
    };
    const n_events = try std.posix.poll(&pollfds, -1);
    std.debug.assert(n_events > 0);

    const revents_c = pollfds[0].revents;
    const revents_s = pollfds[1].revents;
    return .{
        .server = .{
            .can_read = revents_s & poll.IN > 0,
            .hung_up = revents_s & poll.HUP > 0,
            .err = revents_s & poll.ERR > 0,
        },
        .client = .{
            .can_read = revents_c & poll.IN > 0,
            .hung_up = revents_c & poll.HUP > 0,
            .err = revents_c & poll.ERR > 0,
        },
    };
}

pub fn print(index: usize, comptime msg: []const u8, params: anytype) void {
    std.debug.print("[{}] ", .{index});
    std.debug.print(msg, params);
}

pub fn debugPrint(msg: []const u8, index: usize) !void {
    std.debug.print("[{}] ", .{index});
    const bw = std.debug.lockStderrWriter(&.{});
    defer std.debug.unlockStderrWriter();
    try std.zig.stringEscape(msg, bw);
}

const SplitResult = struct {
    partial: bool,
    parts: std.ArrayList([]const u8),
    fn deinit(self: SplitResult) void {
        self.parts.deinit();
    }
};

fn splitMessage(allocator: std.mem.Allocator, msg: []const u8) !SplitResult {
    std.debug.print("{s} is what we're trying to split\n", .{msg});
    var start: usize = 0;
    var result = std.ArrayList([]const u8).init(allocator);
    for (msg, 0..) |c, i| {
        if (c == '\n') {
            try result.append(msg[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < msg.len) {
        try result.append(msg[start..msg.len]);
    }

    for (result.items) |part| {
        std.debug.print("{s} is a part\n", .{part});
    }
    return .{
        .partial = start < msg.len,
        .parts = result,
    };
}

pub fn handleConnection(connection: std.net.Server.Connection, index: usize) !void {
    const client = connection.stream;
    defer client.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    print(index, "connection to server...\n", .{});
    const addressList = try std.net.getAddressList(allocator, "chat.protohackers.com", 16963);
    defer addressList.deinit();
    print(index, "{any}\n", .{addressList.addrs.len});
    for (addressList.addrs, 0..) |addr, i| {
        print(index, "{any}: {f}\n", .{ i, addr.in });
    }
    const server = try std.net.tcpConnectToAddress(addressList.addrs[1]);
    defer server.close();
    print(index, "connected!\n", .{});

    var server_in: [4096]u8 = undefined;
    var start_server: usize = 0;
    var end_server: usize = 0;

    var client_in: [4096]u8 = undefined;
    var start_client: usize = 0;
    var end_client: usize = 0;

    const connected = true;
    var i: usize = 0;
    while (connected) : (i += 1) {
        print(index, "blocking until ready\n", .{});
        const ready = try blockUntilReady(client, server);

        if (ready.server.hung_up or ready.server.err) {
            print(index, "server hung up or err\n", .{});
            break;
        }
        if (ready.client.hung_up or ready.client.err) {
            print(index, "client hung up or err\n", .{});
            break;
        }

        // Fetch data
        var n_read_server: usize = 0;
        if (ready.server.can_read) {
            print(index, "server is ready!\n", .{});
            n_read_server = try server.read(server_in[start_server..]);
            print(index, "read {} bytes\n", .{n_read_server});
            end_server = start_server + n_read_server;
            try debugPrint(server_in[0..n_read_server], index);
            std.debug.print(" is what we got from the server (len {})\n", .{server_in.len});
        }

        var n_read_client: usize = 0;
        if (ready.client.can_read) {
            print(index, "client is ready!\n", .{});
            n_read_client = try client.read(client_in[start_client..]);
            print(index, "read {} bytes\n", .{n_read_client});
            end_client = start_client + n_read_client;
            try debugPrint(client_in[0..n_read_client], index);
            std.debug.print(" is what we got from the client (len {})\n", .{client_in.len});
        }

        if (start_client + n_read_client == 0 and start_server + n_read_server == 0) break;

        // Write data
        if (ready.server.can_read and server_in.len > 0) {
            var split_result = try splitMessage(allocator, server_in[0..end_server]);
            defer split_result.deinit();

            for (split_result.parts.items, 0..) |part, j| {
                try debugPrint(part, index);
                std.debug.print(" is server part {any}\n", .{j});
            }

            if (split_result.partial) {
                const partial = split_result.parts.pop() orelse "";
                std.mem.copyForwards(u8, server_in[0..partial.len], partial);
                start_server = partial.len;
            } else {
                start_server = 0;
            }

            try blockUntilReadyToWrite(client, index);
            for (split_result.parts.items) |msg| {
                const rewritten_server = try rewriteMsg(allocator, msg);
                defer rewritten_server.deinit();

                try debugPrint(rewritten_server.items, index);
                std.debug.print(" is what we try to write to the client\n", .{});
                try client.writeAll(rewritten_server.items);
                try debugPrint(rewritten_server.items, index);
                std.debug.print(" is what we wrote to the client\n", .{});
            }
        }

        if (ready.client.can_read and client_in.len > 0) {
            var split_result = try splitMessage(allocator, client_in[0..end_client]);
            defer split_result.deinit();

            for (split_result.parts.items, 0..) |part, j| {
                try debugPrint(part, index);
                std.debug.print(" is client part {any}\n", .{j});
            }
            if (split_result.partial) {
                const partial = split_result.parts.pop() orelse "";
                try debugPrint(partial, index);
                std.debug.print(" is what we partially have\n", .{});
                std.mem.copyForwards(u8, client_in[0..partial.len], partial);
                start_client = partial.len;
            } else {
                start_client = 0;
            }

            try blockUntilReadyToWrite(client, index);
            for (split_result.parts.items) |msg| {
                const rewritten_client = try rewriteMsg(allocator, msg);
                defer rewritten_client.deinit();

                try debugPrint(rewritten_client.items, index);
                std.debug.print(" is what we try to write to the server\n", .{});
                try server.writeAll(rewritten_client.items);
                try debugPrint(rewritten_client.items, index);
                std.debug.print(" is what we wrote to the server\n", .{});
            }
        }
    }
    print(index, "closing....\n", .{});
}

pub fn main() !void {
    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{f}\n", .{listener.listen_address.in});

    var index: usize = 0;
    while (true) : (index += 1) {
        const connection = try listener.accept();
        _ = try std.Thread.spawn(.{}, handleConnection, .{ connection, index });
    }
}

test "test isBogus" {
    try std.testing.expect(isBogus("7F1u3wSD5RbOHQmupo9nx4TnhQ"));
    try std.testing.expect(isBogus("7iKDZEwPZSqIvDnHvVN2r0hUWXD5rHX"));
    try std.testing.expect(isBogus("7LOrwbDlS8NujgjddyogWgIM93MV5N2VR"));
    try std.testing.expect(isBogus("7YWHMfk9JZe0LM0g1ZauHuiSxhI"));
    try std.testing.expect(!isBogus(""));
    try std.testing.expect(!isBogus("foobar"));
}

pub fn checkRewriteMsg(input: []const u8, expected: []const u8) !void {
    const result = try rewriteMsg(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings(result.items, expected);
}

test "test rewriteMsg" {
    var msg = std.ArrayList(u8).init(std.testing.allocator);
    defer msg.deinit();

    try checkRewriteMsg("Hi alice, please send payment to 7iKDZEwPZSqIvDnHvVN2r0hUWXD5rHX", "Hi alice, please send payment to 7YWHMfk9JZe0LM0g1ZauHuiSxhI");
    try checkRewriteMsg("[BlueDev728] Please send the payment of 750 Boguscoins to 7iA9Z0sXdw9j6QKFdPLyHxZi2mXKXaODem5\n", "[BlueDev728] Please send the payment of 750 Boguscoins to 7YWHMfk9JZe0LM0g1ZauHuiSxhI\n");
    try checkRewriteMsg("* The room contains: alice", "* The room contains: alice");
}
