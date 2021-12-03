const std = @import("std");
const errors = @import("../errors.zig");

pub fn main() !void {
  var eh = try std.fs.cwd().createFile("errors_generated.zig", .{});
  defer eh.close();
  _ = try eh.write(
    \\const std = @import("std");
    \\
    \\const data = @import("model.zig");
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
      "(self: *@This(), pos: data.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.lexerErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.GenericParserError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++
      "(self: *@This(), pos: data.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.parserErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongItemError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++
    \\(self: *@This(), pos: data.Position, expected: []const WrongItemError.ItemDescr, got: WrongItemError.ItemDescr) void {
    \\    self.count += 1;
    \\    self.reporter.wrongItemErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, expected, got);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.PreviousOccurenceError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), repr: []const u8, pos: data.Position, previous: data.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.previousOccurenceFn(self.reporter,
    ++ "." ++ f.name ++ ", repr, pos, previous);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongIdError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position, expected: []const u8, got: []const u8, defined_at: data.Position) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.wrongIdErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, expected, got, defined_at);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongTypeError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position, types: []data.Type) void {\n" ++
    \\    self.count += 1;
    \\    self.reporter.wrongTypeErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, types);\n" ++
    \\  }
    \\
    );
  }
  _ = try eh.write(
    \\};
  );
}