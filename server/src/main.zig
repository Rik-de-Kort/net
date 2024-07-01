const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stream = try std.net.tcpConnectToHost(allocator, "localhost", 3491);
    defer stream.close();

    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    // Reusing this buffer seems to encounter some use-after-free :)
    var msg = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const num = std.Random.int(random, u12);
        try std.json.stringify(.{ .method = "isPrime", .number = num }, .{}, msg.writer());
        try msg.append(10);
        std.debug.print("Writing {s}\n", .{msg.items});
        const nBytesWritten = try stream.write(msg.items);
        std.debug.print("Wrote {any} bytes\n", .{nBytesWritten});
        msg.clearAndFree();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
