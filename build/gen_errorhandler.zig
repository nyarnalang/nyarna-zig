const std = @import("std");
const errors = @import("../src/errors.zig");

pub fn main() !void {
  var eh = try std.fs.cwd().createFile("src/errors_generated.zig", .{});
  defer eh.close();
  try eh.writeAll(
    \\const std = @import("std");
    \\
    \\const model = @import("model.zig");
    \\const errors = @import("errors.zig");
    \\pub usingnamespace errors;
    \\
    \\pub const Handler = struct {
    \\  const WrongItemError = errors.WrongItemError;
    \\
    \\  count: usize = 0,
    \\  reporter: *errors.Reporter,
    \\
  );
  inline for (@typeInfo(errors.LexerError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: model.Position) void {
    \\    self.count += 1;
    \\    self.reporter.lexerErrorFn(self.reporter, .
    ++ f.name ++ \\, pos);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.GenericParserError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: model.Position) void {
    \\    self.count += 1;
    \\    self.reporter.parserErrorFn(self.reporter, .
    ++ f.name ++ \\, pos);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongItemError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
      \\(
    \\    self: *@This(),
    \\    pos: model.Position,
    \\    expected: []const WrongItemError.ItemDescr,
    \\    got: WrongItemError.ItemDescr,
    \\  ) void {
    \\    self.count += 1;
    \\    self.reporter.wrongItemErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, expected, got);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.UnknownError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: model.Position, name: []const u8) void {
    \\    self.count += 1;
    \\    self.reporter.unknownErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, name);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.PreviousOccurenceError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
      \\(
    \\    self: *@This(),
    \\    repr: []const u8,
    \\    pos: model.Position,
    \\    previous: model.Position,
    \\  ) void {
    \\    self.count += 1;
    \\    self.reporter.previousOccurenceFn(self.reporter, .
    ++ f.name ++ \\, repr, pos, previous);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.PositionChainError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: model.Position, referenced: []model.Position) void {
    \\    self.count += 1;
    \\    self.reporter.posChainFn(self.reporter, .
    ++ f.name ++ \\, pos, referenced);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongIdError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
      \\(
    \\    self: *@This(),
    \\    pos: model.Position,
    \\    expected: []const u8,
    \\    got: []const u8,
    \\    defined_at: model.Position,
    \\  ) void {
    \\    self.count += 1;
    \\    self.reporter.wrongIdErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, expected, got, defined_at);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongTypeError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: model.Position, types: []model.Type) void {
    \\    self.count += 1;
    \\    self.reporter.wrongTypeErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, types);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.ConstructionError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
      \\(
    \\    self: *@This(),
    \\    pos: model.Position,
    \\    t: model.Type,
    \\    repr: []const u8,
    \\  ) void {
    \\    self.count += 1;
    \\    self.reporter.constructionErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, t, repr);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.SystemNyError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
      \\(
    \\    self: *@This(),
    \\    pos: model.Position,
    \\    msg: []const u8,
    \\  ) void {
    \\    self.count += 1;
    \\    self.reporter.systemNyErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, msg);
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.FileError).Enum.fields) |f| {
    try eh.writeAll("  pub fn " ++ f.name ++
      \\(
    \\    self: *@This(),
    \\    pos: model.Position,
    \\    path: []const u8,
    \\    message: []const u8,
    \\  ) void {
    \\    self.count += 1;
    \\    self.reporter.fileErrorFn(self.reporter, .
    ++ f.name ++ \\, pos, path, message);
    \\  }
    \\
    );
  }
  try eh.writeAll(
    \\};
  );
}