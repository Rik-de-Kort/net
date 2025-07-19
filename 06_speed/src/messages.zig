const std = @import("std");
const Allocator = std.mem.Allocator;

fn to_u16(bytes: []const u8) u16 {
    const result = std.mem.readInt(u16, bytes, .big);
    // std.debug.print("to: got {any}, wrote {}\n", .{ bytes, result });
    return result;
}

fn from_u16(n: u16) [2]u8 {
    var result: [2]u8 = undefined;
    std.mem.writeInt(u16, &result, n, .big);
    // std.debug.print("from: got {}, wrote {any}\n", .{ n, result });
    return result;
}

fn to_u32(bytes: *const [4]u8) u32 {
    const result = std.mem.readInt(u32, bytes, .big);
    // std.debug.print("to: got {any}, wrote {}\n", .{ bytes, result });
    return result;
}

fn from_u32(n: u32) [4]u8 {
    var result: [4]u8 = undefined;
    std.mem.writeInt(u32, &result, n, .big);
    // std.debug.print("from: got {}, wrote {any}\n", .{ n, result });
    return result;
}

test "to_u32" {
    const x: [4]u8 = .{ 1, 0, 1, 0 };
    try std.testing.expectEqual(to_u32(&x), try std.math.powi(u32, 2, 8) + try std.math.powi(u32, 2, 24));
}

test "to_u32_roundtrip" {
    const x: [4]u8 = .{ 1, 0, 1, 0 };
    try std.testing.expectEqual(from_u32(to_u32(&x)), x);
    try std.testing.expectEqual(to_u32(&from_u32(34)), 34);
}

pub const ClientMessage = union {
    plate: PlateMessage,
    want_heartbeat: WantHeartbeatMessage,
    i_am_camera: IAmCameraMessage,
    i_am_dispatcher: IAmDispatcherMessage,
};

pub const ServerMessage = union {
    error_msg: ErrorMessage,
    ticket: TicketMessage,
    heartbeat: HeartbeatMessage,
};

const PlateMessage = struct {
    plate: []const u8,
    timestamp: u32,

    fn deserialize(bytes: []u8, allocator: Allocator) !PlateMessage {
        if (bytes.len <= 2) return error.bytes_too_small;
        if (bytes[0] != '\x20') return error.not_a_plate;
        const plate_len: usize = std.mem.readInt(u8, bytes[1..2], .big);
        // std.debug.print("plate len {}\n", .{plate_len});
        if (bytes.len < 2 + plate_len + 4) return error.bytes_too_small;
        var plate: []u8 = try allocator.alloc(u8, plate_len);
        errdefer allocator.free(plate);
        @memcpy(plate[0..plate_len], bytes[2 .. 2 + plate_len]);
        const timestamp: u32 = to_u32(@ptrCast(bytes[2 + plate_len .. 2 + plate_len + 4]));
        return PlateMessage{ .plate = plate, .timestamp = timestamp };
    }

    fn serialize(self: PlateMessage, allocator: Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + (1 + self.plate.len) + 4);
        result[0] = '\x20';
        std.mem.writeInt(u8, result[1..2], @as(u8, @intCast(self.plate.len)), .big);
        @memcpy(result[2 .. 2 + self.plate.len], self.plate);
        @memcpy(result[2 + self.plate.len .. 2 + self.plate.len + 4], &from_u32(self.timestamp));
        return result;
    }
};

test "PlateMessage serialization" {
    const msg = PlateMessage{
        .plate = "hello",
        .timestamp = 23484,
    };
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    // std.debug.print("{any} - with {any}\n", .{ serialized, "hello" });
    const result = try PlateMessage.deserialize(serialized, std.testing.allocator);
    defer std.testing.allocator.free(result.plate);
    try std.testing.expectEqualStrings(msg.plate, result.plate);
    try std.testing.expectEqual(msg.timestamp, result.timestamp);
}

const WantHeartbeatMessage = struct {
    interval: u32,

    fn deserialize(bytes: []u8, allocator: Allocator) !WantHeartbeatMessage {
        _ = allocator;
        if (bytes.len < 5) return error.bytes_too_small;
        if (bytes[0] != '\x40') return error.not_a_want_heartbeat;
        return WantHeartbeatMessage{ .interval = to_u32(bytes[1..5]) };
    }

    fn serialize(self: WantHeartbeatMessage, allocator: Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + 4);
        result[0] = '\x40';
        @memcpy(result[1 .. 1 + 4], &from_u32(self.interval));
        return result;
    }
};

