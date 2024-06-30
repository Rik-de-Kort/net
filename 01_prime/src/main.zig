const std = @import("std");
const posix = std.posix;

const PrimeInput = struct { method: *const [7]u8 = "isPrime", number: f64 };

fn isPrime(x: f64) bool {
    if (x < 0) {
        return false;
    }
    const floored: f64 = @divFloor(x, 1);
    if (floored != x) {
        return false;
    }

    const n: u64 = @intFromFloat(x);
    if (n == 1) {
        return false;
    }
    if (n == 2) {
        return true;
    }
    if (n % 2 == 0) {
        return false;
    }

    var i: u64 = 3;
    while (i * i <= n) : (i += 2) {
        if (n % i == 0) {
            return false;
        }
    }
    return true;
}

fn handle(allocator: std.mem.Allocator, msg: []u8) !std.ArrayList(u8) {
    const parsed = try std.json.parseFromSlice(
        PrimeInput,
        allocator,
        msg,
        .{},
    );
    defer parsed.deinit();

    std.debug.print("Parsed {any}\n", .{parsed.value});
    var result = std.ArrayList(u8).init(allocator);
    try std.json.stringify(.{ .method = "isPrime", .prime = isPrime(parsed.value.number) }, .{}, result.writer());
    try result.append(10);
    return result;
}

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
        connection_loop: while (true) {
            std.debug.print("stream: {any}\n", .{connection});

            var data = std.ArrayList(u8).init(allocator);
            defer data.deinit();
            var smallBuf: [39]u8 = undefined;
            var lastChar: u8 = undefined;
            // This doesn't work yet: client can send multiple messages, we would like to process them one at a time
            // If we know the size of a message (should be always the same since 64 bits for the number, rest is const)
            // Except sometimes a message can be only 38 bytes long??
            std.debug.print("Waiting to read...\n", .{});
            const nBytesReceived = try connection.stream.read(&smallBuf);
            if (nBytesReceived <= 0) {
                break;
            }
            std.debug.print("Got {any} bytes: {s}\n", .{ nBytesReceived, smallBuf });
            std.debug.print("as bytes {any}\n", .{smallBuf});

            try data.appendSlice(smallBuf[0..nBytesReceived]);
            std.debug.print("Appended, last byte is {any}\n", .{smallBuf[nBytesReceived - 1]});
            lastChar = smallBuf[nBytesReceived - 1];
            if (lastChar != 10) {
                break :connection_loop;
            }

            std.debug.print("Handling input {s}\n", .{data.items});
            const result = handle(allocator, data.items) catch {
                std.debug.print("Malformed input, continuing\n", .{});
                break :connection_loop;
            };
            defer result.deinit();

            std.debug.print("Sending bytes {s}\n", .{result.items});
            std.debug.print("Sending bytes (as bytes) {any}\n", .{result.items});
            try connection.stream.writeAll(result.items);
            std.debug.print("Bytes sent\n", .{});
            if (lastChar < 0) {
                break :connection_loop;
            }
        }
    }
}

const expect = std.testing.expect;

test "isprime function" {
    try expect(!isPrime(3.4));
    try expect(isPrime(3));
    try expect(!isPrime(4));
    try expect(!isPrime(121));
    try expect(isPrime(101));
    try expect(isPrime(2));
}
