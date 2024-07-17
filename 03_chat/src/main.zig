const std = @import("std");
const net = @import("std.net");

const User = struct { name: []const u8, connection: std.net.Server.Connection };

fn connect_user(server: *std.net.Server) !?User {
    const connection = server.accept() catch |err| switch (err) {
        error.WouldBlock => return null,
        else => |e| return e,
    };
    errdefer connection.stream.close();

    try connection.stream.writeAll("name?\n");
    var name_buf: [16]u8 = undefined;
    const n_bytes = try connection.stream.read(&name_buf);
    if (n_bytes <= 0 or 16 <= n_bytes) { // Todo: what if we only got one byte, equal to \n?
        return error.InvalidLength;
    }
    var name_length: usize = 0;
    for (name_buf[0..n_bytes]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '\n') {
            return error.InvalidCharacter;
        } else if (byte == '\n') {
            break;
        }
        name_length += 1;
    }
    std.debug.print("Got user with name {s}\n", .{name_buf[0..name_length]});
    return User{ .name = name_buf[0..name_length], .connection = connection };
}

fn present_users_message(users: std.ArrayList(User)) ![]const u8 {
    var result = std.ArrayList(u8).init(users.allocator);
    try result.appendSlice("* The room contains: ");
    if (users.items.len == 0) return result.toOwnedSlice();
    try result.appendSlice(users.items[0].name);
    for (users.items[1..]) |user| {
        try result.appendSlice(", ");
        try result.appendSlice(user.name);
    }
    return result.toOwnedSlice();
}

pub fn main() !void {
    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{server});

    var users = std.ArrayList(User).init(std.heap.page_allocator);
    while (true) {
        if (connect_user(&server) catch null) |user| {
            const message = try present_users_message(users);
            std.debug.print("{s}", .{message});
            try user.connection.stream.writeAll(message);
            std.heap.page_allocator.free(message);

            try users.append(user);
        }
        std.debug.print("users is now {any}\n", .{users});
    }
}
