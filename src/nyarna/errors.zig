const ids   = @import("errors/ids.zig");
const model = @import("model.zig");

pub usingnamespace ids;

pub const Reporter = @import("errors/Reporter.zig");
pub const Handler  = @import("errors/Handler.zig");

const Style = enum(u8) {
  reset      = 0,
  bold       = 1,
  underline  = 4,
  fg_black   = 30,
  fg_red     = 31,
  fg_green   = 32,
  fg_yellow  = 33,
  fg_blue    = 34,
  fg_magenta = 35,
  fg_cyan    = 36,
  fg_white   = 37,
};

pub fn Terminal(comptime Writer: type, comptime do_style: bool) type {
  return struct {
    reporter: Reporter,
    writer  : Writer,

    pub fn init(writer: Writer) @This() {
      return .{
        .reporter = .{
          .lexerErrorFn        = lexerError,
          .parserErrorFn       = parserError,
          .previousOccurenceFn = previousOccurence,
          .posChainFn          = posChain,
          .wrongItemErrorFn    = wrongItemError,
          .scalarErrorFn       = scalarError,
          .wrongIdErrorFn      = wrongIdError,
          .typeErrorFn         = typeError,
          .constructionErrorFn = constructionError,
          .runtimeErrorFn      = runtimeError,
          .systemNyErrorFn     = systemNyError,
          .fileErrorFn         = fileError,
        },
        .writer = writer,
      };
    }

    fn style(
              self  : *@This(),
              styles: anytype,
      comptime fmt   : []const u8,
              args  : anytype,
    ) void {
      if (do_style) {
        inline for (styles) |s| {
          self.writer.print("\x1b[{}m", .{@enumToInt(@as(Style, s))})
            catch unreachable;
        }
      }
      self.writer.print(fmt, args) catch unreachable;
      if (do_style) self.writer.writeAll("\x1b[m") catch unreachable;
    }

    fn renderError(
              self: *@This(),
      comptime fmt : []const u8,
              args: anytype,
    ) void {
      self.style(.{.bold, .fg_red}, "[error] ", .{});
      self.style(.{.bold}, fmt, args);
      self.writer.writeByte('\n') catch unreachable;
    }

    fn renderInfo(
              self: *@This(),
      comptime fmt : []const u8,
              args: anytype,
    ) void {
      self.style(.{.bold, .fg_white}, "[info] ", .{});
      self.style(.{.bold}, fmt, args);
      self.writer.writeByte('\n') catch unreachable;
    }

    fn lexerError(
      reporter: *Reporter,
      id      : ids.LexerError,
      pos     : model.Position,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      self.renderError("(lex) {s}", .{@tagName(id)});
    }

    fn parserError(
      reporter: *Reporter,
      id      : ids.GenericParserError,
      pos     : model.Position,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      self.renderError("(parse) {s}", .{@tagName(id)});
    }

    fn wrongItemError(
      reporter: *Reporter,
      id      : ids.WrongItemError,
      pos     : model.Position,
      expected: []const ids.WrongItemError.ItemDescr,
      got     : ids.WrongItemError.ItemDescr,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      const arr = ids.WrongItemError.ItemDescr.formatterAll(expected);
      const single = got.formatter();
      switch (id) {
        .ExpectedXGotY => self.renderError(
          "syntax error: expected {?}, got {}", .{arr, single}),
        .MissingToken => {
          const missing = expected[0].formatter();
          self.renderError("inserted missing item: {}", .{missing});
        },
        .PrematureToken => self.renderError(
          "missing token: {?}", .{arr}),
        .IllegalItem => self.renderError(
          "token not allowed here: {} (expected {?})", .{single, arr}),
      }
    }

    fn scalarError(
      reporter: *Reporter,
      id      : ids.ScalarError,
      pos     : model.Position,
      repr    : []const u8,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      const entity: []const u8 = switch (id) {
        .UnknownFlag           => "unknown flag",
        .UnknownSyntax         => "unknown syntax",
        .UnknownParameter      => "unknown parameter",
        .UnknownSymbol         => "unknown symbol",
        .UnknownField          => "unknown field",
        .UnknownResolver       => "unknown resolver",
        .UnknownUnique         => "unknown unique type",
        .UnknownPrototype      => "unknown prototype",
        .UnknownBuiltin        => "unknown builtin",
        .DoesntHaveConstructor => "unknown constructor of unique type",
        .InvalidNumber         => "invalid number",
        .NumberTooLarge        => "numeric literal has too many digits",
        .TooManyDecimals       => "numeric literal has too many decimal digits",
        .InvalidDecimals       => "too many decimals",
        .FactorMustntBeNegative=> "factor must not be negative",
        .MustHaveDefinedSuffix =>
          "must have one of the defined suffixes (given: no or unknown suffix)",
        .UnknownBackend        => "unknown backend",
        .UnknownMergeTarget    => "unknown merge target",
        .UnknownSyntaxToken    => "unknown syntax token",
        .MissingTokenHandler   => "missing handler for token",
      };
      self.renderError("{s}: '{s}'", .{entity, repr});
    }

    fn wrongIdError(
      reporter  : *Reporter,
      id        : ids.WrongIdError,
      pos       : model.Position,
      expected  : []const u8,
      got       : []const u8,
      defined_at: model.Position,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      const kind: []const u8 = switch (id) {
        .WrongCallId => "wrong",
        .SkippingCallId => "skipping"
      };
      self.renderError("{s} id: expected '{s}', got '{s}'", .{kind, expected, got});
      self.writer.print("  {s} command started here\n", .{defined_at})
        catch unreachable;
    }

    fn previousOccurence(
      reporter: *Reporter,
      id      : ids.PreviousOccurenceError,
      repr    : []const u8,
      pos     : model.Position,
      previous: model.Position,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});

      const msg: []const u8 = switch (id) {
        .IsNotANamespaceCharacter   => " is not a namespace character",
        .AlreadyANamespaceCharacter => " is already a namespace character",
        .DuplicateFlag        => " has been seen previously",
        .DuplicateBlockHeader => " can only be given once per definition",
        .IncompatibleFlag     =>  " is incompatible with previously declared flag",
        .DuplicateAutoSwallow =>
          " conflicts with another auto-swallow definition",
        .DuplicateParameterArgument =>
          " has already been given an argument",
        .MissingParameterArgument =>
          " has not been given an argument",
        .DuplicateSymbolName => " hides existing symbol",
        .MissingEndCommand   => " is missing an explicit end",
        .CannotAssignToConst => " is constant and cannot be assigned to",
        .DuplicateEnumValue  => " occurs multiple times",
        .MultipleModuleKinds => " has already been set",
        .DuplicateMappingKey => " has been seen previously",
        .DuplicateSuffix     => " is already a suffix",
        .FactorsTooFarApart  => " is too many magnitudes away",
        .DuplicateBlockVar   => " has been given previously",
        .DuplicateMatchType  => " has been given previously",
        .MergeSubjectsIncompatible => " is not the same kind as the merge target",
      };

      const entity_name: []const u8 = switch (id) {
        .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter => "character",
        .DuplicateFlag, .IncompatibleFlag => "flag",
        .DuplicateBlockHeader => "block header",
        .DuplicateAutoSwallow => "swallow def",
        .DuplicateParameterArgument, .MissingParameterArgument => "parameter",
        .DuplicateSymbolName => "symbol",
        .MissingEndCommand   => "command",
        .CannotAssignToConst => "variable",
        .DuplicateEnumValue  => "enum value",
        .MultipleModuleKinds => "module kind",
        .DuplicateMappingKey => "key",
        .DuplicateSuffix     => "suffix",
        .FactorsTooFarApart  => "factor",
        .DuplicateBlockVar   => "name for variable",
        .DuplicateMatchType  => "type",
        .MergeSubjectsIncompatible => "merge input",
      };

      const prev_kind: []const u8 = switch (id) {
        .IsNotANamespaceCharacter, .AlreadyANamespaceCharacter, .DuplicateFlag,
        .DuplicateBlockHeader, .DuplicateAutoSwallow => "given",
        .IncompatibleFlag => "other flag",
        .DuplicateParameterArgument => "previous argument",
        .MissingParameterArgument => "parameter definition",
        .DuplicateSymbolName => "symbol definition",
        .MissingEndCommand => "here",
        .CannotAssignToConst => "variable definition",
        .DuplicateEnumValue, .DuplicateMappingKey => "first seen",
        .MultipleModuleKinds => "set",
        .DuplicateSuffix     => "suffix defined",
        .FactorsTooFarApart  => "from this factor",
        .DuplicateBlockVar   => "previous definition",
        .DuplicateMatchType  => "here",
        .MergeSubjectsIncompatible => "merge target",
      };

      self.renderError("{s} '{s}'{s}", .{entity_name, repr, msg});
      self.writer.print("  {s} {s} here\n", .{previous, prev_kind})
        catch unreachable;
    }

    fn posChain(
      reporter  : *Reporter,
      id        : ids.PositionChainError,
      pos       : model.Position,
      referenced: []model.Position,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      self.renderError("{s}", .{@tagName(id)});
      for (referenced) |ref| {
        self.writer.print("  {s} referenced here\n", .{ref}) catch unreachable;
      }
    }

    fn typeError(
      reporter: *Reporter,
      id      : ids.TypeError,
      types   : []const model.SpecType,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{types[0].pos});
      const main = types[0].t.formatter();
      switch (id) {
        .ExpectedExprOfTypeXGotY => {
          self.renderError("incompatible type: {}", .{main});
          const spec = types[1].t.formatter();
          self.writer.print(
            "  {s} specified type: {}\n", .{types[1].pos, spec}
          ) catch unreachable;
        },
        .ScalarTypesMismatch => {
          self.renderError("incompatible scalar type: {}", .{main});
          const spec = types[1].t.formatter();
          self.writer.print(
            "  {s} specified scalar type: {}\n", .{types[1].pos, spec}
          ) catch unreachable;
        },
        .IncompatibleTypes => {
          self.renderError("type not compatible with previous types: {}", .{main});
          for (types[1..]) |item| {
            const prev = item.t.formatter();
            self.writer.print(
              "  {s} previous type: {}\n", .{item.pos, prev}
            ) catch unreachable;
          }
        },
        .InvalidInnerConcatType => {
          self.renderError("invalid inner type for Concat: '{}'", .{main});
        },
        .InvalidInnerOptionalType => {
          self.renderError("invalid inner type for Optional: '{}'", .{main});
        },
        .InvalidInnerIntersectionType => {
          self.renderError("invalid inner type for Intersection: '{}'", .{main});
        },
        .InvalidInnerListType => {
          self.renderError("invalid inner type for List: '{}'", .{main});
        },
        .InvalidInnerSequenceType => {
          self.renderError(
            "invalid inner type for Sequence (must be record): '{}'", .{main});
        },
        .InvalidDirectSequenceType => {
          self.renderError("invalid direct type for Sequence: '{}'", .{main});
        },
        .AutoTypeNeedsPrimary => {
          self.renderError(
            "Sequence auto type needs a primary parameter: '{}'", .{main});
        },
        .AutoTypeParamNotOptional => {
          self.renderError(
            "Sequence auto type has non-primary field that is not optional: '{}'",
            .{main});
          const field = types[1].t.formatter();
          self.writer.print(
            "  {s} field defined here with type '{}'\n",
            .{types[1].pos, field}) catch unreachable;
        },
        .InvalidMappingKeyType => {
          self.renderError("cannot use type as mapping key: '{}'", .{main});
        },
        .NonEmptyAfterNonSequentiable => {
          self.renderError("expression would force a sequence", .{});
          const prev = types[1].t.formatter();
          self.writer.print(
            "  {s} previous expression of type '{}' cannot be part of a sequence\n",
            .{types[1].pos, prev}) catch unreachable;
        },
        .InvalidDefinitionValue => {
          self.renderError(
            "given value for symbol definition is a {} " ++
            "which cannot be made into a symbol", .{main});
        },
        .InvalidIfCondType => {
          self.renderError(
            "invalid type for `if` condition (expected optional or bool): '{}'",
            .{main});
        },
        .VarmapRequiresMap => {
          self.renderError("`varmap` requires mapping type, got '{}'", .{main});
        },
        .VarargsRequiresList => {
          self.renderError("`varargs` requires list type, got '{}'", .{main});
        },
        .BorrowRequiresRef => {
          self.renderError(
            "`borrow` requires ref type " ++
            "(callable, concat, list, map, record), got '{}'", .{main});
        },
        .TypesNotDisjoint => {
          self.renderError("type is not disjoint: {}", .{main});
          const prev = types[1].t.formatter();
          self.writer.print(
            "  {s} with type: {}\n", .{types[1].pos, prev}
          ) catch unreachable;
        },
        .MultipleScalarTypes => {
          self.renderError("multiple scalar types: {}", .{main});
          const prev = types[1].t.formatter();
          self.writer.print(
            "  {s} previous scalar type: {}\n", .{types[1].pos, prev}
          ) catch unreachable;
        },
        .InvalidMatchType => {
          self.renderError("invalid match type: {}", .{main});
        },
        .NotCallable => {
          self.renderError("expression of type {} is not callable", .{main});
        },
        .UnfitForMapFunction => {
          self.renderError(
            "expected callable that takes either a single argument or " ++
            "two arguments with the second one taking a Positive value. Got {}",
            .{main});
        },
        .NotIterable => {
          self.renderError("expression of type {} is not iterable", .{main});
        },
        .InvalidEmbed => {
          self.renderError("invalid embedded type (must be Record): {}", .{main});
        },
        .HasNoParameters => {
          self.renderError("this type has no parameters: {}", .{main});
        },
      }
    }

    fn constructionError(
      reporter: *Reporter,
      id      : ids.ConstructionError,
      pos     : model.Position,
      t       : model.Type,
      repr    : []const u8,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      const t_fmt = t.formatter();
      switch (id) {
        .NotInEnum => self.renderError(
          "given value '{s}' is not part of enum {}", .{repr, t_fmt}),
        .OutOfRange => self.renderError(
          "given value '{s}' is outside of the range of type {}", .{repr, t_fmt}),
        .TooManyDecimalsForType => self.renderError(
          "given value '{s}' has too many decimal digits for type {}",
          .{repr, t_fmt}),
        .CharacterNotAllowed => self.renderError(
          "character '{s}' is not allowed in type {}", .{repr, t_fmt}),
        .InvalidFloat => self.renderError(
          "cannot parse as {}: '{s}'", .{t_fmt, repr}),
        .MissingSuffix => self.renderError(
          "'{s}' has no suffix, must have one of the suffixes of type {}",
          .{repr, t_fmt}),
        .UnknownSuffix => self.renderError(
          "'{s}' is not a known suffix for type {}", .{repr, t_fmt}),
        .DecimalsNotRepresentable => self.renderError(
          "decimal digits given in '{s}' are not representable by type {}",
          .{repr, t_fmt}),
      }
    }

    fn runtimeError(
      reporter: *Reporter,
      id      : ids.RuntimeError,
      pos     : model.Position,
      msg     : []const u8,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      switch (id) {
        .IndexError => self.renderError("index error: {s}", .{msg}),
        .NodePrematurelyProcessed =>
          self.renderError(
            "Node of kind {s} is either not a valid definition subject at all or" ++
            " was given without :<fullast>", .{msg}),
      }
    }

    fn systemNyError(
      reporter: *Reporter,
      id      : ids.SystemNyError,
      pos     : model.Position,
      msg     : []const u8,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      self.renderError("(system.ny) {s}: {s}", .{@tagName(id), msg});
    }

    fn fileError(
      reporter: *Reporter,
      id      : ids.FileError,
      pos     : model.Position,
      path    : []const u8,
      message : []const u8,
    ) void {
      const self = @fieldParentPtr(@This(), "reporter", reporter);
      self.style(.{.bold}, "{s}", .{pos});
      switch (id) {
        .FailedToOpen =>
          self.renderError("cannot open {s}: {s}", .{path, message}),
        .NotAFile =>
          self.renderError("{s} is not a file, but a {s}", .{path, message}),
        .FailedToRead =>
          self.renderError(
            "failed to read content of file {s}: {s}", .{path, message}),
      }
    }
  };
}

