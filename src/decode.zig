const common = @import("common.zig");
const std = @import("std");
const ParseIntError = std.fmt.ParseIntError;
const ParseFloatError = std.fmt.ParseFloatError;
const ParseBoolError = common.ParseBoolError;

pub const sliceIsNull = common.isNull;
pub const sliceToInt = common.asInt;
pub const sliceToFloat = common.asFloat;
pub const sliceToBool = common.asBool;
pub const unquote = common.decode;

/// Parses a field and returns whether or not it is "null"
/// "null" is an empty field or a field with the content "-"
pub fn fieldIsNull(field: anytype) bool {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (comptime std.meta.hasFn(F, "data")) {
        return common.isNull(field.data());
    } else if (comptime std.meta.hasFn(F, "raw")) {
        const unquoted = common.unquoteQuoted(field.raw(), field.opts());
        return common.isNull(unquoted);
    } else {
        unreachable;
    }
}

/// Parses a field and converts it into an int
/// If the field is null (see fieldIsNull), will return null instead
pub fn fieldToInt(comptime T: type, field: anytype, base: u8) ParseIntError!?T {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (fieldIsNull(field)) {
        return null;
    }

    if (comptime std.meta.hasFn(F, "data")) {
        return common.asInt(field.data(), T, base);
    } else if (comptime std.meta.hasFn(F, "raw")) {
        const unquoted = common.unquoteQuoted(field.raw(), field.opts());
        return common.asInt(unquoted, T, base);
    } else {
        unreachable;
    }
}

/// Parses a field and converts it into an bool
/// If the field is null (see fieldIsNull), will return null instead
/// Parsing is case insensitive
/// Truthy values: yes, y, true, t, 1
/// Falsey values: no, n, false, f, 0
pub fn fieldToBool(field: anytype) ParseBoolError!?bool {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (fieldIsNull(field)) {
        return null;
    }

    if (comptime std.meta.hasFn(F, "data")) {
        return common.asBool(field.data());
    } else if (comptime std.meta.hasFn(F, "raw")) {
        const unquoted = common.unquoteQuoted(field.raw(), field.opts());
        return common.asBool(unquoted);
    } else {
        unreachable;
    }
}

/// Parses a field and converts it into a float
/// If the field is null (see fieldIsNull), will return null instead
pub fn fieldToFloat(comptime T: type, field: anytype) ParseFloatError!?T {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (fieldIsNull(field)) {
        return null;
    }

    if (comptime std.meta.hasFn(F, "data")) {
        return common.asFloat(T, field.data());
    } else if (comptime std.meta.hasFn(F, "raw")) {
        const unquoted = common.unquoteQuoted(field.raw(), field.opts());
        return common.asFloat(T, unquoted);
    } else {
        unreachable;
    }
}

/// Indicates if a slice is a raw (unparsed) CSV string or not
pub const StrRes = struct {
    is_raw: bool,
    str: []const u8,
};

/// Get the field as a string/slice
/// Will return whether the slice is raw or not
/// Raw slices happen when zero-allocation is used
/// Parsed (not raw) slices happen when allocation is used
///
/// If the field is "null" (see fieldIsNull), will return null
///
/// For consistent behavior between allocation and zero-allocation,
/// it is recommended to use writeFieldStrTo which will write out the
/// decoded string
pub fn fieldToStr(field: anytype) ?StrRes {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (fieldIsNull(field)) {
        return null;
    }

    if (comptime std.meta.hasFn(F, "data")) {
        return StrRes{
            .is_raw = false,
            .str = field.data(),
        };
    } else if (comptime std.meta.hasFn(F, "raw")) {
        return StrRes{
            .is_raw = true,
            .str = field.raw(),
        };
    } else {
        unreachable;
    }
}

/// Writes the decoded string into a writer
pub fn writeFieldStrTo(field: anytype, writer: anytype) !void {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (comptime std.meta.hasFn(F, "decode")) {
        try field.decode(writer);
    } else if (comptime std.meta.hasFn(F, "data")) {
        try writer.writeAll(field.data());
    } else {
        unreachable;
    }
}

/// Gets the decoded string slice
/// If the string is null, will return fieldIsNull
/// If the field does not support getting the decoded string as a slice,
///     then compilation will fail
pub fn fieldToDecodedStr(field: anytype) ?[]const u8 {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (fieldIsNull(field)) {
        return null;
    }

    if (comptime std.meta.hasFn(F, "data")) {
        return field.data();
    } else {
        // Can only be used with fields that have the "data()" method
        unreachable;
    }
}

/// Gets the raw string slice
/// If the string is null, will return fieldIsNull
/// If the field does not support getting the raw string,
///     then compilation will fail
pub fn fieldToRawStr(field: anytype) ?[]const u8 {
    const F = @TypeOf(field);
    comptime std.debug.assert(isField(F));

    if (fieldIsNull(field)) {
        return null;
    }

    if (comptime std.meta.hasFn(F, "raw")) {
        return field.raw();
    } else {
        // Can only be used with fields that have the "raw()" method
        unreachable;
    }
}

/// Checks if a type is a valid field
fn isField(comptime T: type) bool {
    return T == @import("allocs/column.zig").Field or T == @import("zero_allocs/slice.zig").Field;
}
