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

fn isPrime(n: i128) bool {
    if (n < 0) {
        return false;
    }
    if (n == 1) {
        return false;
    }
    if (n == 2) {
        return true;
    }
    if (@mod(n, 2) == 0) {
        return false;
    }

    var i: i128 = 3;
    while (i * i <= n) : (i += 2) {
        if (@mod(n, i) == 0) {
            return false;
        }
    }
    return true;
}

fn handle(allocator: std.mem.Allocator, msg: []u8) !std.ArrayList(u8) {
    const parsed = try parseInput(allocator, msg);

    std.debug.print("Got method {s}\n", .{parsed.method});
    if (!stringEql(parsed.method, "isPrime")) {
        return error.WrongMethod;
    }

    std.debug.print("Parsed {any}\n", .{parsed});
    var result = std.ArrayList(u8).init(allocator);
    try std.json.stringify(.{ .method = "isPrime", .prime = isPrime(parsed.number) }, .{}, result.writer());
    try result.append('\n');
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
        if (end > self.input.len) {
            return error.ParseError;
        }
        if (!std.mem.eql(u8, self.input[self.position..end], bytes)) {
            std.debug.print("Expected {s} got {s}\n", .{ bytes, self.input[self.position..end] });
            return error.ParseError;
        }
        self.position = end;
    }

    pub fn expectQuotedString(self: *Parser) ParseError![]const u8 {
        try self.expect("\"");
        var escaped = false;
        var end = self.position;
        while (end < self.input.len and (escaped or self.input[end] != '"')) : (end += 1) {
            escaped = !escaped and self.input[end] == '\\'; // If previous char was \, then this \ is escaped and doesn't count
        }
        const result = self.input[self.position..end];
        try self.expect(result);
        try self.expect("\"");
        return result;
    }

    pub fn expectNumber(self: *Parser) ParseError!i128 {
        const start = self.position;

        if (self.input[self.position] == '-') {
            self.position += 1;
        }

        var seen_dot = false;
        var seen_e = false;

        while (self.position < self.input.len - 1) : (self.position += 1) {
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
                // self.position += 1; // Final add because we are breaking the loop
                break;
            }
        }

        const to_parse = self.input[start..self.position];
        std.debug.print("Trying to parse a float out of {s}\n", .{to_parse});

        _ = std.fmt.parseFloat(f64, to_parse) catch return error.ParseError;
        return std.fmt.parseInt(i128, to_parse, 10) catch return 4;
    }

    pub fn expectEnd(self: Parser) ParseError!void {
        if (self.position + 1 < self.input.len) {
            return error.ParseError;
        }
    }
};

fn parseInput(allocator: std.mem.Allocator, input: []const u8) (error{OutOfMemory} || ParseError)!PrimeInput {
    var parser = Parser{ .input = input };
    try parser.expect("{");
    var seen_method = false;
    var seen_number = false;
    var num: i128 = undefined;
    while (parser.position < parser.input.len) {
        const field = try parser.expectQuotedString();
        if (std.mem.eql(u8, field, "method")) {
            try parser.expect(":");
            try parser.expect("\"isPrime\"");
            seen_method = true;
        } else if (std.mem.eql(u8, field, "number")) {
            try parser.expect(":");
            num = try parser.expectNumber();
            seen_number = true;
        } else {
            try parser.expect(":");

            var stack = try std.ArrayList(u8).initCapacity(allocator, 10);
            defer stack.deinit();

            var scanning_string = false;
            var escaped = false;
            std.debug.print("scanning misc field {s}\n", .{parser.input[parser.position..]});

            // Todo: rewrite this using while loop with expect.
            for (parser.input[parser.position..]) |current_char| {
                // std.debug.print("{c} {any} {any} {s}\n", .{ current_char, parser.position, scanning_string, stack.items });
                parser.position += 1;

                if (scanning_string) {
                    if (!escaped and current_char == '"') {
                        scanning_string = false;
                        escaped = false;
                    } else {
                        // If previous char was \ and this char is \, then the next char is not escaped!
                        escaped = !escaped and current_char == '\\';
                    }
                    continue;
                }

                switch (current_char) {
                    '[' => try stack.append(current_char),
                    ']' => if (stack.items.len == 0 or stack.pop() != '[') {
                        return error.ParseError; // Mismatched closing bracket
                    },
                    '{' => try stack.append(current_char),
                    '}' => if (stack.items.len == 0) { // Fell off the end
                        parser.position -= 1;
                        std.debug.print("Found }} with empty stack, position {any}", .{parser.position});
                        break;
                    } else if (stack.pop() != '{') {
                        return error.ParseError; // Mismatched closing brace
                    },
                    '"' => scanning_string = true, // scanning_string is done above this switch so always set to true
                    ',' => if (stack.items.len == 0) {
                        parser.position -= 1;
                        std.debug.print("Found , with empty stack, position {any}", .{parser.position});
                        break;
                    },
                    else => {},
                }
            }
            std.debug.print("\nFell off the for loop at {any}\n", .{parser.position});
        }
        parser.expect(",") catch break;
    }
    if (!seen_number or !seen_method) {
        return error.ParseError;
    }
    std.debug.print("{s}, {any}, {any}\n", .{ parser.input, parser.position, parser.input.len });
    try parser.expect("}");
    try parser.expectEnd();
    return PrimeInput{ .method = "isPrime", .number = num };
}

const PrimeInput = struct { method: *const [7]u8, number: i128 };

test "builtin json" {
    const illegal_quotes = "{\"method\":\"isPrime\",\"number\":\"1389564\"}";
    const result = try std.json.parseFromSlice(PrimeInput, std.testing.allocator, illegal_quotes, .{});
    result.deinit();
}

test "builtin json2" {
    const illegal_quotes = "{\"method\":\"isPrime\",\"number\":\"1rerere564\"}";
    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(PrimeInput, std.testing.allocator, illegal_quotes, .{}));
}

test "json strictness" {
    const allocator = std.testing.allocator;

    const good = "{\"method\":\"isPrime\",\"number\":5337857}";
    _ = try parseInput(allocator, good);

    const good_with_object = "{\"method\":\"isPrime\",\"ignore\":{\"method\":\"isPrime\",\"number\":\"61097353\"},\"number\":5296481}";
    _ = try parseInput(allocator, good_with_object);

    const good_with_escape = "{\"method\":\"isPrime\",\"not\\\"method\":\"isntPrime\",\"number\":3525720}";
    _ = try parseInput(allocator, good_with_escape);

    const comment = "{\"method\":\"isPrime\",\"number\":5337857,\"comment\":\"wow zig is so cool\"}";
    _ = try parseInput(allocator, comment);

    const brackets = "{\"method\":\"isPrime\",\"number\":[5337857]}";
    try std.testing.expectError(error.ParseError, parseInput(allocator, brackets));

    const noMethod = "{\"number\":5337857}";
    try std.testing.expectError(error.ParseError, parseInput(allocator, noMethod));

    const illegalQuotes = "{\"method\":\"isPrime\",\"number\":\"1389564\"}";
    try std.testing.expectError(error.ParseError, parseInput(allocator, illegalQuotes));

    const wrongMethod = "{\"method\":\"primeis\",\"number\":5337857}";
    try std.testing.expectError(error.ParseError, parseInput(allocator, wrongMethod));
}