test "WantHeartbeatMessage serialization" {
    const msg = WantHeartbeatMessage{
        .interval = 23484,
    };
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    // std.debug.print("{any} - with {any}\n", .{ serialized, "hello" });
    const result = try WantHeartbeatMessage.deserialize(serialized);
    try std.testing.expectEqual(msg.interval, result.interval);
}

const IAmCameraMessage = struct {
    road: u16,
    mile: u16,
    limit: u16,

    fn deserialize(bytes: []u8, allocator: Allocator) !IAmCameraMessage {
        _ = allocator;
        if (bytes.len < 7) return error.bytes_too_small;
        if (bytes[0] != '\x80') return error.not_a_i_am_camera;
        return IAmCameraMessage{
            .road = to_u16(bytes[1..3]),
            .mile = to_u16(bytes[3..5]),
            .limit = to_u16(bytes[5..7]),
        };
    }

    fn serialize(self: IAmCameraMessage, allocator: Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + 2 + 2 + 2);
        result[0] = '\x80';
        @memcpy(result[1 .. 1 + 2], &from_u16(self.road));
        @memcpy(result[3 .. 3 + 2], &from_u16(self.mile));
        @memcpy(result[5 .. 5 + 2], &from_u16(self.limit));
        return result;
    }
};

test "IAmCameraMessage serialization" {
    const msg = IAmCameraMessage{
        .road = 66,
        .mile = 100,
        .limit = 60,
    };
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    const result = try IAmCameraMessage.deserialize(serialized);
    try std.testing.expectEqual(msg.road, result.road);
    try std.testing.expectEqual(msg.mile, result.mile);
    try std.testing.expectEqual(msg.limit, result.limit);
}

const IAmDispatcherMessage = struct {
    roads: []u16,

    fn deserialize(bytes: []u8, allocator: Allocator) !IAmDispatcherMessage {
        if (bytes.len < 2) return error.bytes_too_small;
        if (bytes[0] != '\x81') return error.not_a_i_am_dispatcher;
        const numroads: usize = bytes[1];
        if (bytes.len < 2 + numroads * 2) return error.bytes_too_small;
        var roads: []u16 = try allocator.alloc(u16, numroads);
        errdefer allocator.free(roads);
        for (0..numroads) |i| {
            roads[i] = to_u16(bytes[2 + i * 2 .. 2 + i * 2 + 2]);
        }
        return IAmDispatcherMessage{ .roads = roads };
    }

    fn serialize(self: IAmDispatcherMessage, allocator: Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + 1 + (self.roads.len * 2));
        result[0] = '\x81';
        std.mem.writeInt(u8, result[1..2], @as(u8, @intCast(self.roads.len)), .big);
        for (self.roads, 0..) |road, i| {
            const offset = 2 + i * 2;
            @memcpy(result[offset .. offset + 2], &from_u16(road));
        }
        return result;
    }
};

test "IAmDispatcherMessage serialization" {
    var roads = [_]u16{ 66, 368, 5000 };
    const msg = IAmDispatcherMessage{
        .roads = &roads,
    };
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    const result = try IAmDispatcherMessage.deserialize(serialized, std.testing.allocator);
    defer std.testing.allocator.free(result.roads);
    try std.testing.expectEqual(msg.roads.len, result.roads.len);
    for (msg.roads, result.roads) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

const ErrorMessage = struct {
    msg: []const u8,

    fn deserialize(bytes: []u8, allocator: Allocator) !ErrorMessage {
        if (bytes.len <= 2) return error.bytes_too_small;
        if (bytes[0] != '\x10') return error.not_an_error;
        const msg_len: usize = std.mem.readInt(u8, bytes[1..2], .big);
        if (bytes.len < 2 + msg_len) return error.bytes_too_small;
        var msg: []u8 = try allocator.alloc(u8, msg_len);
        errdefer allocator.free(msg);
        @memcpy(msg[0..msg_len], bytes[2 .. 2 + msg_len]);
        return ErrorMessage{ .msg = msg };
    }

    fn serialize(self: ErrorMessage, allocator: Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + 1 + self.msg.len);
        result[0] = '\x10';
        std.mem.writeInt(u8, result[1..2], @as(u8, @intCast(self.msg.len)), .big);
        @memcpy(result[2 .. 2 + self.msg.len], self.msg);
        return result;
    }
};

