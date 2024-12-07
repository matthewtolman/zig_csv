const zcsv = @import("zcsv");
const std = @import("std");

const csv =
    \\name,age,id
    \\"John",32,1
    \\"Jane",54,2
    \\"Will",12,3
;

pub fn main() !void {

    // These methods demonstrate how to use the builder
    // to get specific parsers
    // The idea behind the builder is to allow in-code
    // discovery of different parsers

    std.debug.print("Map example\n", .{});
    try runMapExample();

    std.debug.print("\nColumn example\n", .{});
    try runColumnExample();

    std.debug.print("\nRaw Slice example\n", .{});
    try runRawSliceExample();
}

/// This example will use the builder
/// to create a parser that returns fields
/// inside of a hash map
fn runMapExample() !void {
    // Get our allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Get our reader
    var fbs = std.io.fixedBufferStream(csv[0..]);
    const reader = fbs.reader();

    // Get our builder
    const builder = zcsv.ParserBuilder
    //  These calls determine which parser we will use
    //  They are required
        .withReaderInput(@TypeOf(reader))
        .withHeaderRow(alloc)
    //  These calls customize the CSV tokens used for parsing
    //  These are optional and only shown for demonstration purposes
        .withQuote('"')
        .withDelimiter(',');

    var parser = try builder.build(reader);
    defer builder.denitParser(parser); // ensures parser is cleaned up properly

    std.debug.print("id\tname\tage\n-------------------\n", .{});
    while (parser.next()) |row| {
        defer builder.deinitRow(row);

        // Work with the row data
        std.debug.print("{s}\t{s}\t{s}\n", .{
            row.data().get("id").?.data(),
            row.data().get("name").?.data(),
            row.data().get("age").?.data(),
        });
    }
}

/// This example shows how to get a column parser
/// (allocating parser with no header row)
fn runColumnExample() !void {
    // Get our allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Get our reader
    var fbs = std.io.fixedBufferStream(csv[0..]);
    const reader = fbs.reader();

    // Get our builder
    const builder = zcsv.ParserBuilder
    //  These calls determine which parser we will use
    //  They are required
        .withReaderInput(@TypeOf(reader))
        .withNoHeaderRow(alloc)
    //  These calls customize the CSV tokens used for parsing
    //  These are optional and only shown for demonstration purposes
        .withQuote('"')
        .withDelimiter(',');

    var parser = try builder.build(reader);
    defer builder.denitParser(parser); // ensures parser is cleaned up properly

    while (parser.next()) |row| {
        defer builder.deinitRow(row);

        // Work with the row data
        std.debug.print("{s}\t{s}\t{s}\n", .{
            (try row.field(0)).data(),
            (try row.field(1)).data(),
            (try row.field(2)).data(),
        });
    }
}

/// This example shows how to get a fast, raw parser
/// (does not decode fields)
fn runRawSliceExample() !void {
    // Get our builder
    const builder = zcsv.ParserBuilder
    //  These calls determine which parser we will use
    //  They are required
        .withSliceInput()
        .withRawFields()
    //  These calls customize the CSV tokens used for parsing
    //  These are optional and only shown for demonstration purposes
        .withQuote('"')
        .withDelimiter(',');

    var parser = try builder.build(csv[0..]);
    defer builder.denitParser(parser); // ensures parser is cleaned up properly

    while (parser.next()) |row| {
        defer builder.deinitRow(row);

        // Work with the row data
        // Note: this one has "raw" data
        // Use the `zcsv.decode  or the field `decode` method
        // to get the unencoded data (i.e. quotes removed)
        std.debug.print("{s}\t{s}\t{s}\n", .{
            (try row.field(0)).raw(),
            (try row.field(1)).raw(),
            (try row.field(2)).raw(),
        });
    }
}
