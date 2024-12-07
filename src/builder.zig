const CsvOpts = @import("common.zig").CsvOpts;
const allocs = @import("allocs.zig");
const zero_allocs = @import("zero_allocs.zig");
const std = @import("std");

/// Initializer for allocating parsers
fn ErrAllocsInitializer(
    comptime P: type,
    comptime I: type,
    comptime Error: type,
) type {
    return struct {
        pub const Parser = P;
        pub const Input = I;
        pub const InitFn = *const fn (
            a: std.mem.Allocator,
            i: Input,
            o: CsvOpts,
        ) Error!Parser;
        _alloc: std.mem.Allocator,
        _initFn: InitFn,

        pub fn init(initFn: InitFn, alloc: std.mem.Allocator) @This() {
            return .{
                ._alloc = alloc,
                ._initFn = initFn,
            };
        }

        pub fn create(self: @This(), i: Input, o: CsvOpts) Error!Parser {
            return try self._initFn(self._alloc, i, o);
        }
    };
}

/// Initializer for allocating parsers
fn AllocsInitializer(comptime P: type, comptime I: type) type {
    return struct {
        pub const Parser = P;
        pub const Input = I;
        pub const InitFn = *const fn (
            a: std.mem.Allocator,
            i: Input,
            o: CsvOpts,
        ) Parser;
        _alloc: std.mem.Allocator,
        _initFn: InitFn,

        pub fn init(initFn: InitFn, alloc: std.mem.Allocator) @This() {
            return .{
                ._alloc = alloc,
                ._initFn = initFn,
            };
        }

        pub fn create(self: @This(), i: Input, o: CsvOpts) !Parser {
            return self._initFn(self._alloc, i, o);
        }
    };
}

/// Initializer for zero-allocation parsers
fn ZeroAllocsInitializer(comptime P: type, comptime I: type) type {
    return struct {
        pub const Parser = P;
        pub const Input = I;
        pub const InitFn = *const fn (i: Input, o: CsvOpts) Parser;
        _initFn: InitFn,

        pub fn init(initFn: InitFn) @This() {
            return .{
                ._initFn = initFn,
            };
        }

        pub fn create(self: @This(), i: Input, o: CsvOpts) !Parser {
            return self._initFn(i, o);
        }
    };
}

/// Last step of CSV builder
fn OptsBuilder(comptime Init: type) type {
    return struct {
        pub const Parser = Init.Parser;
        pub const Input = Init.Input;
        pub const Initializer = Init;
        _init: Initializer,
        _delim: u8 = ',',
        _line_end_pre: ?u8 = '\r',
        _line_end: u8 = '\n',
        _quote: u8 = '"',
        _max_iter: usize = 65_536,

        /// Creates a new options builder
        pub fn init(initializer: Initializer) @This() {
            return .{ ._init = initializer };
        }

        /// Gets a version of the builder with a specific delimiter
        pub fn withDelimiter(self: @This(), delim: u8) @This() {
            var cpy = self;
            cpy._delim = delim;
            return cpy;
        }

        /// Gets a version of the builder with a specific line ending
        pub fn withLineEnd(self: @This(), line_end: u8) @This() {
            var cpy = self;
            cpy._line_end = line_end;
            return cpy;
        }

        /// Gets a version of the builder with a specific line ending prefix
        pub fn withLineEndPrefix(self: @This(), prefix: ?u8) @This() {
            var cpy = self;
            cpy._line_end_pre = prefix;
            return cpy;
        }

        /// Gets a version of the builder with a specific quote
        pub fn withQuote(self: @This(), quote: u8) @This() {
            var cpy = self;
            cpy._quote = quote;
            return cpy;
        }

        /// Gets a version of the builder with a max iteration count
        pub fn withMaxIter(self: @This(), max: usize) @This() {
            var cpy = self;
            cpy._max_iter = max;
            return cpy;
        }

        /// Builds the CSV parser with the given inputs
        pub fn build(self: @This(), input: Input) !Parser {
            const opts = CsvOpts{
                .max_iter = self._max_iter,
                .column_delim = self._delim,
                .column_quote = self._quote,
                .column_line_end = self._line_end,
                .column_line_end_prefix = self._line_end_pre,
            };
            return try self._init.create(input, opts);
        }

        pub fn denitParser(_: @This(), parser: Parser) void {
            if (comptime std.meta.hasFn(Parser, "deinit")) {
                parser.deinit();
            }
        }

        pub fn deinitRow(_: @This(), row: Parser.Rows) void {
            if (comptime std.meta.hasFn(Parser.Rows, "deinit")) {
                row.deinit();
            }
        }
    };
}

