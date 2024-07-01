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

            var data = std.ArrayList(u8).init(allocator); // All data received for this session
            defer data.deinit();

            var i: usize = 0; // Start of current message
            var receiveBuf: [64]u8 = undefined;

            read_and_handle: while (true) {
                std.debug.print("Waiting to read...\n", .{});
                const nBytesReceived = try connection.stream.read(&receiveBuf);
                if (nBytesReceived <= 0) {
                    break :read_and_handle;
                }
                std.debug.print("Got {any} bytes: {s}\n", .{ nBytesReceived, receiveBuf });
                std.debug.print("as bytes {any}\n", .{receiveBuf});

                try data.appendSlice(receiveBuf[0..nBytesReceived]);

                var j = i; // Index of \n (end of message)
                while (j < data.items.len) : (j += 1) {
                    if (data.items[j] == 10) {
                        break;
                    }
                } else { // No \n found, fetch more data
                    continue :read_and_handle;
                }

                const inputMsg = data.items[i..j];
                std.debug.print("Handling input {s}\n", .{inputMsg});
                const result = handle(allocator, inputMsg) catch {
                    std.debug.print("Malformed input, continuing\n", .{});
                    break :connection_loop;
                };
                defer result.deinit();

                std.debug.print("Sending bytes {s}\n", .{result.items});
                std.debug.print("Sending bytes (as bytes) {any}\n", .{result.items});
                try connection.stream.writeAll(result.items);
                std.debug.print("Bytes sent\n", .{});

                i = j + 1; // j is index of \n, add one to get start of new message
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
