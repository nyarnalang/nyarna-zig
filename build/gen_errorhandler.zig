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
    \\    self.reporter.lexerErrorFn(
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.GenericParserError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position) void {\n" ++
    \\    self.count = self.count + 1;
    \\    self.reporter.parserErrorFn(
    ++ "." ++ f.name ++ ", pos);\n" ++
    \\  }
    \\
    );
  }
  inline for (@typeInfo(errors.PreviousOccurenceError).Enum.fields) |f| {
    _ = try eh.write("  pub fn " ++ f.name ++ "(self: *@This(), pos: data.Position, previous: data.Position) void {\n" ++
    \\    self.count = self.count + 1;
    \\    self.reporter.prevousOccurenceFn(
    ++ "." ++ f.name ++ ", pos, previous);\n" ++
    \\  }
    \\
    );
  }
  _ = try eh.write(
    \\};
  );
}