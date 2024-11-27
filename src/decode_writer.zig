const std = @import("std");
const common = @import("common.zig");

/// Decodes CSV values and writes the decoded values to an underlying stream
/// Operates on a stream basis to avoid internal buffering
/// Meant for internal use
pub fn DecodeWriter(comptime UnderlyingWriter: type) type {
    const AppendErr = UnderlyingWriter.Error;
    return struct {
        pub const Writer = std.io.Writer(
            *@This(),
            AppendErr,
            @This().append,
        );
        pub const Error = AppendErr;
        _writer: UnderlyingWriter,
        _start: bool = true,
        _last_was_quote: bool = false,
        _quoted: bool = false,
        _opts: common.CsvOpts = .{},

        /// Marks the end of a field so it can reset internal state
        pub fn fieldEnd(self: *DecodeWriter(UnderlyingWriter)) void {
            // Make sure we didn't end up in an invalid state
            if (self._quoted) {
                // If it's a quoted string, we should end on an "odd" quote
                // (the ending quote)
                std.debug.assert(self._last_was_quote);
                // we also shouldn't be at the start
                std.debug.assert(!self._start);
            }
            self._start = true;
            self._last_was_quote = false;
            self._quoted = false;
        }

        /// Appends CSV data to a writer
        /// Will decode as data is being appended
        fn append(
            self: *DecodeWriter(UnderlyingWriter),
            data: []const u8,
        ) AppendErr!usize {
            const quote = self._opts.column_quote;
            if (self._start and data.len > 0 and data[0] == quote) {
                self._quoted = true;
            }

            // If we're writing a quoted string, then we need to write it
            // character by character
            if (self._quoted) {
                for (data) |datum| {
                    defer self._start = false;
                    if (datum == quote) {
                        // Make sure we started with a quote
                        std.debug.assert(self._quoted);
                        if (self._start) {
                            std.debug.assert(!self._last_was_quote);
                            // Keep track that we started with a quote
                            continue;
                        } else if (!self._last_was_quote) {
                            self._last_was_quote = true;
                            continue;
                        } else {
                            self._last_was_quote = false;
                        }
                    }

                    std.debug.assert(!self._last_was_quote);
                    std.debug.assert(!self._start or datum != quote);
                    try self._writer.writeByte(datum);
                }
            } else {
                // If we aren't a quoted string, we can take a shortcut
                // But let's also check that the shortcut is valid
                const quoted = [_]u8{self._opts.column_quote};
                std.debug.assert(std.mem.indexOf(u8, data, quoted[0..]) == null);
                try self._writer.writeAll(data);
            }

            // Report that we wrote everything
            return data.len;
        }

        pub fn writer(self: *DecodeWriter(UnderlyingWriter)) Writer {
            return .{ .context = self };
        }

        pub fn init(underlying: UnderlyingWriter, opts: common.CsvOpts) DecodeWriter(UnderlyingWriter) {
            return .{ ._writer = underlying, ._opts = opts };
        }
    };
}

/// Creates a new CSV decode writer
pub fn init(writer: anytype, opts: common.CsvOpts) DecodeWriter(@TypeOf(writer)) {
    return DecodeWriter(@TypeOf(writer)).init(writer, opts);
}

test "with fixed buffer" {
    var buff: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buff);

    var decoder = init(fbs.writer(), .{});
    try decoder.writer().writeAll("\"hello \"\"world\"\"\"");
    try std.testing.expectEqualStrings("hello \"world\"", fbs.getWritten());
    decoder.fieldEnd();

    try decoder.writer().writeAll("\"hello\"");
    try std.testing.expectEqualStrings("hello \"world\"hello", fbs.getWritten());
    decoder.fieldEnd();

    try decoder.writer().writeAll("hi");
    try std.testing.expectEqualStrings("hello \"world\"hellohi", fbs.getWritten());
    decoder.fieldEnd();

    fbs.reset();
    try decoder.writer().writeAll("\"\"");
    try std.testing.expectEqualStrings("", fbs.getWritten());
    decoder.fieldEnd();

    try decoder.writer().writeAll("");
    try std.testing.expectEqualStrings("", fbs.getWritten());
    decoder.fieldEnd();

    fbs.reset();
    try decoder.writer().writeAll("012345678901234567890123456789");
    try decoder.writer().writeAll("012345678901234567890123456789");
    try std.testing.expectEqualStrings("012345678901234567890123456789012345678901234567890123456789", fbs.getWritten());
    decoder.fieldEnd();
}
