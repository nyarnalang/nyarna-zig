const std = @import("std");
const types = @import("../types.zig");
const errors = @import("errors");
const data = @import("../data.zig");
const lib = @import("lib.zig");
const parse = @import("parse.zig");
const interpret = @import("interpret.zig");
const lex = @import("lex.zig");

/// The loader is both the public interface for reading and interpreting
/// nyarna code, and provides the context for this process. Calling code shall
/// only access the Loader's functions, while callback code (i.e.
/// implementations of user-defined keywords and builtins) may use the Loader's
/// fields.
///
/// A processor's input is a single source, its output is either a single
/// standalone module or a non-empty list of errors. Returned errors are
/// static errors (4.5) and indicate that the source is invalid Nyarna input.
pub const Loader = struct {
  /// The error reporter for this loader, supplied externally.
  reporter: *errors.Reporter,
  /// The backing allocator for heap allocations used by this loader.
  allocator: *std.mem.Allocator,
  /// The type lattice contains all types ever instantiated during the loading
  /// process and provides the type lattice operations (e.g. type intersection
  /// and type relation checks).
  types: types.Lattice,
  /// Used to allocate all non-source-local objects, i.e. all objects that are
  /// not discarded after a source has been fully interpreted. Uses the
  /// externally supplied allocator.
  storage: std.heap.ArenaAllocator,
  /// This module contains the definitions of intrinsic symbols.
  /// it is initialized with the loader and used in all files the loader
  /// processes.
  intrinsics: *const data.Module,
  /// The error handler which is used to report any recoverable errors that are
  /// encountered. If one or more errors are encountered during loading, the
  /// input is considered to be invalid.
  logger: errors.Handler,

  /// list of known keyword implementations. They bear no name since they are
  /// referenced via their index.
  keyword_registry: std.ArrayListUnmanaged(lib.Provider.KeywordWrapper),
  /// list of known builtin implementations, analoguous to keyword_registry.
  builtin_registry: std.ArrayListUnmanaged(lib.Provider.BuiltinWrapper),

  pub fn init(allocator: *std.mem.Allocator, reporter: *errors.Reporter)
      !Loader {
    var ret = Loader{
      .reporter = reporter,
      .allocator = allocator,
      .types = undefined,
      .storage = std.heap.ArenaAllocator.init(allocator),
      .intrinsics = undefined,
      .logger = .{
        .reporter = reporter,
      },
      .keyword_registry = .{},
      .builtin_registry = .{},
    };
    errdefer ret.storage.deinit();
    ret.types = try types.Lattice.init(&ret.storage);
    errdefer ret.types.deinit();
    ret.intrinsics = try lib.intrinsicModule(&ret);
    return ret;
  }

  pub fn deinit(loader: *Loader) void {
    loader.types.deinit();
    loader.storage.deinit();
  }

  /// interruptible loader of a module. Interrupts happen when a reference to
  /// a module that has not yet been loaded occurs.
  pub const ModuleLoader = struct {
    parser: parse.Parser,
    interpreter: interpret.Interpreter,

    /// TODO: process args
    pub fn create(self: *Loader, input: *const data.Source,
                  _: []*const data.Source) !*ModuleLoader {
      var ret = try self.storage.allocator.create(ModuleLoader);
      errdefer self.storage.allocator.destroy(ret);
      ret.interpreter = try interpret.Interpreter.init(self, input);
      errdefer ret.interpreter.deinit();
      ret.parser = parse.Parser.init();
      return ret;
    }

    pub fn deinit(self: *ModuleLoader) void {
      self.interpreter.deinit();
    }

    pub fn destroy(self: *ModuleLoader) void {
      self.deinit();
      self.interpreter.loader.storage.allocator.destroy(self);
    }

    pub fn load(self: *ModuleLoader, fullast: bool) !*data.Module {
      return try self.interpreter.interpret(try self.loadAsNode(fullast));
    }

    pub fn loadAsNode(self: *ModuleLoader, fullast: bool) !*data.Node {
      return try self.parser.parseSource(&self.interpreter, fullast);
    }

    pub fn initLexer(self: *ModuleLoader) !lex.Lexer {
      return lex.Lexer.init(&self.interpreter);
    }
  };
};