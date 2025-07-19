const std = @import("std");
const net = std.net;
const posix = std.posix;
const poll = posix.POLL;
const Allocator = std.mem.Allocator;

fn to_u32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) + @as(u32, bytes[1]) * 8 + @as(u32, bytes[2]) * 8 * 8 + @as(u32, bytes[3]) * 8 * 8 * 8;
}

fn to_u16(bytes: []const u8) u16 {
    std.debug.assert(bytes.len == 4);
    return @as(u16, bytes[0]) + @as(u16, bytes[1]) * 8;
}

test "to_u32" {
    try std.testing.expectEqual(to_u32(&.{ 1, 0, 1, 0 }), 65);
}

const ClientMessage = union {
    plate: PlateMessage,
    want_heartbeat: WantHeartbeatMessage,
    i_am_camera: IAmCameraMessage,
};

const PlateMessage = struct {
    plate: []const u8,
    timestamp: u32,

    fn parse(bytes: []u8, allocator: std.mem.Allocator) !PlateMessage {
        if (bytes.len <= 2) return error.bytes_too_small;
        if (bytes[0] != '\x20') return error.not_a_plate;

        const plate_len: usize = bytes[1];
        if (bytes.len < 2 + plate_len + 4) return error.bytes_too_small;

        var plate: []u8 = try allocator.alloc(u8, plate_len);
        errdefer allocator.destroy(plate);
        @memcpy(plate[0..plate_len], bytes[2 .. 2 + plate_len]);

        const timestamp: u32 = to_u32(bytes[2 + plate_len .. 2 + plate_len + 4]);
        return PlateMessage{ .plate = plate, .timestamp = timestamp };
    }
};

const WantHeartbeatMessage = struct {
    interval: u32,

    fn parse(bytes: []u8) !WantHeartbeatMessage {
        if (bytes.len < 5) return error.bytes_too_small;
        if (bytes[0] != '\x40') return error.not_a_want_heartbeat;
        return WantHeartbeatMessage{ .interval = to_u32(bytes[1..5]) };
    }
};

const IAmCameraMessage = struct {
    road: u16,
    mile: u16,
    limit: u16,

    fn parse(bytes: []u8) !IAmCameraMessage {
        if (bytes.len < 7) return error.bytes_too_small;
        if (bytes[0] != '\x80') return error.not_a_i_am_camera;
        return IAmCameraMessage{
            .road = to_u16(bytes[1..3]),
            .mile = to_u16(bytes[3..5]),
            .limit = to_u16(bytes[5..7]),
        };
    }
};

const Client = struct {
    stream: net.Stream,
    buf: [1024]u8,
    buf_idx: usize,
};

fn parse_message(client: *Client, allocator: std.mem.Allocator) !ClientMessage {
    if (client.buf_idx <= 1) return error.no_msg;

    if (PlateMessage.parse(&client.buf, allocator)) |msg| {
        return .{ .plate = msg };
    } else |_| {}

    if (WantHeartbeatMessage.parse(&client.buf)) |msg| {
        return .{ .want_heartbeat = msg };
    } else |_| {}

    if (IAmCameraMessage.parse(&client.buf)) |msg| {
        return .{ .i_am_camera = msg };
    } else |_| {}

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
