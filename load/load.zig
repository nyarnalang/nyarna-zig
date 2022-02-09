const std = @import("std");
const nyarna = @import("../nyarna.zig");
const types = nyarna.types;
const errors = nyarna.errors;
const model = nyarna.model;
const lib = nyarna.lib;
const Context = nyarna.Context;
const Interpreter = @import("interpret.zig").Interpreter;
const parse = @import("parse.zig");
const lex = @import("lex.zig");


/// interruptible loader of a module. Interrupts happen when a reference to
/// a module that has not yet been loaded occurs, or when a module's parameter
/// definition is encountered.
///
/// Interaction must follow this schema:
///
///   loader = ModuleLoader.create(…);
///
///   loader.work(…); // may be repeated as long as it returns false
///
///   // exactly one of these must be called. Each will deallocate the loader.
///   // finalizeNode() may be called before destroy(). The returned node will
///   // go out of scope after destroy() because it is owned by the ModuleLoader
///   loader.finalize() | [ loader.finalizeNode() ] loader.destroy()
///
///   // loader has been deallocated and mustn't be used anymore.
pub const ModuleLoader = struct {
  data: *nyarna.Globals,
  parser: parse.Parser,
  /// for data local to the module loading process. will go out of scope when
  /// the module has finished loading.
  storage: std.heap.ArenaAllocator,
  interpreter: *Interpreter,
  /// The error handler which is used to report any recoverable errors that
  /// are encountered. If one or more errors are encountered during loading,
  /// the input is considered to be invalid.
  logger: errors.Handler,
  public_syms: std.ArrayListUnmanaged(*model.Symbol) = .{},
  state: union(enum) {
    initial,
    /// encountered a parameter specification
    encountered_parameters,
    parsing,
    interpreting: *model.Node,
    finished: *model.Expression,
  },
  fullast: bool,

  /// allocates the loader and initializes it. Give no_interpret if you want to
  /// load the input as Node without interpreting it.
  pub fn create(data: *nyarna.Globals, input: *const model.Source.Descriptor,
                resolver: *nyarna.Resolver, fullast: bool) !*ModuleLoader {
    var ret = try data.storage.allocator().create(ModuleLoader);
    ret.* = .{
      .data = data,
      .logger = .{.reporter = data.reporter},
      .fullast = fullast,
      .state = .initial,
      .interpreter = undefined,
      .parser = parse.Parser.init(),
      .storage = std.heap.ArenaAllocator.init(data.backing_allocator),
    };
    errdefer data.storage.allocator().destroy(ret);
    const source =
      (try resolver.getSource(input, ret.storage.allocator(), &ret.logger))
      orelse blk: {
        const poison = try data.storage.allocator().create(model.Expression);
        poison.* = .{
          .pos = model.Position{
            .source = input,
            .start = model.Cursor.unknown(),
            .end = model.Cursor.unknown(),
          },
          .data = .poison,
          .expected_type = .{.intrinsic = .poison},
        };
        ret.state = .{.finished = poison};
        // it is safe to leave the source undefined here, as a finished
        // ModuleLoader will never call its interpreter.
        break :blk undefined;
      };
    ret.interpreter = (try Interpreter.create(
      ret.ctx(), ret.storage.allocator(), source, &ret.public_syms));
    return ret;
  }

  inline fn ctx(self: *ModuleLoader) Context {
    return Context{.data = self.data, .logger = &self.logger};
  }

  /// deallocates the loader and its owned data.
  pub fn destroy(self: *ModuleLoader) void {
    const allocator = self.data.storage.allocator();
    self.storage.deinit();
    allocator.destroy(self);
  }

  fn handleError(self: *ModuleLoader, e: parse.Error) nyarna.Error!bool {
    switch (e) {
      parse.UnwindReason.referred_module_unavailable =>
        if (self.state == .initial or self.state == .encountered_parameters) {
          self.state = .parsing;
        },
      parse.UnwindReason.encountered_parameters =>
        self.state = .encountered_parameters,
      else => |actual_error| return actual_error,
    }
    return false;
  }

  /// return true if finished
  pub fn work(self: *ModuleLoader) !bool {
    while (true) switch (self.state) {
      .initial => {
        const node = self.parser.parseSource(self.interpreter, self.fullast)
          catch |e| return self.handleError(e);
        self.state = .{.interpreting = node};
      },
      .parsing, .encountered_parameters => {
        const node = self.parser.resumeParse()
          catch |e| return self.handleError(e);
        self.state = .{.interpreting = node};
      },
      .interpreting => |node| {
        if (self.fullast) return true;
        const root = self.interpreter.interpret(node)
          catch |e| return self.handleError(e);
        self.state = .{.finished = root};
        return true;
      },
      .finished => return true,
    };
  }

  /// deallocates the loader and returns the loaded module.
  /// preconditions:
  ///
  ///  * self.work() must have returned true
  ///  * create() must have been called with fullast == false
  pub fn finalize(self: *ModuleLoader) !*model.Module {
    std.debug.assert(!self.fullast);
    defer self.destroy();
    const ret = try self.ctx().global().create(model.Module);
    ret.* = .{
      .symbols = self.public_syms.items,
      .root = self.state.finished,
    };
    if (self.logger.count > 0) self.data.seen_error = true;
    return ret;
  }

  /// deallocates the loader and returns the loaded node.
  /// preconditions:
  ///
  ///  * self.work() must have returned true
  ///  * create() must have been called with fullast == true
  pub fn finalizeNode(self: *ModuleLoader) *model.Node {
    std.debug.assert(self.fullast);
    return self.state.interpreting;
  }

  /// this function mainly exists for testing the lexer. as far as the public
  /// API is concerned, the lexer is an implementation detail.
  pub fn initLexer(self: *ModuleLoader) !lex.Lexer {
    std.debug.assert(self.state == .initial);
    return lex.Lexer.init(self.interpreter);
  }
};