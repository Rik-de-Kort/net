const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // Find address information for a local socket, then connect?
    const allocator = std.heap.page_allocator;

    const addressList = try std.net.getAddressList(allocator, "localhost", 3491);
    defer addressList.deinit();
    std.debug.print("Got addressList, {any}!\n", .{addressList.addrs});

    const myAddress = addressList.addrs[1];
    const mySocket = try posix.socket(myAddress.in.sa.family, posix.SOCK.STREAM, 0);
    defer posix.close(mySocket);

    std.debug.print("Got socket, {any}!\n", .{mySocket});
    try posix.bind(mySocket, &myAddress.any, myAddress.getOsSockLen());
    std.debug.print("Bound!\n", .{});
    try posix.connect(mySocket, &myAddress.any, myAddress.getOsSockLen());
    std.debug.print("Connected! {any} {any}\n", .{ mySocket, 10 });
    try posix.listen(mySocket, 0);
    std.debug.print("Listening...\n", .{});
    var remoteAddress: std.net.Address = undefined;
    const connectionSocket = try posix.accept(mySocket, &remoteAddress.any, null, 0);
    std.debug.print("Got request from {any} with socket {any}!\n", .{ remoteAddress, connectionSocket });

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
