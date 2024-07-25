const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    var address = try std.net.Address.parseIp4("0.0.0.0", 3491);
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(sockfd);
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    var sock_len = address.getOsSockLen();
    try posix.bind(sockfd, &address.any, sock_len);
    try posix.getsockname(sockfd, &address.any, &sock_len);
    std.debug.print("Bound socket at {any}\n", .{address});

    var their_address: posix.sockaddr = undefined;
    var their_address_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var database = std.StringHashMap([]const u8).init(allocator);
    try database.put("version", "by OmeRikkert");

    var receive_buf: [1024]u8 = .{0} ** 1024;
    handle_loop: while (true) {
        std.debug.print("Waiting for packet...\n", .{});
        const n_bytes = try posix.recvfrom(sockfd, &receive_buf, 0, &their_address, &their_address_len);
        std.debug.print("got {any} bytes from {any}: {s}\n", .{ n_bytes, their_address, receive_buf[0..n_bytes] });

        var index_var: usize = 0;
        while (index_var < n_bytes) : (index_var += 1) {
            if (receive_buf[index_var] == '=') {
                const variable = receive_buf[0..index_var];
                const value = receive_buf[index_var + 1 .. n_bytes];
                std.debug.print("Writing variable {s} to value {s}\n", .{ variable, value });
                if (!std.mem.eql(u8, variable, "version")) {
                    // Allocate memory for variable if needed
                    var variable_buf: []u8 = undefined;
                    if (database.contains(variable)) {
                        variable_buf = variable;
                    } else {
                        variable_buf = try allocator.alloc(u8, variable.len);
                        std.mem.copyForwards(u8, variable_buf, variable);
                    }

                    const value_buf = try allocator.alloc(u8, value.len);
                    std.mem.copyForwards(u8, value_buf, value);

                    try database.put(variable_buf, value_buf);
                }
                // ???? Program doesn't pass first check if this is not sent.
                const n_sent = try posix.sendto(sockfd, receive_buf[0..n_bytes], 0, &their_address, their_address_len);
                std.debug.print("Echoed {d} bytes back: {s}\n", .{ n_sent, receive_buf[0..n_sent] });
                continue :handle_loop;
            }
        } else {
            const variable = receive_buf[0..n_bytes];
            const value = database.get(variable) orelse "";
            const n_sent = try posix.sendto(sockfd, value, 0, &their_address, their_address_len);
            std.debug.print("Echoed {d} bytes back: {s}\n", .{ n_sent, value });
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
