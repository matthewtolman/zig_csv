/// Represents an error when writing CSV data
pub const CsvWriteError = error{
    CharacterNotWrittern,
    InvalidValueType,
};

/// Represents an error when reading CSV data
pub const CsvReadError = error{
    InternalLimitReached,
    UnexpectedEndOfFile,
    InvalidLineEnding,
    QuotePrematurelyTerminated,
    UnexpectedQuote,
};
