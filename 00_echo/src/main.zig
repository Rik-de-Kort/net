const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const addressList = try std.net.getAddressList(allocator, "0.0.0.0", 3491);
    defer addressList.deinit();
    std.debug.print("Got addressList, {any}!\n", .{addressList.addrs});

    const myAddress = addressList.addrs[0];
    const mySocket = try posix.socket(myAddress.in.sa.family, posix.SOCK.STREAM, 0);
    defer posix.close(mySocket);

    try posix.setsockopt(mySocket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    std.debug.print("Got socket, {any}!\n", .{mySocket});
    try posix.bind(mySocket, &myAddress.any, myAddress.getOsSockLen());
    std.debug.print("Bound!\n", .{});
    // try posix.connect(mySocket, &myAddress.any, myAddress.getOsSockLen());
    std.debug.print("Connected! {any} {any}\n", .{ mySocket, 10 });
    try posix.listen(mySocket, 5);
    std.debug.print("Listening...\n", .{});

    while (true) {
        var remoteAddress: std.net.Address = undefined;
        var addressSize = myAddress.getOsSockLen();
        const connectionSocket = try posix.accept(mySocket, &remoteAddress.any, &addressSize, 0);
        defer posix.close(connectionSocket);
        std.debug.print("Got request from {any} with socket {any}!\n", .{ remoteAddress, connectionSocket });

        var data = std.ArrayList(u8).init(allocator);
        defer data.deinit();
        var smallBuf: [1024]u8 = undefined;
        while (true) {
            const nBytesReceived = try posix.recv(connectionSocket, &smallBuf, 0);
            if (nBytesReceived <= 0) {
                break;
            }
            std.debug.print("Got {any} bytes: {s}\n", .{ nBytesReceived, smallBuf });

            try data.appendSlice(smallBuf[0..nBytesReceived]);
            if (smallBuf[nBytesReceived - 1] < 0) { // EOF
                break;
            }
        }
        var bytesSent: usize = 0;
        while (bytesSent < data.items.len) {
            bytesSent += try posix.send(connectionSocket, data.items[bytesSent..data.items.len], 0);
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
