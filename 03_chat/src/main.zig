const std = @import("std");
const net = @import("std.net");

const User = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    connection: std.net.Server.Connection,

    fn deinit(self: User) void {
        self.allocator.free(self.name);
        self.connection.close();
    }
};

fn connect_user(allocator: std.mem.Allocator, server: *std.net.Server) !?User {
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
    var name = try allocator.alloc(u8, name_length);
    @memcpy(name[0..name_length], name_buf[0..name_length]);
    return User{ .allocator = allocator, .name = name, .connection = connection };
}

fn present_users_message(users: std.ArrayList(User)) !std.ArrayList(u8) {
    var result = std.ArrayList(u8).init(users.allocator);
    try result.appendSlice("* The room contains: ");
    if (users.items.len > 0) {
        try result.appendSlice(users.items[0].name);
        for (users.items[1..]) |user| {
            try result.appendSlice(", ");
            try result.appendSlice(user.name);
        }
    }
    try result.append('\n');
    return result;
}

fn joined_user_message(user: User) !std.ArrayList(u8) {
    var result = std.ArrayList(u8).init(user.allocator);
    try result.appendSlice("* ");
    try result.appendSlice(user.name);
    try result.appendSlice(" has joined the room\n");
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    var server = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("{any}\n", .{server});

    var users = std.ArrayList(User).init(allocator);
    while (true) {
        if (connect_user(allocator, &server) catch null) |new_user| {
            // std.debug.print("got user {any}\n", .{new_user});

            // Send message who is already in room
            const presence_message = try present_users_message(users);
            defer presence_message.deinit();
            try new_user.connection.stream.writeAll(presence_message.items);

            // Send message who joined
            const join_message = try joined_user_message(new_user);
            defer join_message.deinit();
            for (users.items) |user| {
                try user.connection.stream.writeAll(join_message.items);
            }

            try users.append(new_user);
        }
    }
}
