const std = @import("std");

const model = @import("../model/lexing.zig");

pub const LexerError = enum {
  UnknownConfigDirective, MissingClosingParenthesis, InvalidUtf8Encoding,
  IllegalCodePoint, IllegalOpeningParenthesis, IllegalBlocksStartInArgs,
  IllegalCommandChar, MixedIndentation, IllegalIndentation,
  IllegalContentAtHeader, IllegalCharacters, InvalidEndCommand,
  SwallowDepthWithoutDiamondClose, InvalidLocator, IllegalColon, IllegalNameSep,
  AssignmentWithoutExpression, MissingId, IllegalContentAfterId,
  MissingColon,
};

pub const GenericParserError = enum {
  NamedArgumentInAssignment, MissingBlockNameEnd, NonLocationFlag,
  NonDefinitionFlag, BlockHeaderNotAllowedForDefinition, MissingSymbolName,
  MissingSymbolType, MissingSymbolEntity, PrefixedSymbolMustBeCalled,
  AstNodeInNonKeyword, CannotResolveImmediately, InvalidLvalue, CantBeCalled,
  TooManyArguments, UnexpectedPrimaryBlock, InvalidPositionalArgument,
  BlockNeedsConfig, InvalidNamedArg, UnfinishedCallInTypeArg, NotAType,
  CantCallUnfinished, FailedToCalculateReturnType, FieldAccessWithoutInstance,
  MethodOutsideDeclare, CannotResolveLocator, ImportIllegalInFullast,
  MissingInitialValue, IllegalNumericInterval, EntityCannotBeNamed,
  SurplusFlags, TypeInMagic, NyFuncInMagic, BuiltinMustBeNamed, NoBlockToEnd,
  ConstructorUnavailable, NoBuiltinProvider, IllegalContentInPrototypeFuncs,
  BlockNameAtTopLevel, KeywordMustBeCalled, NotAllowedForOption,
  CannotCallLibraryImport, UnexpectedBlockNameExpr,
};

pub const WrongItemError = enum {
  pub const ItemDescr = union(enum) {
    token: model.Token,
    character: u21,
    node,

    pub fn format(
               self   : ItemDescr,
      comptime _      : []const u8,
               options: std.fmt.FormatOptions,
               writer : anytype,
    ) @TypeOf(writer).Error!void {
      switch (self) {
        .token     => |t| try writer.writeAll(@tagName(t)),
        .character => |c| {
          try writer.writeByte('\'');
          try std.fmt.formatUnicodeCodepoint(c, options, writer);
          try writer.writeByte('\'');
        },
        .node => try writer.writeAll("<node>"),
      }
    }

    pub fn formatAll(
               data     : []const ItemDescr,
      comptime specifier: []const u8,
               options  : std.fmt.FormatOptions,
               writer   : anytype,
    ) @TypeOf(writer).Error!void {
      if ((comptime std.mem.eql(u8, specifier, "?")) and data.len == 1) {
        try data[0].format("", options, writer);
      } else {
        for (data) |cur, index| {
          try if (index == 0) writer.writeByte('{')
          else writer.writeAll(", ");
          try cur.format(specifier, options, writer);
        }
        try writer.writeByte('}');
      }
    }

    pub fn formatter(self: ItemDescr) std.fmt.Formatter(format) {
      return .{.data = self};
    }

    pub fn formatterAll(data: []const ItemDescr) std.fmt.Formatter(formatAll) {
      return .{.data = data};
    }
  };

  ExpectedXGotY, MissingToken, PrematureToken, IllegalItem,
};

pub const ScalarError = enum {
  UnknownFlag, UnknownSyntax, UnknownParameter, UnknownSymbol, UnknownField,
  UnknownResolver, UnknownUnique, UnknownPrototype, UnknownBuiltin,
  DoesntHaveConstructor, InvalidNumber, NumberTooLarge, TooManyDecimals,
  FactorMustntBeNegative, MustHaveDefinedSuffix, InvalidDecimals,
};

pub const WrongIdError = enum {
  WrongCallId, SkippingCallId,
};

pub const PreviousOccurenceError = enum {
  IsNotANamespaceCharacter, AlreadyANamespaceCharacter, DuplicateFlag,
  DuplicateBlockHeader, IncompatibleFlag, DuplicateAutoSwallow,
  DuplicateParameterArgument, MissingParameterArgument, DuplicateSymbolName,
  MissingEndCommand, CannotAssignToConst, DuplicateEnumValue,
  MultipleModuleKinds, DuplicateMappingKey, DuplicateSuffix,
  FactorsTooFarApart,
};

pub const PositionChainError = enum {
  /// emitted when types in \declare reference each other in a chain that
  /// cannot be made into a set of types.
  CircularType,
};

pub const TypeError = enum {
   /// gives two types: first actual, then expected type.
   ExpectedExprOfTypeXGotY,
   /// gives two scalar types: first actual, then expected type.
   ScalarTypesMismatch,
   /// gives two types: first the current, then the previous type.
   IncompatibleTypes,
   /// gives one type.
   InvalidInnerConcatType,
   /// gives one type.
   InvalidInnerOptionalType,
   /// gives one type.
   InvalidInnerIntersectionType,
   /// gives one type.
   InvalidInnerListType,
   /// gives one type.
   InvalidInnerSequenceType,
   /// gives one type.
   InvalidDirectSequenceType,
   /// gives one type.
   InvalidMappingKeyType,
   /// gives two types: first the one currently given, then the previous one.
   NonEmptyAfterNonSequentiable,
   /// gives one type.
   InvalidDefinitionValue,
   /// gives one type.
   CannotBranchOn,
   /// gives one type.
   VarmapRequiresMap,
   /// gives one type.
   VarargsRequiresList,
   /// gives one type.
   BorrowRequiresRef,
   /// gives two types: first the one currently given, then the previous one.
   TypesNotDisjoint,
   /// gives two types: first the one currently given, then the previous one.
   MultipleScalarTypes,
};

pub const ConstructionError = enum {
  NotInEnum, OutOfRange, TooManyDecimalsForType, CharacterNotAllowed,
  InvalidFloat, MissingSuffix, UnknownSuffix, DecimalsNotRepresentable,
};

pub const RuntimeError = enum {
  IndexError
};

pub const SystemNyError = enum {
  MissingType, MissingPrototype, MissingKeyword, MissingBuiltin,
  ShouldBeType, ShouldBePrototype, ShouldBeKeyword, ShouldBeBuiltin,
  WrongType, UnknownSystemSymbol, MissingConstructor, WrongNumberOfEnumValues,
};

pub const FileError = enum {
  FailedToOpen, NotAFile, FailedToRead,
};