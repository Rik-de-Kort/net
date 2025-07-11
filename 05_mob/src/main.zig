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
    return out;
}

pub fn handleMsg(alloc: std.mem.Allocator, server: std.net.Stream, msg: []const u8) !void {
    // todo: handle response from server
    // maybe extract the loop for reading or use std.io.GenericReader with ReadUntilDelimiter somehow?
    std.debug.print("Trying to handle {s}\n", .{msg});
    const rewritten = try rewriteMsg(alloc, msg);
    defer rewritten.deinit();
    std.debug.print("Trying to write {s}\n", .{rewritten.items});
    try server.writeAll(rewritten.items);
}

pub fn handleConnection(connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    std.debug.print("connection to server...\n", .{});
    const serverAddress = try std.net.Address.parseIp4("206.189.113.124", 16963);
    const server = try std.net.tcpConnectToAddress(serverAddress);
    defer server.close();
    std.debug.print("connected!\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    var buf: [1024]u8 = undefined;
    conn: while (true) {
        std.debug.print("{any}\n", .{connection.address.in});
        const nBytes = try connection.stream.read(&buf);
        if (nBytes <= 0) break;

        for (buf[0..nBytes], 0..) |c, i| {
            if (c == '\n') {
                try data.appendSlice(buf[0 .. i + 1]); // Include newline
                try handleMsg(allocator, server, data.items);
                data.clearRetainingCapacity();
                try data.appendSlice(buf[i + 1 .. nBytes]);
                continue :conn;
            }
        }
        try data.appendSlice(buf[0..nBytes]);
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
