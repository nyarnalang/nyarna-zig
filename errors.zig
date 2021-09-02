const std = @import("std");
const data = @import("data");

pub const LexerError = enum {
  UnknownConfigDirective, MissingClosingParenthesis, InvalidUtf8Encoding,
  IllegalCodePoint, IllegalOpeningParenthesis, IllegalBlocksStartInArgs,
  IllegalCommandChar, MixedIndentation, IllegalIndentation, IllegalContentAtHeader,
  IllegalCharacterForId, InvalidEndCommand, SwallowDepthWithoutDiamondClose,
};

pub const GenericParserError = enum {
  NamedArgumentInAssignment, MissingBlockNameEnd,
};

pub const WrongTokenError = enum {
  ExpectedTokenXGotY
};

pub const WrongIdError = enum {
  WrongCallId, SkippingCallId,

  fn kind(e: WrongIdError) []const u8 {
    return switch (e) {
      .WrongCallId => "wrong",
      .SkippingCallId => "skipping"
    };
  }
};

pub const PreviousOccurenceError = enum {
  IsNotANamespaceCharacter, AlreadyANamespaceCharacter,

  fn errorMsg(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter => " is not a namespace character",
      .AlreadyANamespaceCharacter => " is already a namespace character"
    };
  }

  fn entityName(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "character"
    };
  }

  fn prevOccurenceKind(e: PreviousOccurenceError) []const u8 {
    return switch (e) {
      .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "given"
    };
  }
};

pub const Reporter = struct {
  lexerErrorFn: fn(reporter: *Reporter, id: LexerError, pos: data.Position) void,
  parserErrorFn: fn(reporter: *Reporter, id: GenericParserError, pos: data.Position) void,
  wrongTokenErrorFn: fn(reporter: *Reporter, id: WrongTokenError, pos: data.Position, expected: data.Token, got: data.Token) void,
  wrongIdErrorFn: fn(reporter: *Reporter, id: WrongIdError, pos: data.Position, expected: []const u8, got: []const u8, defined_at: data.Position) void,
  previousOccurenceFn: fn(reporter: *Reporter, id: PreviousOccurenceError, repr: []const u8, pos: data.Position, previous: data.Position) void,
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
        .wrongIdErrorFn = CmdLineReporter.wrongIdError,
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

  fn renderSubPos(self: *CmdLineReporter, pos: data.Position) void {
    switch (pos) {
      .module => |mod| {
        self.writer.print("{s}({}:{}): ", .{mod.name, mod.start.at_line, mod.start.before_column}) catch unreachable;
      },
      .intrinsic => self.writer.print("<intrinsic>: ", .{}) catch unreachable,
      .argument => |arg| self.writer.print("(param {s}): ", .{arg.param_name}) catch unreachable,
      .invokation => self.writer.print("<invokation>: ", .{}) catch unreachable,
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

  fn wrongIdError(reporter: *Reporter, id: WrongIdError, pos: data.Position, expected: []const u8, got: []const u8, defined_at: data.Position) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(pos);
    self.renderError("{s} id: expected '{s}', got '{s}'",
        .{WrongIdError.kind(id), expected, got});
    self.renderSubPos(defined_at);
    _ = self.writer.write("command started here") catch unreachable;
  }

  fn previousOccurence(reporter: *Reporter, id: PreviousOccurenceError, repr: []const u8, pos: data.Position, previous: data.Position) void {
    const self = @fieldParentPtr(CmdLineReporter, "reporter", reporter);
    self.renderPos(pos);
    self.renderError("{s} '{s}'{s}", .{id.entityName(), repr, id.errorMsg()});
    self.renderSubPos(previous);
    self.writer.print("{s} here", .{previous}) catch unreachable;
  }
};