const std = @import("std");
const model = @import("../model/lexing.zig");

pub const LexerError = enum {
  UnknownConfigDirective, MissingClosingParenthesis, InvalidUtf8Encoding,
  IllegalCodePoint, IllegalOpeningParenthesis, IllegalBlocksStartInArgs,
  IllegalCommandChar, MixedIndentation, IllegalIndentation,
  IllegalContentAtHeader, IllegalCharacters, InvalidEndCommand,
  SwallowDepthWithoutDiamondClose, InvalidLocator, IllegalColon, IllegalNameSep,
  AssignmentWithoutExpression, MissingId, IllegalContentAfterId,
};

pub const GenericParserError = enum {
  NamedArgumentInAssignment, MissingBlockNameEnd, NonLocationFlag,
  NonDefinitionFlag, BlockHeaderNotAllowedForDefinition, MissingSymbolName,
  MissingSymbolType, MissingSymbolEntity, PrefixedSymbolMustBeCalled,
  AstNodeInNonKeyword, CannotResolveImmediately, InvalidLvalue, CantBeCalled,
  TooManyArguments, UnexpectedPrimaryBlock, InvalidPositionalArgument,
  BlockNeedsConfig, InvalidNamedArgInAssign, UnfinishedCallInTypeArg, NotAType,
  CantCallUnfinished, FailedToCalculateReturnType, FieldAccessWithoutInstance,
  MethodOutsideDeclare, CannotResolveLocator, ImportIllegalInFullast,
  MissingInitialValue, IllegalNumericInterval, EntityCannotBeNamed,
  SurplusFlags, TypeInMagic, NyFuncInMagic, BuiltinMustBeNamed, NoBlockToEnd,
  ConstructorUnavailable, NoBuiltinProvider, IllegalContentInPrototypeFuncs,
  BlockNameAtTopLevel,
};

pub const WrongItemError = enum {
  pub const ItemDescr = union(enum) {
    token: model.Token,
    character: u21,
    node,

    pub fn format(
      self: ItemDescr,
      comptime _: []const u8,
      options: std.fmt.FormatOptions,
      writer: anytype
    ) @TypeOf(writer).Error!void {
      switch (self) {
        .token => |t| try writer.writeAll(@tagName(t)),
        .character => |c| {
          try writer.writeByte('\'');
          try std.fmt.formatUnicodeCodepoint(c, options, writer);
          try writer.writeByte('\'');
        },
        .node => try writer.writeAll("<node>"),
      }
    }

    pub fn formatAll(
      data: []const ItemDescr,
      comptime specifier: []const u8,
      options: std.fmt.FormatOptions,
      writer: anytype
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
  InvalidDecimals,
};

pub const WrongIdError = enum {
  WrongCallId, SkippingCallId,
};

pub const PreviousOccurenceError = enum {
  IsNotANamespaceCharacter, AlreadyANamespaceCharacter, DuplicateFlag,
  DuplicateBlockHeader, IncompatibleFlag, DuplicateAutoSwallow,
  DuplicateParameterArgument, MissingParameterArgument, DuplicateSymbolName,
  MultipleScalarTypesInIntersection, MissingEndCommand, CannotAssignToConst,
  DuplicateEnumValue, MultipleModuleKinds,
};

pub const PositionChainError = enum {
  /// emitted when types in \declare reference each other in a chain that
  /// cannot be made into a set of types.
  CircularType,
};

pub const WrongTypeError = enum {
   /// gives two types: first expected, then actual type.
   ExpectedExprOfTypeXGotY,
   /// gives two scalar types: first expected, then actual type.
   ScalarTypesMismatch,
   /// gives at least two types: the first type is the one that makes the set
   /// incompatible, the others are other types in the set.
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
   InvalidDefinitionValue,
   /// gives one type.
   CannotBranchOn,
   /// gives one type.
   VarmapRequiresMap,
   /// gives one type.
   VarargsRequiresList,
   /// gives one type.
   BorrowRequiresRef,
};

pub const ConstructionError = enum {
  NotInEnum, OutOfRange, TooManyDecimalsForType,
};

pub const SystemNyError = enum {
  MissingType, MissingPrototype, MissingKeyword, MissingBuiltin,
  ShouldBeType, ShouldBePrototype, ShouldBeKeyword, ShouldBeBuiltin,
  WrongType, UnknownSystemSymbol, MissingConstructor,
};

pub const FileError = enum {
  FailedToOpen, NotAFile, FailedToRead,
};