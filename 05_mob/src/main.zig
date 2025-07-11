const std = @import("std");

pub fn isBogus(tok: []const u8) bool {
    return 26 <= tok.len and tok.len <= 35 and tok[0] == '7';
}

pub fn rewriteMsg(alloc: std.mem.Allocator, msg: []const u8) !std.ArrayList(u8) {
    var slice_start: usize = 0;
    var out = try std.ArrayList(u8).initCapacity(alloc, 2 * msg.len);
    for (msg, 0..) |char, i| {
        if (char != ' ') continue;

        if (isBogus(msg[slice_start..i])) {
            out.appendSliceAssumeCapacity("7YWHMfk9JZe0LM0g1ZauHuiSxhI ");
        } else {
            out.appendSliceAssumeCapacity(msg[slice_start .. i + 1]); // include space
        }
        slice_start = i + 1;
    }
    if (isBogus(msg[slice_start..msg.len])) {
        out.appendSliceAssumeCapacity("7YWHMfk9JZe0LM0g1ZauHuiSxhI");
    } else {
        out.appendSliceAssumeCapacity(msg[slice_start..msg.len]);
    }
    out.appendSliceAssumeCapacity("\n");
    return out;
}

pub fn handleConnection(connection: std.net.Server.Connection) !void {
    defer connection.stream.close();
    const client = connection.stream;

    std.debug.print("connection to server...\n", .{});
    const serverAddress = try std.net.Address.parseIp4("206.189.113.124", 16963);
    const server = try std.net.tcpConnectToAddress(serverAddress);
    defer server.close();
    std.debug.print("connected!\n", .{});

    try server.reader().streamUntilDelimiter(client.writer(), '\n', null);
    _ = try client.write("\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    while (true) {
        // Todo: deal with ERR and HUP
        const events = std.posix.POLL.IN;
        const server_pollfd = std.posix.pollfd{ .fd = server.handle, .events = events, .revents = 0 };
        const client_pollfd = std.posix.pollfd{ .fd = client.handle, .events = events, .revents = 0 };

        // Todo: figure out why this doesnt work
        var pollfds: [2]std.posix.pollfd = .{ server_pollfd, client_pollfd };
        std.debug.print("polling\n", .{});
        const n_events = try std.posix.poll(&pollfds, 1000);
        if (n_events == 0) {
            std.debug.print("nothing to do\n", .{});
            continue;
        }

        if (server_pollfd.revents & std.posix.POLL.IN > 0) {
            try server.reader().streamUntilDelimiter(data.writer(), '\n', null);
            defer data.clearRetainingCapacity();
            std.debug.print("Got {s} from server\n", .{data.items});

            const rewritten = try rewriteMsg(allocator, data.items);
            defer rewritten.deinit();

            std.debug.print("Trying to write {s} to client\n", .{rewritten.items});
            try client.writeAll(rewritten.items);
            _ = try client.write("\n");
        }
        if (client_pollfd.revents & std.posix.POLL.IN > 0) {
            try client.reader().streamUntilDelimiter(data.writer(), '\n', null);
            defer data.clearRetainingCapacity();
            std.debug.print("Got {s} from client\n", .{data.items});

            const rewritten = try rewriteMsg(allocator, data.items);
            defer rewritten.deinit();

            std.debug.print("Trying to write {s} to server\n", .{rewritten.items});
            try server.writeAll(rewritten.items);
            _ = try server.write("\n");
        }
    }
}

pub fn main() !void {
    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{listener.listen_address.in});

    while (true) {
        const connection = try listener.accept();
        _ = try std.Thread.spawn(.{}, handleConnection, .{connection});
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
