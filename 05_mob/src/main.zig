const std = @import("std");
const poll = std.posix.POLL;

pub fn isBogus(tok: []const u8) bool {
    return 26 <= tok.len and tok.len <= 35 and tok[0] == '7';
}

pub fn rewriteMsg(alloc: std.mem.Allocator, msg: []const u8) !std.ArrayList(u8) {
    var slice_start: usize = 0;
    var out = try std.ArrayList(u8).initCapacity(alloc, msg.len);
    for (msg, 0..) |char, i| {
        if (char != ' ') continue;

        if (isBogus(msg[slice_start..i])) {
            try out.appendSlice("7YWHMfk9JZe0LM0g1ZauHuiSxhI ");
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
    try out.appendSlice("\n");
    return out;
}

pub fn blockUntilReadyToWrite(stream: std.net.Stream) !void {
    var pollfds: [1]std.posix.pollfd = .{.{ .fd = stream.handle, .events = poll.OUT, .revents = 0 }};
    const n_events = try std.posix.poll(&pollfds, -1);
    std.debug.assert(n_events > 0);
}

pub fn blockUntilReadyToReadMultiple(client: std.net.Stream, server: std.net.Stream) ![2]bool {
    var pollfds: [2]std.posix.pollfd = .{
        .{ .fd = client.handle, .events = poll.IN, .revents = 0 },
        .{ .fd = server.handle, .events = poll.IN, .revents = 0 },
    };
    const n_events = try std.posix.poll(&pollfds, -1);
    std.debug.assert(n_events > 0);

    // client ready, server ready
    return .{ pollfds[0].revents & poll.IN > 0, pollfds[1].revents & poll.IN > 0 };
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

pub fn handleConnection(connection: std.net.Server.Connection, index: usize) !void {
    const client = connection.stream;
    defer connection.stream.close();

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

    var data_server = std.ArrayList(u8).init(allocator);
    defer data_server.deinit();
    var data_client = std.ArrayList(u8).init(allocator);
    defer data_client.deinit();

    var connected = true;
    var i: usize = 0;
    while (connected) : (i += 1) {
        // Todo: deal with ERR and HUP
        const ready = try blockUntilReadyToReadMultiple(client, server);
        const ready_client = ready[0];
        const ready_server = ready[1];

        // Fetch data
        if (ready_server) {
            print(index, "server is ready!\n", .{});
            data_server.clearRetainingCapacity();
            server.reader().streamUntilDelimiter(data_server.writer(), '\n', null) catch |err| switch (err) {
                error.EndOfStream => {
                    print(index, "server end of stream\n", .{});
                },
                else => return err,
            };
            try debugPrint(data_server.items, index);
            std.debug.print(" is what we got from the server (len {})\n", .{data_server.items.len});
        }

        if (ready_client) {
            print(index, "client is ready!\n", .{});
            data_client.clearRetainingCapacity();
            client.reader().streamUntilDelimiter(data_client.writer(), '\n', null) catch |err| switch (err) {
                error.EndOfStream => {
                    connected = false;
                    print(index, "client end of stream\n", .{});
                },
                else => return err,
            };
            try debugPrint(data_client.items, index);
            std.debug.print(" is what we got from the client (len {})\n", .{data_client.items.len});
        }

        // Write data
        if (ready_server and data_server.items.len > 0) {
            try blockUntilReadyToWrite(client);
            const rewritten_server = try rewriteMsg(allocator, data_server.items);
            defer rewritten_server.deinit();

            try debugPrint(rewritten_server.items, index);
            std.debug.print(" is what we tried to write to the client\n", .{});
            try client.writeAll(rewritten_server.items);
        }

        if (ready_client and data_client.items.len > 0) {
            try blockUntilReadyToWrite(server);
            const rewritten_client = try rewriteMsg(allocator, data_client.items);
            defer rewritten_client.deinit();

            try debugPrint(rewritten_client.items, index);
            std.debug.print(" is what we tried to write to the server\n", .{});
            // print(index, "Trying to write {s} to server\n", .{std.fmt.fmt rewritten_client.items});
            try server.writeAll(rewritten_client.items);
        }
    }
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
    try checkRewriteMsg("* The room contains: alice", "* The room contains: alice");
}