test "ErrorMessage serialization" {
    const msg = ErrorMessage{
        .msg = "illegal msg",
    };
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    const result = try ErrorMessage.deserialize(serialized, std.testing.allocator);
    defer std.testing.allocator.free(result.msg);
    try std.testing.expectEqualStrings(msg.msg, result.msg);
}

const TicketMessage = struct {
    plate: []const u8,
    road: u16,
    mile1: u16,
    timestamp1: u32,
    mile2: u16,
    timestamp2: u32,
    speed: u16,

    fn deserialize(bytes: []u8, allocator: Allocator) !TicketMessage {
        if (bytes.len <= 2) return error.bytes_too_small;
        if (bytes[0] != '\x21') return error.not_a_ticket;
        const plate_len: usize = std.mem.readInt(u8, bytes[1..2], .big);
        if (bytes.len < 2 + plate_len + 16) return error.bytes_too_small;

        var plate: []u8 = try allocator.alloc(u8, plate_len);
        errdefer allocator.free(plate);
        @memcpy(plate[0..plate_len], bytes[2 .. 2 + plate_len]);

        const offset = 2 + plate_len;
        const road: u16 = to_u16(bytes[offset .. offset + 2]);
        const mile1: u16 = to_u16(bytes[offset + 2 .. offset + 4]);
        const timestamp1: u32 = to_u32(@ptrCast(bytes[offset + 4 .. offset + 8]));
        const mile2: u16 = to_u16(bytes[offset + 8 .. offset + 10]);
        const timestamp2: u32 = to_u32(@ptrCast(bytes[offset + 10 .. offset + 14]));
        const speed: u16 = to_u16(bytes[offset + 14 .. offset + 16]);

        return TicketMessage{
            .plate = plate,
            .road = road,
            .mile1 = mile1,
            .timestamp1 = timestamp1,
            .mile2 = mile2,
            .timestamp2 = timestamp2,
            .speed = speed,
        };
    }

    fn serialize(self: TicketMessage, allocator: Allocator) ![]u8 {
        var result = try allocator.alloc(u8, 1 + 1 + self.plate.len + 16);
        result[0] = '\x21';
        std.mem.writeInt(u8, result[1..2], @as(u8, @intCast(self.plate.len)), .big);
        @memcpy(result[2 .. 2 + self.plate.len], self.plate);

        const offset = 2 + self.plate.len;
        @memcpy(result[offset .. offset + 2], &from_u16(self.road));
        @memcpy(result[offset + 2 .. offset + 4], &from_u16(self.mile1));
        @memcpy(result[offset + 4 .. offset + 8], &from_u32(self.timestamp1));
        @memcpy(result[offset + 8 .. offset + 10], &from_u16(self.mile2));
        @memcpy(result[offset + 10 .. offset + 14], &from_u32(self.timestamp2));
        @memcpy(result[offset + 14 .. offset + 16], &from_u16(self.speed));

        return result;
    }
};

test "TicketMessage serialization" {
    const msg = TicketMessage{
        .plate = "UN1X",
        .road = 66,
        .mile1 = 100,
        .timestamp1 = 123456,
        .mile2 = 110,
        .timestamp2 = 123816,
        .speed = 10000,
    };
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    const result = try TicketMessage.deserialize(serialized, std.testing.allocator);
    defer std.testing.allocator.free(result.plate);
    try std.testing.expectEqualStrings(msg.plate, result.plate);
    try std.testing.expectEqual(msg.road, result.road);
    try std.testing.expectEqual(msg.mile1, result.mile1);
    try std.testing.expectEqual(msg.timestamp1, result.timestamp1);
    try std.testing.expectEqual(msg.mile2, result.mile2);
    try std.testing.expectEqual(msg.timestamp2, result.timestamp2);
    try std.testing.expectEqual(msg.speed, result.speed);
}

const HeartbeatMessage = struct {
    fn deserialize(bytes: []u8, allocator: Allocator) !HeartbeatMessage {
        _ = allocator;
        if (bytes.len < 1) return error.bytes_too_small;
        if (bytes[0] != '\x41') return error.not_a_heartbeat;
        return HeartbeatMessage{};
    }

    fn serialize(self: HeartbeatMessage, allocator: Allocator) ![]u8 {
        _ = self;
        var result = try allocator.alloc(u8, 1);
        result[0] = '\x41';
        return result;
    }
};

test "HeartbeatMessage serialization" {
    const msg = HeartbeatMessage{};
    const serialized = try msg.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    const result = try HeartbeatMessage.deserialize(serialized);
    _ = result;
}
