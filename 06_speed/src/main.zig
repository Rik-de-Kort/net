const std = @import("std");
const net = std.net;
const posix = std.posix;
const poll = posix.POLL;
const Allocator = std.mem.Allocator;
const m = @import("messages.zig");

const Client = struct {
    stream: net.Stream,
    buf: [1024]u8,
    buf_idx: usize,
};

fn parse_message(client: *Client, allocator: std.mem.Allocator) !m.ClientMessage {
    if (client.buf_idx <= 1) return error.no_msg;

    inline for (std.meta.fields(m.ClientMessage)) |field| {
        const MessageType = @TypeOf(@field(@as(m.ClientMessage, undefined), field.name));

        if (MessageType.deserialize(&client.buf, allocator)) |msg| {
            return @unionInit(m.ClientMessage, field.name, msg);
        } else |_| {}
    }

    return error.no_msg;
}

fn read(client: *Client, allocator: Allocator) ![]u8 {
    const events = poll.IN | poll.HUP | poll.ERR;
    var pollfd: [1]posix.pollfd = .{.{ .fd = client.stream.handle, .events = events, .revents = 0 }};
    const n_events = try std.posix.poll(&pollfd, -1);
    std.debug.assert(n_events > 0);
    if (pollfd[0].revents & (poll.HUP | poll.ERR) > 0) {
        return error.disconnected;
    }
    if (pollfd[0].revents & poll.IN > 0) {
        const n_read = try client.stream.read(client.buf[client.buf_idx..]);
        client.buf_idx += n_read;
        std.log.info("{any}", .{try parse_message(client, allocator)});
    }
    unreachable;
}

fn handle(client: net.Stream) !void {
    defer client.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.log.info("connected!", .{});
    const myBuf: [1024]u8 = undefined;
    var my_client = Client{ .stream = client, .buf = myBuf, .buf_idx = 0 };
    _ = try read(&my_client, allocator);
}

pub fn main() !void {
    const address = try net.Address.parseIp4("0.0.0.0", 3491);
    var listener = try address.listen(.{ .reuse_address = true, .reuse_port = true });
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    while (true) {
        const connection = try listener.accept();
        _ = try std.Thread.spawn(.{}, handle, .{connection.stream});
    }
}
