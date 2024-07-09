const std = @import("std");

const Insert = struct {
    timestamp: i32,
    price: i32,
    fn fromBytes(bytes: *[8]u8) Insert {
        return Insert{ .timestamp = @bitCast(*bytes[0..4]), .price = @bitCast(bytes[4..]) };
    }
};
const Query = struct {
    mintime: i32,
    maxtime: i32,
    fn fromBytes(bytes: *[8]u8) Query {
        return Query{ .mintime = @bitCast(*bytes[0..4]), .maxtime = @bitCast(*bytes[4..]) };
    }
};

const Database = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(Insert),

    pub fn insert(self: *Database, msg: Insert) !void {
        for (self.data.items) |item| {
            if (item.timestamp == msg.timestamp) {
                return error.TimestampAlreadySet;
            }
        }
        try self.data.append(msg);
    }

    pub fn query(self: Database, msg: Query) !i32 {
        var true_mean: f64 = 0;
        var n: f64 = 0;
        for (self.data.items) |item| {
            if (msg.mintime <= item.timestamp and item.timestamp <= msg.maxtime) {
                true_mean = (n / n + 1) * true_mean + item.price / n;
                n += 1;
            }
        }
        return @intFromFloat(true_mean);
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    defer server.deinit();

    connection_loop: while (true) {
        const connection = try server.accept();
        defer connection.stream.close();

        const timeout: std.posix.timeval = .{ .tv_sec = 10, .tv_usec = 0 };
        try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        var database = Database{ .allocator = allocator, .data = std.ArrayList(Insert).init(allocator) };
        var receiveBuf: [9]u8 = undefined;
        while (true) {
            const nBytesReceived = connection.stream.read(&receiveBuf) catch |err| switch (err) {
                error.WouldBlock => break :connection_loop,
                else => |e| return e,
            };
            if (nBytesReceived != 9) {
                break :connection_loop;
            }

            if (receiveBuf[0] == 'I') {
                database.insert(Insert.fromBytes(receiveBuf[1..])) catch break :connection_loop;
            } else if (receiveBuf[0] == 'Q') {
                const result = database.query(Query.fromBytes(receiveBuf[1..])) catch break :connection_loop;
                connection.stream.writeAll(std.mem.asBytes(result)) catch |err| switch (err) {
                    error.ConnectionResetByPeer => break :connection_loop,
                    error.BrokenPipe => break :connection_loop,
                    else => |e| return e,
                };
            } else {
                break :connection_loop;
            }
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
