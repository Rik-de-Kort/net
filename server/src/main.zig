const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stream = try std.net.tcpConnectToHost(allocator, "localhost", 3491);
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    const num = std.Random.int(random, u12);
    std.debug.print("Got {any}\n", .{num});

    const nBytesWritten = try stream.write("Hello, world!");
    std.debug.print("Wrote {any} bytes\n", .{nBytesWritten});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
