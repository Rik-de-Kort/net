const std = @import("std");

fn parse_network_int(bytes: [4]u8) i32 {
    const i: i32 = @bitCast(bytes);
    return @bitReverse(i);
}

const Insert = packed struct {
    timestamp: i32,
    price: i32,

    fn from_bytes(bytes: [8]u8) Insert {
        std.debug.print("Parsing query message from {s}\n", .{bytes});
        return Insert{
            .timestamp = parse_network_int(bytes[0..4].*),
            .price = parse_network_int(bytes[4..8].*),
        };
    }
};
const Query = packed struct {
    mintime: i32,
    maxtime: i32,

    fn from_bytes(bytes: [8]u8) Query {
        std.debug.print("Parsing query message from {s}\n", .{bytes});
        return Query{
            .mintime = parse_network_int(bytes[4..8].*),
            .maxtime = parse_network_int(bytes[0..4].*),
        };
    }
};

test "query from bytes" {
    const first_query = Query.from_bytes("\x00\x00\x03\xe8\x00\x01\x86\xa0".*);
    try std.testing.expectEqual(1000, first_query.mintime);
    try std.testing.expectEqual(100000, first_query.maxtime);
}

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
        std.debug.print("Got query {any}. Database items: {any}", .{ msg, self.data.items });
        var true_mean: f64 = 0;
        var n: f64 = 0;
        for (self.data.items) |item| {
            if (msg.mintime <= item.timestamp and item.timestamp <= msg.maxtime) {
                const price: f64 = @floatFromInt(item.price);
                true_mean = (n / n + 1) * true_mean + price / n;
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
    std.debug.print("listening...\n", .{});

    connection_loop: while (true) {
        const connection = try server.accept();
        defer connection.stream.close();

        const timeout: std.posix.timeval = .{ .tv_sec = 10, .tv_usec = 0 };
        try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        var database = Database{ .allocator = allocator, .data = std.ArrayList(Insert).init(allocator) };
        var receive_buf: [9]u8 = undefined;
        while (true) {
            var bytes_read: usize = 0;
            while (bytes_read < 9) {
                const n_bytes = connection.stream.read(receive_buf[bytes_read..]) catch |err| switch (err) {
                    error.WouldBlock => break :connection_loop,
                    else => |e| return e,
                };
                if (n_bytes <= 0) {
                    break :connection_loop;
                }
                bytes_read += n_bytes;
                std.debug.print("Got {any} bytes, total bytes is now {any}: {s}\n", .{ n_bytes, bytes_read, receive_buf });
            }

            if (receive_buf[0] == 'I') {
                database.insert(Insert.from_bytes(receive_buf[1..].*)) catch break :connection_loop;
            } else if (receive_buf[0] == 'Q') {
                const result = database.query(Query.from_bytes(receive_buf[1..].*)) catch break :connection_loop;
                std.debug.print("Query result {any}, sending...\n", .{result});
                connection.stream.writeAll(std.mem.asBytes(&result)) catch |err| switch (err) {
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
