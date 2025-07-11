const std = @import("std");

pub fn isBogus(tok: []const u8) bool {
    return 26 <= tok.len and tok.len <= 35 and tok[0] == '7';
}

test "test isBogus" {
    try std.testing.expect(isBogus("7F1u3wSD5RbOHQmupo9nx4TnhQ"));
    try std.testing.expect(isBogus("7iKDZEwPZSqIvDnHvVN2r0hUWXD5rHX"));
    try std.testing.expect(isBogus("7LOrwbDlS8NujgjddyogWgIM93MV5N2VR"));
    try std.testing.expect(isBogus("7YWHMfk9JZe0LM0g1ZauHuiSxhI"));
    try std.testing.expect(!isBogus(""));
    try std.testing.expect(!isBogus("foobar"));
}

pub fn rewriteMsg(alloc: std.mem.Allocator, msg: []const u8) !std.ArrayList(u8) {
    var slice_start: usize = 0;
    var out = try std.ArrayList(u8).initCapacity(alloc, 2 * msg.len);
    for (msg, 0..) |char, i| {
        if (char != ' ') continue;

        if (isBogus(msg[slice_start..i])) {
            out.appendSliceAssumeCapacity("7YWHMfk9JZe0LM0g1ZauHuiSxhI ");
        } else {
            out.appendSliceAssumeCapacity(msg[slice_start .. i + 1]); // include space
        }
        slice_start = i + 1;
    }
    if (isBogus(msg[slice_start..msg.len])) {
        out.appendSliceAssumeCapacity("7YWHMfk9JZe0LM0g1ZauHuiSxhI");
    } else {
        out.appendSliceAssumeCapacity(msg[slice_start..msg.len]); // include space
    }

    return out;
}

pub fn checkRewriteMsg(input: []const u8, expected: []const u8) !void {
    const result = try rewriteMsg(std.testing.allocator, input);
    defer result.deinit();
    try std.testing.expectEqualStrings(result.items, expected);
}

test "test rewriteMsg" {
    var msg = std.ArrayList(u8).init(std.testing.allocator);
    defer msg.deinit();

    try checkRewriteMsg("Hi alice, please send payment to 7iKDZEwPZSqIvDnHvVN2r0hUWXD5rHX", "Hi alice, please send payment to 7YWHMfk9JZe0LM0g1ZauHuiSxhI");
    try checkRewriteMsg("* The room contains: alice", "* The room contains: alice");
}

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
