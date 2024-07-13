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

    fn from_bytes(bytes: []u8) Insert {
        //std.debug.print("Parsing query message from {x}\n", .{bytes});
        return Insert{
            .timestamp = read_network_int(bytes[0..4].*),
            .price = read_network_int(bytes[4..8].*),
        };
    }
};
const Query = packed struct {
    mintime: i32,
    maxtime: i32,

    fn from_bytes(bytes: []u8) Query {
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
        //std.debug.print("Got insert {any}\n", .{msg});
        for (self.data.items) |item| {
            if (item.timestamp == msg.timestamp) {
                return error.TimestampAlreadySet;
            }
        }
        self.data.appendAssumeCapacity(msg);
        if (self.data.items.len % 1000 == 0) {
            std.debug.print("{any} items in database\n", .{self.data.items.len});
        }
    }

    pub fn query(self: Database, msg: Query) !i32 {
        //std.debug.print("Got query {any}. Database items: {any}\n", .{ msg, self.data.items.len });
        var sum: i128 = 0;
        var n: usize = 0;
        for (self.data.items) |item| {
            if (msg.mintime <= item.timestamp and item.timestamp <= msg.maxtime) {
                n += 1;
                sum += @as(i128, item.price);
            }
        }
        //std.debug.print("n={any}, sum={any}\n", .{ n, sum });
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

const Connection = struct { connection: std.net.Server.Connection, database: Database };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    const allocator = arena.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true, .force_nonblocking = true });
    defer server.deinit();

    var connections = std.ArrayList(std.net.Server.Connection).init(allocator);
    defer connections.deinit();
    var databases = std.ArrayList(Database).init(allocator);
    defer databases.deinit();

    std.debug.print("listening...\n", .{});
    while (true) {
        // Check for new connections
        //std.debug.print("Checking for new connections", .{});
        if (server.accept() catch |err| switch (err) {
            error.WouldBlock => null,
            else => |e| return e,
        }) |connection| {
            const timeout: std.posix.timeval = .{ .tv_sec = 0, .tv_usec = 25000 };
            try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

            try connections.append(connection);
            var database = Database{ .data = std.ArrayList(Insert).init(allocator) };
            try database.data.ensureTotalCapacity(200000);
            try databases.append(database);
        }

        // Handle any open connections
        var connections_to_clean = std.ArrayList(usize).init(allocator);
        per_connection: for (connections.items, databases.items, 0..) |connection, *database, i_conn| {
            // if (database.data.items.len % 1000 == 0) {
            // std.debug.print("Handling connection {any}. Items in database {any}\n", .{ i_conn, database.data.items.len });
            // }
            var receive_buf: [90000]u8 = [_]u8{0} ** 90000;
            var bytes_read: usize = 0;
            while (true) {
                while (bytes_read < 9) {
                    const n_bytes = connection.stream.read(receive_buf[bytes_read..]) catch |err| switch (err) {
                        error.WouldBlock => {
                            std.debug.print("would block!\n", .{});
                            continue :per_connection;
                        },
                        error.NotOpenForReading => {
                            std.debug.print("not open for reading!\n", .{});
                            try connections_to_clean.append(i_conn);
                            continue :per_connection;
                        },
                        else => |e| return e,
                    };
                    if (n_bytes <= 0) {
                        std.debug.print("n_bytes {any}\n", .{n_bytes});
                        try connections_to_clean.append(i_conn);
                        continue :per_connection;
                    }
                    bytes_read += n_bytes;
                }
                // std.debug.print("Got {any} bytes: {x}\n", .{ bytes_read, receive_buf });
                std.debug.print("Got {any} bytes\n", .{bytes_read});
                var i_msg: usize = 0;
                while (i_msg + 9 <= bytes_read) : (i_msg += 9) {
                    const msg = receive_buf[i_msg .. i_msg + 9];

                    if (msg[0] == 'I') {
                        database.insert(Insert.from_bytes(msg[1..])) catch |err| {
                            std.debug.print("Error handling database insert {any}\n", .{err});
                            continue :per_connection;
                        };
                    } else if (msg[0] == 'Q') {
                        const result = database.query(Query.from_bytes(msg[1..])) catch |err| {
                            std.debug.print("Error handling database query {any}\n", .{err});
                            continue :per_connection;
                        };
                        //std.debug.print("Query result {any}, sending...\n", .{result});
                        connection.stream.writeAll(&write_network_int(result)) catch |err| switch (err) {
                            error.ConnectionResetByPeer, error.BrokenPipe => {
                                try connections_to_clean.append(i_conn);
                                continue :per_connection;
                            },
                            else => |e| return e,
                        };
                    }
                }
                // Dump remaining content back into receive buf and continue
                const bytes_remaining = bytes_read - i_msg;
                for (0..bytes_remaining) |i_receive| {
                    receive_buf[i_receive] = receive_buf[i_msg + i_receive];
                }
                bytes_read = bytes_remaining;
            }
        }

        // Handle broken connections
        var connections_left = std.ArrayList(std.net.Server.Connection).init(allocator);
        var databases_left = std.ArrayList(Database).init(allocator);
        outer: for (connections.items, databases.items, 0..) |connection, database, i| {
            for (connections_to_clean.items) |j| {
                if (i == j) {
                    //std.debug.print("Removing connection {any}\n", .{i});
                    database.data.deinit();
                    continue :outer;
                }
            }
            try connections_left.append(connection);
            try databases_left.append(database);
        }
        connections.clearAndFree();
        databases.clearAndFree();
        connections = connections_left;
        databases = databases_left;
    }
}
