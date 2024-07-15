const std = @import("std");
const net = @import("std.net");

const User = struct { name: []const u8, connection: std.net.Server.Connection };

fn connect_user(server: *std.net.Server) !?User {
    const connection = server.accept() catch |err| switch (err) {
        error.WouldBlock => return null,
        else => |e| return e,
    };

    try connection.stream.writeAll("name?\n");
    var name_buf: [16]u8 = undefined;
    const n_bytes = try connection.stream.read(&name_buf);
    var i: usize = 0;
    while (i < n_bytes and name_buf[i] != '\n') : (i += 1) {}
    std.debug.print("Got user with name {s}\n", .{name_buf[0..i]});
    return User{ .name = name_buf[0..i], .connection = connection };
}

pub fn main() !void {
    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{server});

    var users = std.ArrayList(User).init(std.heap.page_allocator);
    if (try connect_user(&server)) |user| {
        try users.append(user);
    }
    std.debug.print("users is now {any}\n", .{users});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
