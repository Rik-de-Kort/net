const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    std.debug.print("Address: {any}\n", .{address});

    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    defer server.deinit();
    std.debug.print("server: {any}\n", .{server});

    while (true) {
        std.debug.print("waiting for connection...\n", .{});
        const connection = try server.accept();
        defer connection.stream.close();
        std.debug.print("stream: {any}\n", .{connection});

        var data = std.ArrayList(u8).init(allocator);
        defer data.deinit();
        var smallBuf: [1024]u8 = undefined;
        while (true) {
            std.debug.print("Waiting to read...\n", .{});
            const nBytesReceived = try connection.stream.read(&smallBuf);
            if (nBytesReceived <= 0) {
                break;
            }
            std.debug.print("Got {any} bytes: {s}\n", .{ nBytesReceived, smallBuf });

            try data.appendSlice(smallBuf[0..nBytesReceived]);
            std.debug.print("Appended, last byte is {any}\n", .{smallBuf[nBytesReceived - 1]});
            if (smallBuf[nBytesReceived - 1] < 0) { // EOF
                break;
            }
        }
        std.debug.print("Sending bytes...\n", .{});
        try connection.stream.writeAll(data.items);
        std.debug.print("Bytes sent\n", .{});
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
