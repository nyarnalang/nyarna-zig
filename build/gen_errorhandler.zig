const std = @import("std");
const errors = @import("errors");

pub fn main() !void {
  var eh = try std.fs.cwd().createFile("errors_generated.zig", .{});
  defer eh.close();
  _ = try eh.write(
    \\const std = @import("std");
    \\
    \\const data = @import("data.zig");
    \\const errors = @import("errors.zig");
    \\
    \\pub const Reporter = errors.Reporter;
    \\pub const CmdLineReporter = errors.CmdLineReporter;
    \\
    \\pub const Handler = struct {
    \\  count: usize = 0,
    \\  reporter: *Reporter,
    \\
  );
  inline for (@typeInfo(errors.LexerError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position) void {\n" ++
    \\    self.count = self.count + 1;
    \\    self.reporter.lexerErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.GenericParserError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position) void {\n" ++
    \\    self.count = self.count + 1;
    \\    self.reporter.parserErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.WrongTokenError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position, expected: data.Token, got: data.Token) void {\n" ++
    \\    self.count = self.count + 1;
    \\    self.reporter.wrongTokenErrorFn(self.reporter,
    ++ "." ++ f.name ++ ", pos, expected, got);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.PreviousOccurenceError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), repr: []const u8, pos: data.Position, previous: data.Position) void {\n" ++
    \\    self.count = self.count + 1;
    \\    self.reporter.previousOccurenceFn(self.reporter,
    ++ "." ++ f.name ++ ", repr, pos, previous);\n" ++
    \\  }
    \\
    );
  }
  _ = try eh.write(
    \\};
  );
}