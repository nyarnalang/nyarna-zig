const std = @import("std");
const nyarna = @import("../nyarna.zig");
const types = nyarna.types;
const errors = nyarna.errors;
const data = nyarna.data;
const lib = nyarna.lib;
const Context = nyarna.Context;
const parse = @import("parse.zig");
const lex = @import("lex.zig");


/// interruptible loader of a module. Interrupts happen when a reference to
/// a module that has not yet been loaded occurs.
pub const ModuleLoader = struct {
  context: *Context,
  parser: parse.Parser,
  interpreter: nyarna.Interpreter,
  /// The error handler which is used to report any recoverable errors that
  /// are encountered. If one or more errors are encountered during loading,
  /// the input is considered to be invalid.
  logger: errors.Handler,
  public_syms: std.ArrayListUnmanaged(*data.Symbol),

  /// TODO: process args
  pub fn create(context: *Context, input: *const data.Source,
                _: []*const data.Source) !*ModuleLoader {
    var ret = try context.storage.allocator.create(ModuleLoader);
    ret.context = context;
    ret.public_syms = .{};
    ret.logger = .{
      .reporter = context.reporter,
    };
    errdefer context.storage.allocator.destroy(ret);
    ret.interpreter = try nyarna.Interpreter.init(ret, input);
    errdefer ret.interpreter.deinit();
    ret.parser = parse.Parser.init();
    return ret;
  }

  pub fn deinit(self: *ModuleLoader) void {
    self.interpreter.deinit();
  }

  pub fn destroy(self: *ModuleLoader) void {
    self.deinit();
    self.interpreter.loader.context.storage.allocator.destroy(self);
  }

  pub fn load(self: *ModuleLoader, fullast: bool) !*data.Module {
    var root = try self.interpreter.interpret(try self.loadAsNode(fullast));
    var ret = try self.interpreter.createPublic(data.Module);
    ret.* = .{
      .symbols = self.public_syms.items,
      .root = root,
    };
    return ret;
  }

  pub fn loadAsNode(self: *ModuleLoader, fullast: bool) !*data.Node {
    return try self.parser.parseSource(&self.interpreter, fullast);
  }

  /// this function mainly exists for testing the lexer. as far as the public
  /// API is concerned, the lexer is an implementation detail.
  pub fn initLexer(self: *ModuleLoader) !lex.Lexer {
    return lex.Lexer.init(&self.interpreter);
  }
};