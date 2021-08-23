const std = @import("std");
const data = @import("data");

pub const LexerError = enum {
  unknown_config_directive
};

pub const GenericParserError = enum {
  named_argument_in_assignment, missing_block_name_end
};

pub const WrongTokenError = enum {
  expected_token_x_got_y
};

pub const PreviousOccurenceError = enum {
  baz
};

pub const Reporter = struct {
  lexerErrorFn: fn(reporter: *Reporter, id: LexerError, pos: data.Position) void,
  parserErrorFn: fn(reporter: *Reporter, id: GenericParserError, pos: data.Position) void,
  wrongTokenErrorFn: fn(reporter: *Reporter, id: WrongTokenError, pos: data.Position, expected: data.Token, got: data.Token) void,
  previousOccurenceFn: fn(reporter: *Reporter, id: PreviousOccurenceError, pos: data.Position, previous: data.Position) void,
};

pub const CmdLineReporter = struct {
  const Style = enum(u8) {
    reset = 0,
    bold = 1,
    underline = 4,
    fg_black = 30,
    fg_red = 31,
    fg_green = 32,
    fg_yellow = 33,
    fg_blue = 34,
    fg_magenta = 35,
    fg_cyan = 36,
    fg_white = 37,
  };

  reporter: Reporter,
  writer: std.fs.File.Writer,
  do_style: bool,

  pub fn init() CmdLineReporter {
    var stdout = std.io.getStdOut();
    return .{
      .reporter = .{
        .lexerErrorFn = CmdLineReporter.lexerError,
        .parserErrorFn = CmdLineReporter.parserError,
        .previousOccurenceFn = CmdLineReporter.previousOccurence,
        .wrongTokenErrorFn = CmdLineReporter.wrongTokenError,
      },
      .writer = stdout.writer(),
      .do_style = std.os.isatty(stdout.handle),
    };
  }

  fn style(self: *CmdLineReporter, styles: anytype, comptime fmt: []const u8, args: anytype) void {
    if (self.do_style) {
      inline for (styles) |s| {
        self.writer.print("\x1b[{}m", .{@enumToInt(@as(Style, s))}) catch unreachable;
      }
    }
    self.writer.print(fmt, args) catch unreachable;
    if (self.do_style) self.writer.writeAll("\x1b[m") catch unreachable;
  }

  fn renderPos(self: *CmdLineReporter, pos: data.Position) void {
    switch (pos) {
      .module => |mod| {
        self.style(.{.bold}, "{s}({}:{}): ", .{mod.name, mod.start.at_line, mod.start.before_column});
      },
      .intrinsic => self.style(.{.bold}, "<intrinsic>: ", .{}),
      .argument => |arg| self.style(.{.bold}, "(param {s}): ", .{arg.param_name}),
      .invokation => self.style(.{.bold}, "<invokation>: ", .{}),
    }
  }

  fn renderError(self: *CmdLineReporter, comptime fmt: []const u8, args: anytype) void {
    self.style(.{.bold, .fg_red}, "[error] ", .{});
    self.style(.{.bold}, fmt, args);
    self.writer.writeByte('\n') catch unreachable;
  }

  fn renderInfo(self: *CmdLineReporter, comptime fmt: []const u8, args: anytype) void {
    self.style(.{.bold, .fg_white}, "[info] ", .{});
    self.style(.{.bold}, fmt, args);
    self.writer.writeByte('\n') catch unreachable;
  }

  fn lexerError(reporter: *Reporter, id: LexerError, pos: data.Position) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(pos);
    self.renderError("(lex) {s}", .{@tagName(id)});
  }

  fn parserError(reporter: *Reporter, id: GenericParserError, pos: data.Position) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(pos);
    self.renderError("(parse) {s}", .{@tagName(id)});
  }

  fn wrongTokenError(reporter: *Reporter, id: WrongTokenError, pos: data.Position, expected: data.Token, got: data.Token) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(pos);
    self.renderError("wrong token: expected {s}, got {s}", .{@tagName(expected), @tagName(got)});
  }

  fn previousOccurence(reporter: *Reporter, id: PreviousOccurenceError, pos: data.Position, previous: data.Position) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(pos);
    self.renderError("duplicate symbol name", .{});
    self.renderPos(previous);
    self.renderInfo("previous occurrence here", .{});
  }
};