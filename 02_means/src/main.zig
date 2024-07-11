const std = @import("std");

fn read_network_int(bytes: [4]u8) i32 {
    return @bitCast([_]u8{ bytes[3], bytes[2], bytes[1], bytes[0] });
}

test "read_network_int" {
    try std.testing.expectEqual(read_network_int("\x00\x00\x03\xe8".*), 1000);
    try std.testing.expectEqual(read_network_int("\x00\x00\x30\x39".*), 12345);
}

fn write_network_int(i: i32) [4]u8 {
    const bytes = @constCast(std.mem.asBytes(&i));
    std.mem.reverse(u8, bytes);
    return bytes.*;
}

test "write_network_int" {
    try std.testing.expect(std.mem.eql(u8, &write_network_int(1000), "\x00\x00\x03\xe8"));
    try std.testing.expect(std.mem.eql(u8, &write_network_int(12345), "\x00\x00\x30\x39"));
}

const Insert = packed struct {
    timestamp: i32,
    price: i32,

    fn from_bytes(bytes: [8]u8) Insert {
        std.debug.print("Parsing query message from {x}\n", .{bytes});
        return Insert{
            .timestamp = read_network_int(bytes[0..4].*),
            .price = read_network_int(bytes[4..8].*),
        };
    }
};
const Query = packed struct {
    mintime: i32,
    maxtime: i32,

    fn from_bytes(bytes: [8]u8) Query {
        return Query{
            .mintime = read_network_int(bytes[0..4].*),
            .maxtime = read_network_int(bytes[4..8].*),
        };
    }
};

test "query from bytes" {
    const first_query = Query.from_bytes("\x00\x00\x03\xe8\x00\x01\x86\xa0".*);
    try std.testing.expectEqual(1000, first_query.mintime);
    try std.testing.expectEqual(100000, first_query.maxtime);
}

const Database = struct {
    data: std.ArrayList(Insert),

    pub fn insert(self: *Database, msg: Insert) !void {
        std.debug.print("Got insert {any}\n", .{msg});
        for (self.data.items) |item| {
            if (item.timestamp == msg.timestamp) {
                return error.TimestampAlreadySet;
            }
        }
        try self.data.append(msg);
    }

    pub fn query(self: Database, msg: Query) !i32 {
        std.debug.print("Got query {any}. Database items: {any}\n", .{ msg, self.data.items });
        var sum: i128 = 0;
        var n: usize = 0;
        for (self.data.items) |item| {
            if (msg.mintime <= item.timestamp and item.timestamp <= msg.maxtime) {
                n += 1;
                sum += @as(i128, item.price);
            }
        }
        std.debug.print("n={any}, sum={any}\n", .{ n, sum });
        if (n == 0 and sum == 0) {
            return 0;
        } else {
            return @intCast(@divFloor(sum, n));
        }
    }
};

test "Database" {
    var database = Database{ .data = try std.ArrayList(Insert).initCapacity(std.testing.allocator, 4) };
    defer database.data.deinit();

    try database.insert(Insert{ .timestamp = 12345, .price = 101 });
    try database.insert(Insert{ .timestamp = 12346, .price = 102 });
    try database.insert(Insert{ .timestamp = 12347, .price = 100 });
    try database.insert(Insert{ .timestamp = 40960, .price = 5 });

    const query = Query{ .mintime = 12288, .maxtime = 16384 };
    try std.testing.expectEqual(101, database.query(query));
}

pub fn main() !void {
    const number: i32 = 0x3e8;
    const string = "\x00\x00\x03\xe8";
    const same = read_network_int(string.*);
    std.debug.print("{any}, {x}, {any}\n", .{ number, string, same });

    const number2: i32 = 1000;
    const bytes = std.mem.asBytes(&number2);
    std.debug.print("{any}, {x}, {x}\n", .{ number2, bytes, std.mem.asBytes(&@bitReverse(number2)) });

    const allocator = std.heap.page_allocator;

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    defer server.deinit();

    connection_loop: while (true) {
        std.debug.print("listening...\n", .{});
        const connection = try server.accept();
        defer connection.stream.close();

        const timeout: std.posix.timeval = .{ .tv_sec = 15, .tv_usec = 0 };
        try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        var database = Database{ .data = std.ArrayList(Insert).init(allocator) };
        var receive_buf: [9]u8 = [_]u8{0} ** 9;
        read_and_handle: while (true) {
            var bytes_read: usize = 0;
            while (bytes_read < 9) {
                std.debug.print("Trying to read more bytes (so far {x})\n", .{receive_buf});
                const n_bytes = connection.stream.read(receive_buf[bytes_read..]) catch |err| switch (err) {
                    error.WouldBlock => {
                        std.debug.print("Would block, bytes so far {x}\n", .{receive_buf});
                        continue :connection_loop;
                    },
                    else => |e| return e,
                };
                if (n_bytes <= 0) {
                    continue :connection_loop;
                }
                bytes_read += n_bytes;
                std.debug.print("Got {any} bytes, total bytes is now {any}: {x}\n", .{ n_bytes, bytes_read, receive_buf });
            }

            if (receive_buf[0] == 'I') {
                database.insert(Insert.from_bytes(receive_buf[1..].*)) catch |err| {
                    std.debug.print("Error handling database insert {any}", .{err});
                    continue :read_and_handle;
                };
            } else if (receive_buf[0] == 'Q') {
                const result = database.query(Query.from_bytes(receive_buf[1..].*)) catch |err| {
                    std.debug.print("Error handling database query {any}", .{err});
                    continue :read_and_handle;
                };
                std.debug.print("Query result {any}, sending...\n", .{result});
                connection.stream.writeAll(&write_network_int(result)) catch |err| switch (err) {
                    error.ConnectionResetByPeer => continue :connection_loop,
                    error.BrokenPipe => continue :connection_loop,
                    else => |e| return e,
                };
            } else {
                continue :connection_loop;
            }
        }
    }
}
