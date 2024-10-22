const CsvReadError = @import("../common.zig").CsvReadError;
const fields = @import("fields.zig");
const std = @import("std");

/// Iterates over fields in a CSV row
pub const RowIter = struct {
    _field_parser: fields.Parser,

    pub fn next(self: *RowIter) ?fields.Field {
        return self._field_parser.next();
    }
};

/// A CSV row
pub const Row = struct {
    _data: []const u8,

    pub fn iter(self: Row) RowIter {
        return RowIter{
            ._field_parser = fields.init(self._data),
        };
    }
};

/// A CSV row parser
/// Will parse a row twice, once for identifying the row end
/// and once for iterating over fields in a row
pub const Parser = struct {
    _text: []const u8,
    _field_parser: fields.Parser,
    err: ?CsvReadError = null,

    /// Gets the next row in a row
    pub fn next(self: *Parser) ?Row {
        if (self._field_parser.done()) {
            return null;
        }

        const start = self._field_parser.startPos();
        var end = start;
        while (self._field_parser.next()) |f| {
            self.err = self._field_parser.err;
            if (self.err) |_| {
                return null;
            }
            end += f.data.len + 1;
            end = @min(end, self._text.len);
            if (f.row_end) {
                break;
            }
        }
        self.err = self._field_parser.err;

        return Row{
            ._data = self._text[start..end],
        };
    }

    /// Initializes a parser
    pub fn init(text: []const u8) Parser {
        return Parser{
            ._text = text,
            ._field_parser = fields.init(text),
        };
    }
};

/// Initializes a new raw parser
pub fn init(text: []const u8) Parser {
    return Parser.init(text);
}

test "row iterator" {
    const testing = @import("std").testing;

    const tests = [_]struct {
        input: []const u8,
        count: usize,
        err: ?CsvReadError = null,
    }{
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c",
            .count = 3,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\r\n",
            .count = 3,
        },
        .{
            .input = "c1,c2,c3\r\nv1,v2,v3\na,b,c\n",
            .count = 3,
        },
        .{
            .input = "\",,\",",
            .count = 1,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh",
            ,
            .count = 2,
        },
        .{
            .input =
            \\abc,"def",
            \\abc"def""geh",
            ,
            .count = 1,
            .err = CsvReadError.UnexpectedQuote,
        },
        .{
            .input =
            \\abc,"def",
            \\"def"geh",
            ,
            .count = 1,
            .err = CsvReadError.UnexpectedEndOfFile,
        },
        .{
            .input =
            \\abc,"def",
            \\"def""geh,
            ,
            .count = 1,
            .err = CsvReadError.UnexpectedEndOfFile,
        },
        .{
            .input = "abc,serkj\r",
            .count = 1,
            .err = CsvReadError.InvalidLineEnding,
        },
        .{
            .input = "abc,serkj\r1232,232",
            .count = 1,
            .err = CsvReadError.InvalidLineEnding,
        },
    };

    for (tests) |testCase| {
        var iterator = Parser.init(testCase.input);
        var cnt: usize = 0;
        while (iterator.next()) |_| {
            cnt += 1;
        }

        try testing.expectEqual(testCase.err, iterator.err);
        try testing.expectEqual(testCase.count, cnt);
    }
}

test "row and field iterator" {
    const testing = @import("std").testing;

    const input =
        \\userid,name,age
        \\1,"Jonny",23
        \\2,Jack,32
    ;

    const fieldCount = 9;

    var parser = Parser.init(input);
    var cnt: usize = 0;
    while (parser.next()) |row| {
        var iter = row.iter();
        while (iter.next()) |_| {
            cnt += 1;
        }
    }

    try testing.expectEqual(fieldCount, cnt);
}