/// Options for map parser
fn OptsForMap(comptime Input: type) type {
    const Parser = allocs.map.Parser(Input);
    return OptsBuilder(ErrAllocsInitializer(Parser, Input, Parser.InitError));
}

/// Options for column parser
fn OptsForColumn(comptime Input: type) type {
    return OptsBuilder(AllocsInitializer(allocs.column.Parser(Input), Input));
}

/// Options for raw slice parser
fn OptsForSliceRaw() type {
    return OptsBuilder(ZeroAllocsInitializer(zero_allocs.slice.Parser, []const u8));
}

/// Builder for Reader inputs
fn ReaderBuilder(comptime Reader: type) type {
    return struct {
        pub const Input = Reader;

        /// Returns a builder for a CSV parser that handles CSVs with header row
        /// This parser does allocate memory for unquoted field data
        /// That way you don't have to unquote fields
        pub fn withHeaderRow(
            _: @This(),
            allocator: std.mem.Allocator,
        ) OptsForMap(Input) {
            const Res = OptsForMap(Input);
            return Res.init(Res.Initializer.init(&Res.Parser.init, allocator));
        }

        /// Returns a builder for a CSV parser that handles CSVs with no header row
        /// This parser does allocate memory for unquoted field data
        /// That way you don't have to unquote fields
        pub fn withNoHeaderRow(
            _: @This(),
            allocator: std.mem.Allocator,
        ) OptsForColumn(Input) {
            const Res = OptsForColumn(Input);
            return Res.init(Res.Initializer.init(&Res.Parser.init, allocator));
        }

        /// Creates a new builder
        pub fn init() @This() {
            return .{};
        }
    };
}

/// Builder for raw slice inputs
const SliceBuilder = struct {
    /// Gets a parser which will return slices to raw fields that are parsed
    /// This allows the parser to be faster by doing less memory allocations
    /// However, it does require for you, the developer, to decode the
    /// raw values. See `zcsv.decode` for helper functions
    pub fn withRawFields(_: @This()) OptsForSliceRaw() {
        const Res = OptsForSliceRaw();
        return Res.init(Res.Initializer.init(&Res.Parser.init));
    }
};

/// Builder for creating CSV parsers
/// Note: This does not provide an exhaustive list of parsers
///       Instead, the focus is on abstracting parsers that are used in similar
///       (though not identical) ways, such as column, row, and slice
///
///       Parsers that are more niche or require vastly different usage
///       semantics (such as stream) are not present in the Builder.
///       The parsers that are present tend to be the onese that are used
///       a majority of the time. The parsers not present are rarely
///       used directly, and when they need to be used it should be obvious
///       that none of the other parsers will work for that scenario.
///
///       If it's not obvious which  parser to use, then use one of the parsers
///       provided by this builder.
pub const Builder = struct {
    /// Gets a builder for parsers which use reader inputs
    /// Note: you can wrap a slice with std.io.fixedBufferStream
    ///       and then pass the `.reader()` from that wrapper to this method
    pub fn withReaderInput(comptime Reader: type) ReaderBuilder(Reader) {
        return ReaderBuilder(Reader).init();
    }

    /// Gets a bulider for parsers that work on slices
    /// Note: alternatively, you can wrap a slice with std.io.fixedBufferStream
    ///       and then pass the `.reader()` from that wrapper to
    ///       `withReaderInput` instead
    pub fn withSliceInput() SliceBuilder {
        return .{};
    }
};