/// reporter that doesn't do anything.
pub const Ignore = struct {
  reporter: Reporter,

  pub fn init() @This() {
    return .{
      .reporter = .{
        .lexerErrorFn        = lexerError,
        .parserErrorFn       = parserError,
        .previousOccurenceFn = previousOccurence,
        .posChainFn          = posChain,
        .wrongItemErrorFn    = wrongItemError,
        .scalarErrorFn       = scalarError,
        .wrongIdErrorFn      = wrongIdError,
        .typeErrorFn         = typeError,
        .constructionErrorFn = constructionError,
        .runtimeErrorFn      = runtimeError,
        .systemNyErrorFn     = systemNyError,
        .fileErrorFn         = fileError,
      },
    };
  }

  fn lexerError(_: *Reporter, _ : ids.LexerError, _ : model.Position) void {}
  fn parserError(
    _ : *Reporter,
    _ : ids.GenericParserError,
    _ : model.Position,
  ) void {}
  fn wrongItemError(
    _: *Reporter,
    _: ids.WrongItemError,
    _: model.Position,
    _: []const ids.WrongItemError.ItemDescr,
    _: ids.WrongItemError.ItemDescr,
  ) void {}
  fn scalarError(
    _: *Reporter,
    _: ids.ScalarError,
    _: model.Position,
    _: []const u8,
  ) void {}
  fn wrongIdError(
    _: *Reporter,
    _: ids.WrongIdError,
    _: model.Position,
    _: []const u8,
    _: []const u8,
    _: model.Position,
  ) void {}
  fn previousOccurence(
    _: *Reporter,
    _: ids.PreviousOccurenceError,
    _: []const u8,
    _: model.Position,
    _: model.Position,
  ) void {}
  fn posChain(
    _: *Reporter,
    _: ids.PositionChainError,
    _: model.Position,
    _: []model.Position,
  ) void {}
  fn typeError(
    _: *Reporter,
    _: ids.TypeError,
    _: []const model.SpecType,
  ) void {}
  fn constructionError(
    _: *Reporter,
    _: ids.ConstructionError,
    _: model.Position,
    _: model.Type,
    _: []const u8,
  ) void {}
  fn runtimeError(
    _: *Reporter,
    _: ids.RuntimeError,
    _: model.Position,
    _: []const u8,
  ) void {}
  fn systemNyError(
    _: *Reporter,
    _: ids.SystemNyError,
    _: model.Position,
    _: []const u8,
  ) void {}
  fn fileError(
    _: *Reporter,
    _: ids.FileError,
    _: model.Position,
    _: []const u8,
    _: []const u8,
  ) void {}
};