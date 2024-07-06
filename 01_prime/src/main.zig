const std = @import("std");
const posix = std.posix;

pub fn stringEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |a_elem, b_elem| {
        if (a_elem != b_elem) return false;
    }
    return true;
}

const PrimeInput = struct { method: *const [7]u8, number: f64 };

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
    // Todo: hand-roll parser
    const parsed = try std.json.parseFromSlice(
        PrimeInput,
        allocator,
        msg,
        .{},
    );
    defer parsed.deinit();

    std.debug.print("Got method {s}\n", .{parsed.value.method});
    if (!stringEql(parsed.value.method, "isPrime")) {
        return error.WrongMethod;
    }

    std.debug.print("Parsed {any}\n", .{parsed.value});
    var result = std.ArrayList(u8).init(allocator);
    try std.json.stringify(.{ .method = "isPrime", .prime = isPrime(parsed.value.number) }, .{}, result.writer());
    try result.append(10);
    return result;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const wrongMethod = "{\"method\":\"primeis\",\"number\":5337857}";
    const result2 = try std.json.parseFromSlice(PrimeInput, allocator, wrongMethod, .{});
    defer result2.deinit();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    std.debug.print("Address: {any}\n", .{address});

    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    defer server.deinit();
    std.debug.print("server: {any}\n", .{server});

    while (true) {
        std.debug.print("waiting for connection...\n", .{});
        const connection = try server.accept();
        defer connection.stream.close();

        const timeout: std.posix.timeval = .{ .tv_sec = 10, .tv_usec = 0 };
        try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        connection_loop: while (true) {
            std.debug.print("stream: {any}\n", .{connection});

            var data = std.ArrayList(u8).init(allocator); // All data received for this session
            defer data.deinit();

            var i: usize = 0; // Start of current message
            var receiveBuf: [64]u8 = undefined;

            read_and_handle: while (true) {
                std.debug.print("Waiting to read...\n", .{});
                const nBytesReceived = connection.stream.read(&receiveBuf) catch |err| switch (err) {
                    error.WouldBlock => break :connection_loop,
                    else => |e| return e,
                };
                if (nBytesReceived <= 0) {
                    std.debug.print("No bytes received, cleaning up connection\n", .{});
                    break :connection_loop;
                }
                std.debug.print("Got {any} bytes: {s}\n", .{ nBytesReceived, receiveBuf });
                std.debug.print("as bytes {any}\n", .{receiveBuf});

                try data.appendSlice(receiveBuf[0..nBytesReceived]);

                while (true) {
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
                    std.debug.print("Remaining in memory {s}\n", .{data.items[j..]});
                    const result = handle(allocator, inputMsg) catch {
                        std.debug.print("Malformed input, continuing\n", .{});
                        break :connection_loop;
                    };
                    defer result.deinit();

                    std.debug.print("Sending bytes {s}\n", .{result.items});
                    std.debug.print("Sending bytes (as bytes) {any}\n", .{result.items});
                    connection.stream.writeAll(result.items) catch |err| switch (err) {
                        error.ConnectionResetByPeer => break :connection_loop,
                        error.BrokenPipe => break :connection_loop,
                        else => |e| return e,
                    };
                    std.debug.print("Bytes sent\n", .{});

                    i = j + 1; // j is index of \n, add one to get start of new message
                }
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

test "string equal method" {
    try expect(stringEql("aaaa", "aaaa"));
    try expect(!stringEql("primeis", "isPrime"));
}

const ParseError = error{ParseError};

const Parser = struct {
    input: []const u8,
    position: usize = 0,

    pub fn expect(self: *Parser, bytes: []const u8) ParseError!void {
        const end = self.position + bytes.len;
        if (!std.mem.eql(u8, self.input[self.position..end], bytes)) {
            std.debug.print("Expected {s} got {s}\n", .{ bytes, self.input[self.position..end] });
            return error.ParseError;
        }
        self.position = end;
    }

    pub fn expectQuotedString(self: *Parser) ParseError![]const u8 {
        try self.expect("\"");
        var end = self.position;
        while (end < self.input.len and self.input[end] != '"') : (end += 1) {}
        const result = self.input[self.position..end];
        try self.expect(result);
        try self.expect("\"");
        return result;
    }

    pub fn expectNumber(self: *Parser) ParseError!f64 {
        const start = self.position;

        var seen_dot = false;
        var seen_e = false;

        while (self.position < self.input.len) : (self.position += 1) {
            const current_char = self.input[self.position];
            if (current_char == '.') {
                if (seen_dot or seen_e) { // Dot not allowed after e
                    return error.ParseError;
                } else {
                    seen_dot = true;
                }
            } else if (current_char == 'e') {
                if (seen_e) {
                    return error.ParseError;
                } else {
                    seen_e = true;
                }
            } else if (!std.ascii.isDigit(current_char)) {
                break;
            }
        } else {
            return error.ParseError;
        }

        self.position += 1; // Final add because we broke the loop

        const to_parse = self.input[start..self.position];
        std.debug.print("Trying to parse a float out of {s}\n", .{to_parse});

        const result: f64 = std.fmt.parseFloat(f64, to_parse) catch blk: {
            const parsedInt = std.fmt.parseInt(u64, to_parse, 10) catch return error.ParseError;
            const intAsFloat: f64 = @floatFromInt(parsedInt);
            break :blk intAsFloat;
        };
        return result;
    }

    pub fn expectEnd(self: Parser) ParseError!void {
        if (self.position + 1 < self.input.len) {
            return error.ParseError;
        }
    }
};

fn parseInput(input: []const u8) ParseError!PrimeInput {
    var parser = Parser{ .input = input };
    try parser.expect("{");
    var num: f64 = undefined;
    const field = try parser.expectQuotedString();
    if (std.mem.eql(u8, field, "method")) {
        try parser.expect(":");
        try parser.expect("\"isPrime\"");
        try parser.expect(",");
        try parser.expect("\"number\":");
        num = try parser.expectNumber();
        try parser.expect("}");
        try parser.expectEnd();
    } else if (std.mem.eql(u8, field, "number")) {
        try parser.expect(":");
        num = try parser.expectNumber();
        try parser.expect(",");
        try parser.expect("\"method\":\"isPrime\"}");
        try parser.expectEnd();
    } else {
        return error.ParseError;
    }
    return PrimeInput{ .method = "isPrime", .number = num };
}

test "json strictness" {
    _ = try (std.fmt.parseFloat(f64, "5337857") catch std.fmt.parseInt(f64, "5337857", 10));

    var parser = Parser{ .input = "5337857" };
    _ = try parser.expectNumber();

    const good = "{\"method\":\"isPrime\",\"number\":5337857}";
    _ = try parseInput(good);

    const brackets = "{\"method\":\"isPrime\",\"number\":[5337857]}";
    try std.testing.expectError(error.ParseError, parseInput(brackets));

    const noMethod = "{\"number\":5337857}";
    try std.testing.expectError(error.ParseError, parseInput(noMethod));

    const illegalQuotes = "{\"method\":\"isPrime\",\"number\":\"1389564\"}";
    try std.testing.expectError(error.ParseError, parseInput(illegalQuotes));

    const wrongMethod = "{\"method\":\"primeis\",\"number\":5337857}";
    try std.testing.expectError(error.ParseError, parseInput(wrongMethod));
}
