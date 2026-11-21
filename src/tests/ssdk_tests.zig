const std = @import("std");
const CCommand = @import("zroot").ssdk.ClientCommand;

test "CCommand matches the Source SDK binary layout" {
    try std.testing.expectEqual(@as(usize, 1544), @sizeOf(CCommand));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CCommand, "m_nArgc"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CCommand, "m_nArgv0Size"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CCommand, "m_pArgSBuffer"));
    try std.testing.expectEqual(@as(usize, 520), @offsetOf(CCommand, "m_pArgvBuffer"));
    try std.testing.expectEqual(@as(usize, 1032), @offsetOf(CCommand, "m_ppArgv"));
}

test "CCommand.commandText reads the NUL-terminated command line" {
    var command = std.mem.zeroes(CCommand);
    command.m_nArgc = 2;
    const text = "zlua ping";
    @memcpy(command.m_pArgSBuffer[0..text.len], text);

    try std.testing.expectEqualStrings(text, command.commandText().?);

    command.m_nArgc = 0;
    try std.testing.expect(command.commandText() == null);
}
