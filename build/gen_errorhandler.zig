const std = @import("std");
const errors = @import("../errors.zig");

pub fn main() !void {
  var eh = try std.fs.cwd().createFile("errors_generated.zig", .{});
  defer eh.close();
  _ = try eh.write(
    \\const std = @import("std");
    \\
    \\const model = @import("model.zig");
    \\const errors = @import("errors.zig");
    \\pub usingnamespace errors;
    \\
    \\pub const Handler = struct {
    \\  const Reporter = errors.Reporter;
    \\  const WrongItemError = errors.WrongItemError;
    \\
    \\  count: usize = 0,
    \\  reporter: *Reporter,
    \\
  );
  inline for (@typeInfo(errors.LexerError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++
      "(self: *@This(), pos: model.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.lexerErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.GenericParserError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++
      "(self: *@This(), pos: model.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.parserErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongItemError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: model.Position, expected: []const WrongItemError.ItemDescr, got: WrongItemError.ItemDescr) void {
    \\    self.count += 1;
    \\    self.reporter.wrongItemErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, expected, got);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.PreviousOccurenceError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), repr: []const u8, pos: model.Position, previous: model.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.previousOccurenceFn(self.reporter,
    ++ "." ++ f.name ++ ", repr, pos, previous);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongIdError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: model.Position, expected: []const u8, got: []const u8, defined_at: model.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.wrongIdErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, expected, got, defined_at);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongTypeError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: model.Position, types: []model.Type) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.wrongTypeErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, types);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.ConstructionError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: model.Position, t: model.Type) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.constructionErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, t);\n" ++
    \\  }
    \\
    );
  }
  _ = try eh.write(
    \\};
  );
}