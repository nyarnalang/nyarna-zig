//! The Interpreter is part of the process to read in a single file or stream.
//! It provides both the functionality of interpretation, i.e. transformation
//! of AST nodes to expressions, and context data for the lexer and parser.
//!
//! The interpreter implements a push-interface, i.e. nodes are pushed into it
//! for interpretation by the parser. The parser decides when nodes ought to be
//! interpreted.
//!
//! The interpreter is a parameter to keyword implementations, which are allowed
//! to leverage its facilities for the implementation of static semantics.

const std = @import("std");

const CycleResolution     = @import("Interpreter/CycleResolution.zig");
const graph               = @import("Interpreter/graph.zig");
const IntersectionChecker = @import("Interpreter/IntersectionChecker.zig");
const MatchBuilder        = @import("Interpreter/MatchBuilder.zig");
const nyarna              = @import("../nyarna.zig");
const Parser              = @import("Parser.zig");
const syntaxes            = @import("Parser/syntaxes.zig");
const unicode             = @import("unicode.zig");

const errors = nyarna.errors;
const lib    = nyarna.lib;
const Loader = nyarna.Loader;
const model  = nyarna.model;
const Types  = nyarna.Types;

const last = @import("helpers.zig").last;

pub const Resolver = @import("Interpreter/Resolver.zig");

pub const Errors = error {
  referred_source_unavailable,
};

/// Describes the current stage when trying to interpret nodes.
pub const Stage = struct {
  kind: enum {
    /// in intermediate stage, symbol resolutions are allowed to fail and won't
    /// generate error messages. This allows forward references e.g. in \declare
    intermediate,
    /// keyword stage is used for interpreting value (non-AST) arguments of
    /// keywords. Failed symbol resolution will issue an error saying that the
    /// symbol cannot be resolved *immediately* (telling the user that forward
    /// references are not possible here).
    keyword,
    /// the final stage of node resolutions, in which all context is available
    /// and thus all nodes must be interpretable. Failed symbol resolution here
    /// will issue an error saying that the symbol is unknown.
    final,
    /// this stage is used when the code assumes that interpretation cannot
    /// fail. Failure will result in an std.debug.panic.
    assumed,
  },
  /// additional resolution context that is set during cyclic resolution /
  /// fixpoint iteration in \declare and templates. This context is queried for
  /// symbol resolution if the symbol is not directly resolvable in its
  /// namespace.
  resolve_ctx: ?*Resolver.Context = null,
};

/// An internal namespace that contains a set of symbols with unique names.
/// This data type is optimized for quick symbol name lookup. In contrast, a
/// module's external namespace is a simple list not supporting name lookup
/// directly since it is only ever imported into internal namespaces, where
/// symbols will be looked up.
pub const Namespace = struct {
  index: ?usize,
  data : std.StringArrayHashMapUnmanaged(*model.Symbol) = .{},

  pub fn tryRegister(
    self : *Namespace,
    intpr: *Interpreter,
    sym  : *model.Symbol,
  ) std.mem.Allocator.Error!bool {
    const res = try self.data.getOrPut(intpr.allocator(), sym.name);
    // if the symbol exists, check if the existing symbol is intrinsic.
    // if so, the new symbol overrides a magic symbol used in system.ny which is
    // allowed.
    if (res.found_existing and !res.value_ptr.*.defined_at.isIntrinsic()) {
      intpr.ctx.logger.DuplicateSymbolName(
        sym.name, sym.defined_at, res.value_ptr.*.defined_at);
      return false;
    } else {
      res.value_ptr.* = sym;
      if (self.index) |index| {
        try intpr.symbols.append(intpr.allocator(), .{
          .ns    = @intCast(u15, index),
          .sym   = sym,
          .alive = true,
        });
      }
      return true;
    }
  }
};

const IterableInput = struct {
  const Kind = enum {concat, list, sequence};

  kind     : Kind,
  item_type: model.Type,
};

pub const ModuleInOut = struct {
  params: []model.locations.Ref,
  root  : model.Type,
};

const Interpreter = @This();

pub const ActiveVarContainer = struct {
  /// into Interpreter.symbols. At this offset, the first symbol (if any)
  /// of the container is found.
  offset: usize,
  /// unfinished. required to link newly created variables to it.
  container: *model.VariableContainer,
};

/// Context of the ModuleLoader that owns this interpreter.
ctx: nyarna.Context,
/// the loader owning this interpreter
loader: *Loader,
/// Maps each existing command character to the index of the namespace it
/// references. Lexer uses this to check whether a character is a command
/// character; the namespace mapping is relevant later for the interpreter.
/// The values are indexes into the namespaces field.
command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15) = .{},
/// Used when disabling all command characters. Will be swapped with
/// command_characters until the block disabling the command characters ends.
stored_command_characters: std.hash_map.AutoHashMapUnmanaged(u21, u15) = .{},
/// Internal namespaces in the source file [6.1].
/// A namespace will not be deleted when it goes out of scope, so that we do
/// not need to apply special care for delayed resolution of symrefs:
/// If a symref cannot initially be resolved to a symbol, it will be stored
/// with namespace index and target name. Since namespaces are never deleted,
// it will still try to find its target symbol in the same namespace when
/// delayed resolution is triggered.
namespaces: std.ArrayListUnmanaged(Namespace) = .{},
/// Type namespaces [6.2].
/// The namespace of a type is added to this hashmap when the first symbol in
/// that namespace is established. This hashmap is used to lookup any
/// references to symbols in a type's namespace in the current source file.
type_namespaces: std.HashMapUnmanaged(model.Type, Namespace,
  model.Type.HashContext, std.hash_map.default_max_load_percentage) = .{},
/// Array of alternative syntaxes known to the interpreter [7.12].
/// TODO: make this user-extensible
syntax_registry: [2]syntaxes.SpecialSyntax,
/// convenience object to generate nodes using the interpreter's storage.
node_gen: model.NodeGenerator,
/// symbols declared in the source code. Each symbol is initially alive,
/// until it gets out of scope at which time it becomes dead but stays in the
/// list. This list is used to deregister symbols at the end of their
/// lifetime, and for giving variable containers a list of contained symbols.
/// This list never shrinks.
symbols: std.ArrayListUnmanaged(model.Symbol.Definition) = .{},
/// length equals the current list of open levels whose type is FrameRoot.
var_containers: std.ArrayListUnmanaged(ActiveVarContainer) = .{},
/// the implementation of builtin functions for this module, if any.
builtin_provider: ?*const lib.Provider,
/// the content of the current file, as specified by \library, \standalone or
/// \fragment.
specified_content: union(enum) {
  library: model.Position,
  standalone: struct {
    pos     : model.Position,
    schema  : ?*model.Value.Schema,
    in_out  : ModuleInOut,
  },
  fragment: struct {
    pos     : model.Position,
    in_out  : ModuleInOut,
  },
  unspecified,
} = .unspecified,

/// creates an interpreter.
pub fn create(
  loader   : *nyarna.Loader,
  provider : ?*const lib.Provider,
) std.mem.Allocator.Error!*Interpreter {
  var ret = try loader.storage.allocator().create(Interpreter);
  ret.* = .{
    .ctx             = loader.ctx(),
    .loader          = loader,
    .syntax_registry = .{
      syntaxes.SymbolDefs.locations(),
      syntaxes.SymbolDefs.definitions(),
    },
    .node_gen         = undefined,
    .builtin_provider = provider,
  };
  ret.node_gen = model.NodeGenerator.init(loader.storage.allocator(), ret.ctx);
  ret.addNamespace('\\') catch |e| switch (e) {
    // never happens, as only one namespace is added.
    error.too_many_namespaces           => unreachable,
    std.mem.Allocator.Error.OutOfMemory => |oom| return oom,
  };
  const container = try ret.ctx.global().create(model.VariableContainer);
  container.* = .{.num_values = 0};
  try ret.var_containers.append(loader.storage.allocator(), .{
    .offset = 0, .container = container,
  });
  return ret;
}

pub fn allocator(self: *Interpreter) std.mem.Allocator {
  return self.loader.storage.allocator();
}

pub fn addNamespace(self: *Interpreter, character: u21) !void {
  const index = self.namespaces.items.len;
  if (index > std.math.maxInt(u15)) return error.too_many_namespaces;
  try self.command_characters.put(
    self.allocator(), character, @intCast(u15, index));
  try self.namespaces.append(self.allocator(), .{.index = index});
  const ns = self.namespace(@intCast(u15, index));
  // intrinsic symbols of every namespace.
  for (self.ctx.data.generic_symbols.items) |sym| {
    _ = try ns.tryRegister(self, sym);
  }
}

pub fn namespace(self: *Interpreter, ns: u15) *Namespace {
  return &self.namespaces.items[ns];
}

pub const Mark = usize;

pub fn markSyms(self: *Interpreter) Mark {
  return self.symbols.items.len;
}

pub fn resetSyms(self: *Interpreter, state: Mark) void {
  for (self.symbols.items[state..]) |*ds| {
    if (ds.alive) {
      const ns = self.namespace(ds.ns);
      ns.data.shrinkRetainingCapacity(ns.data.count() - 1);
      ds.alive = false;
    }
  }
}

pub fn type_namespace(self: *Interpreter, t: model.Type) !*Namespace {
  const entry = try self.type_namespaces.getOrPutValue(
    self.allocator(), t, Namespace{.index = null});
  return entry.value_ptr;
}

/// imports all symbols in the external namespace of the given module into the
/// internal namespace given by ns_index.
pub fn importModuleSyms(
  self    : *Interpreter,
  module  : *const model.Module,
  ns_index: u15,
) !void {
  const ns = self.namespace(ns_index);
  for (module.symbols) |sym| {
    if (sym.parent_type) |ptype| {
      _ = try (try self.type_namespace(ptype)).tryRegister(self, sym);
    } else _ = try ns.tryRegister(self, sym);
  }
}

pub fn removeNamespace(self: *Interpreter, character: u21) void {
  const ns_index = self.command_characters.fetchRemove(character).?;
  _ = ns_index;
  // namespaces are kept in self.namespaces to avoid any errors resulting from
  // unresolved symbols being resolved after the namespace is gone.
  // OPPORTUNITY: check if this can be avoided and then actually remove the
  // namespace
  //std.debug.assert(ns_index.value == self.namespaces.items.len - 1);
  //_ = self.namespaces.pop();
}

fn tryInterpretChainEnd(
  self : *Interpreter,
  node : *model.Node,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  switch (try Resolver.init(self, stage).resolveChain(node)) {
    .runtime => |*rc| {
      if (rc.preliminary) return null;
      if (rc.indexes.items.len == 0) {
        return self.tryInterpret(rc.base, stage);
      } else {
        std.debug.assert(rc.base != node);
        node.data = .{.resolved_access = .{
          .base = rc.base,
          .path = rc.indexes.items,
          .last_name_pos = rc.last_name_pos,
          .ns = rc.ns,
        }};
        return self.tryInterpretRAccess(&node.data.resolved_access, stage);
      }
    },
    .sym_ref => |ref| {
      if (ref.preliminary) return null;
      const value = if (ref.prefix != null) blk: {
        self.ctx.logger.PrefixedSymbolMustBeCalled(node.pos);
        break :blk try self.ctx.values.poison(node.pos);
      } else switch (ref.sym.data) {
        .func => |func|
          (try self.ctx.values.funcRef(node.pos, func)).value(),
        .@"type" => |t|
          (try self.ctx.values.@"type"(node.pos, t)).value(),
        .prototype => |pt|
          (try self.ctx.values.prototype(node.pos, pt)).value(),
        .variable, .poison => unreachable,
      };
      return try self.ctx.createValueExpr(value);
    },
    .failed, .function_returning => return null,
    .poison => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(node.pos)),
  }
}

fn tryInterpretRootDef(
  self: *Interpreter,
  rdef: *model.Node.RootDef,
) nyarna.Error!*model.Expression {
  if (rdef.kind == .library) {
    self.specified_content = .{.library = rdef.node().pos};
  } else {
    var schema: ?*model.Value.Schema = null;
    const root = if (rdef.kind == .fragment) blk: {
      const expr = (
        try self.associate(
          rdef.root.?, self.ctx.types().@"type"().predef(), .{.kind = .final})
      ) orelse break :blk self.ctx.types().poison();
      break :blk switch ((try self.ctx.evaluator().evaluate(expr)).data) {
        .@"type" => |tv| tv.t,
        .poison  => self.ctx.types().poison(),
        else     => unreachable,
      };
    } else blk: {
      if (rdef.root) |rnode| {
        const expr =
          try self.interpretAs(rnode, self.ctx.types().schema().predef());
        switch ((try self.ctx.evaluator().evaluate(expr)).data) {
          .schema => |*sch| {
            schema = sch;
            for (sch.symbols) |sym| {
              _ = try self.namespace(0).tryRegister(self, sym);
            }
            break :blk sch.root.t;
          },
          .poison => break :blk self.ctx.types().poison(),
          else => unreachable,
        }
      } else break :blk self.ctx.types().text();
    };

    var list = std.ArrayList(model.locations.Ref).init(self.allocator());
    if (rdef.params) |params| {
      if (try self.locationsCanGenVars(params, .{.kind = .final})) {
        try self.collectLocations(params, &list);
      }
    }

    self.specified_content = switch (rdef.kind) {
      .fragment => .{.fragment = .{
        .pos      = rdef.node().pos,
        .in_out   = .{.params = list.items, .root = root},
      }},
      .standalone => .{.standalone = .{
        .pos      = rdef.node().pos,
        .schema   = schema,
        .in_out   = .{.params = list.items, .root = root},
      }},
      .library => unreachable,
    };
  }
  const expr = try self.ctx.global().create(model.Expression);
  expr.* = .{
    .pos           = rdef.node().pos,
    .data          = .void,
    .expected_type = self.ctx.types().@"void"(),
  };
  return expr;
}

fn tryInterpretUAccess(
  self : *Interpreter,
  uacc : *model.Node.UnresolvedAccess,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  return try self.tryInterpretChainEnd(uacc.node(), stage);
}

fn tryInterpretURef(
  self : *Interpreter,
  uref : *model.Node.UnresolvedSymref,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  return try self.tryInterpretChainEnd(uref.node(), stage);
}

const PathResult = union(enum) {
  success: struct {
    path: []model.Expression.Access.PathItem,
    t   : model.Type,
  },
  poison, unfinished
};

fn tryInterpretPath(
  self        : *Interpreter,
  subject_type: model.Type,
  path        : []const model.Node.Assign.PathItem,
  stage       : Stage,
) !PathResult {
  var cur_t = subject_type;
  var seen_poison = false;
  var seen_unfinished = false;
  for (path) |item| switch (item) {
    .field     => |field| cur_t = Types.descend(field.t.typedef(), field.index),
    .subscript => |node| {
      const req_t = switch (cur_t.structural.*) {
        .concat => |*con| blk: {
          cur_t = con.inner;
          break :blk self.ctx.types().system.positive;
        },
        .list => |*lst| blk: {
          cur_t = lst.inner;
          break :blk self.ctx.types().system.positive;
        },
        .sequence => |*seq| blk: {
          cur_t = try self.ctx.types().seqInnerType(seq);
          break :blk self.ctx.types().system.positive;
        },
        else => unreachable,
      };
      if (try self.associate(node, req_t.predef(), stage)) |s_expr| {
        node.data = .{.expression = s_expr};
        if (s_expr.expected_type.isNamed(.poison)) seen_poison = true;
      } else seen_unfinished = true;
    }
  };
  if (seen_unfinished) return PathResult.unfinished;
  if (seen_poison) return PathResult.poison;

  const expr_path = try self.ctx.global().alloc(
    model.Expression.Access.PathItem, path.len);
  for (path) |item, i| switch (item) {
    .field => |field| expr_path[i] = .{
      .field = .{.index = field.index, .t = field.t},
    },
    .subscript => |node| expr_path[i] = .{.subscript = node.data.expression},
  };
  return PathResult{.success = .{.path = expr_path, .t = cur_t}};
}

fn tryInterpretAss(
  self : *Interpreter,
  ass  : *model.Node.Assign,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  const target = switch (ass.target) {
    .resolved => |*val| val,
    .unresolved => |node| innerblk: {
      switch (try Resolver.init(self, stage).resolveChain(node)) {
        .runtime => |*rc| switch (rc.base.data) {
          .resolved_symref => |*rsym| switch (rsym.sym.data) {
            .variable => |*v| {
              ass.target = .{.resolved = .{
                .target = v,
                .path   = rc.indexes.items,
                .spec   = rc.t.at(node.pos),
                .pos    = node.pos,
              }};
              break :innerblk &ass.target.resolved;
            },
            else => {
              self.ctx.logger.InvalidLvalue(node.pos);
              return self.ctx.createValueExpr(
                try self.ctx.values.poison(ass.node().pos));
            }
          },
          .unresolved_call, .unresolved_symref => return null,
          else => {
            self.ctx.logger.InvalidLvalue(node.pos);
            return try self.ctx.createValueExpr(
              try self.ctx.values.poison(ass.node().pos));
          },
        },
        .sym_ref => |*sr| {
          switch (sr.sym.data) {
            .variable => |*v| {
              ass.target = .{
                .resolved = .{
                  .target = v,
                  .path   = &.{},
                  .spec   = v.spec,
                  .pos    = node.pos,
                },
              };
              break :innerblk &ass.target.resolved;
            },
            else => {},
          }
          self.ctx.logger.InvalidLvalue(node.pos);
          return self.ctx.createValueExpr(
            try self.ctx.values.poison(ass.node().pos));
        },
        .poison => {
          return self.ctx.createValueExpr(
            try self.ctx.values.poison(ass.node().pos));
        },
        .failed, .function_returning => return null,
      }
    }
  };
  if (target.target.kind != .assignable) {
    const sym = target.target.sym();
    self.ctx.logger.CannotAssignToConst(
      sym.name, target.pos, sym.defined_at);
    return self.ctx.createValueExpr(
      try self.ctx.values.poison(ass.node().pos));
  }
  const target_expr = (
    try self.associate(ass.replacement, target.spec, stage)
  ) orelse return null;

  const res =
    try self.tryInterpretPath(target.target.spec.t, target.path, stage);
  if (res == .unfinished) return null;

  const expr = try self.ctx.global().create(model.Expression);
  expr.* = switch (res) {
    .poison => .{
      .pos = ass.node().pos,
      .data = .poison,
      .expected_type = self.ctx.types().poison(),
    },
    .success => |s| .{
      .pos  = ass.node().pos,
      .data = .{
        .assignment = .{
          .target = target.target,
          .path   = s.path,
          .rexpr  = target_expr,
        },
      },
      .expected_type = self.ctx.types().void(),
    },
    .unfinished => unreachable,
  };
  return expr;
}

/// probes the given node for its scalar type (if any), and then interprets
/// it using that type, so that any literal nodes will become expression of
/// that type.
fn tryProbeAndInterpret(
  self : *Interpreter,
  input: *model.Node,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  const scalar_type = (
    try self.probeForScalarType(input, stage)
  ) orelse return null;
  return self.interpretWithTargetScalar(input, scalar_type.predef(), stage);
}

fn tryInterpretSymref(
  self : *Interpreter,
  ref  : *model.Node.ResolvedSymref,
) nyarna.Error!?*model.Expression {
  switch (ref.sym.data) {
    .func => |func| {
      if (func.sig().isKeyword()) {
        self.ctx.logger.KeywordMustBeCalled(ref.node().pos);
        return self.ctx.createValueExpr(
          try self.ctx.values.poison(ref.node().pos));
      }
      return self.ctx.createValueExpr(
        (try self.ctx.values.funcRef(ref.node().pos, func)).value());
    },
    .variable => |*v| {
      if (v.spec.t.isNamed(.every)) return null;
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos  = ref.node().pos,
        .data = .{
          .var_retrieval = .{.variable = v},
        },
        .expected_type = v.spec.t,
      };
      return expr;
    },
    .@"type" => |t| return self.ctx.createValueExpr(
      (try self.ctx.values.@"type"(ref.node().pos, t)).value()),
    .prototype => |pt| return self.ctx.createValueExpr(
      (try self.ctx.values.prototype(ref.node().pos, pt)).value()),
    .poison => return self.ctx.createValueExpr(
      try self.ctx.values.poison(ref.node().pos)),
  }
}

fn tryInterpretCall(
  self : *Interpreter,
  rc   : *model.Node.ResolvedCall,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  const is_keyword = rc.sig.returns.isNamed(.ast);
  const target: ?*model.Expression = if (is_keyword) null else (
    try self.tryInterpret(rc.target, stage)
  ) orelse return null;

  const cur_allocator =
    if (is_keyword) self.allocator() else self.ctx.global();
  var args_failed_to_interpret = false;
  const arg_stage = Stage{
    .kind = if (is_keyword) .keyword else stage.kind,
    .resolve_ctx = stage.resolve_ctx,
  };
  // in-place modification of args requires that the arg nodes have been
  // created by the current document. The only way a node from another
  // document can be referenced in the current document is through
  // compile-time functions. Therefore, we always copy call nodes that
  // originate from calls of compile-time functions.
  for (rc.args) |*arg, i| {
    if (arg.*.data != .expression) {
      arg.*.data = if (
        try self.associate(arg.*, rc.sig.parameters[i].spec, arg_stage)
      ) |e| .{.expression = e}
      else {
        args_failed_to_interpret = true;
        continue;
      };
    }
  }

  if (args_failed_to_interpret) {
    return if (is_keyword) try self.ctx.createValueExpr(
      try self.ctx.values.poison(rc.node().pos)) else null;
  }

  const args = try cur_allocator.alloc(
    *model.Expression, rc.sig.parameters.len);
  var seen_poison = false;
  for (rc.args) |arg, i| {
    args[i] = arg.data.expression;
    if (args[i].expected_type.isNamed(.poison)) seen_poison = true;
  }

  if (target) |rt_target| {
    const expr = try cur_allocator.create(model.Expression);
    expr.* = .{
      .pos  = rc.node().pos,
      .data = .{
        .call = .{
          .ns     = rc.ns,
          .target = rt_target,
          .exprs  = args,
        },
      },
      .expected_type = rc.sig.returns,
    };
    return expr;
  } else {
    var eval = self.ctx.evaluator();
    const res = try eval.evaluateKeywordCall(
      self, rc.node().pos, rc.ns, rc.target.data.resolved_symref.sym, args);
    // if this is an import, the parser must handle it.
    const interpreted_res = if (res.data == .import) null else
      try self.tryInterpret(res, stage);
    if (interpreted_res == null) {
      // it would be nicer to actually replace the original node with `res`
      // but that would make the tryInterpret API more complicated so we just
      // update the original node instead.
      rc.node().* = res.*;
    }
    return interpreted_res;
  }
}

fn tryInterpretCapture(
  self: *Interpreter,
  cpt : *model.Node.Capture,
) !?*model.Expression {
  self.ctx.logger.UnexpectedCaptureVars(
    cpt.vars[0].pos.span(last(cpt.vars).pos));
  // remove capture from the tree, replace it with content
  const content = cpt.content;
  cpt.node().data = content.data;
  return null;
}

fn tryInterpretLoc(
  self : *Interpreter,
  loc  : *model.Node.Location,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var incomplete = false;
  var t = if (loc.@"type") |node| blk: {
    var expr = (
      try self.associate(
        node, self.ctx.types().@"type"().predef(), stage)
    ) orelse {
      incomplete = true;
      break :blk null;
    };
    break :blk expr;
  } else null;

  var default: ?*model.Expression = null;
  if (loc.default) |node| {
    const res: ?*model.Expression = if (t) |texpr| switch (texpr.data) {
      .value => |val| switch (val.data) {
        .@"type" => |tv|
          try self.associate(node, tv.t.at(texpr.pos), stage),
        else => try self.tryInterpret(node, stage),
      },
      else => try self.tryInterpret(node, stage),
    } else try self.tryInterpret(node, stage);
    if (res) |rexpr| default = rexpr else incomplete = true;
  }

  if (incomplete) return null;

  const name = (
    try self.associate(loc.name, self.ctx.types().literal().predef(), stage)
  ) orelse return null;

  const ret = try self.ctx.global().create(model.Expression);
  ret.* = .{
    .pos  = loc.node().pos,
    .data = .{.location = .{
      .name        = name,
      .@"type"     = t,
      .default     = default,
      .additionals = loc.additionals,
    }},
    .expected_type = self.ctx.types().location(),
  };
  return ret;
}

fn tryInterpretMap(
  self : *Interpreter,
  map  : *model.Node.Map,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var seen_unfinished = false;
  var seen_poison = false;

  var ret_inner_type: model.SpecType = undefined;
  // we need the type of the func to properly interpret scalars inside of the
  // input.
  const func_input_type = if (map.func) |func| blk: {
    if (try self.tryInterpret(func, stage)) |expr| {
      func.data = .{.expression = expr};
      switch (expr.expected_type) {
        .structural => |strct| switch (strct.*) {
          .callable => |*call| {
            ret_inner_type = call.sig.returns.at(func.pos);
            switch (call.sig.parameters.len) {
              1 => break :blk call.sig.parameters[0].spec.t,
              2 => if (
                self.ctx.types().lesserEqual(
                  self.ctx.types().system.positive,
                  call.sig.parameters[1].spec.t)
              ) break :blk call.sig.parameters[0].spec.t,
              else => {}
            }
            self.ctx.logger.UnfitForMapFunction(
              &.{expr.expected_type.at(expr.pos)});
          },
          else => {
            self.ctx.logger.NotCallable(&.{expr.expected_type.at(func.pos)});
          },
        },
        .named => |named| {
          if (named.data != .poison) self.ctx.logger.NotCallable(&.{
            expr.expected_type.at(func.pos)
          });
        },
      }
      seen_poison = true;
    } else seen_unfinished = true;
    break :blk null;
  } else null;

  const input: IterableInput = if (!seen_unfinished) blk: {
    const scalar = if (func_input_type) |t| Types.containedScalar(t) else null;
    if (
      if (scalar) |st| (
        try self.interpretWithTargetScalar(
          map.input, st.at(map.func.?.pos), stage)
      ) else try self.tryInterpret(map.input, stage)
    ) |expr| {
      map.input.data = .{.expression = expr};
      if (
        try self.inspectIterableInput(expr.expected_type.at(expr.pos))
      ) |input_i| {
        if (func_input_type) |it| {
          if (!(self.ctx.types().lesserEqual(input_i.item_type, it))) {
            self.ctx.logger.ExpectedExprOfTypeXGotY(
              &.{input_i.item_type.at(map.input.pos), it.at(map.func.?.pos)});
            expr.data = .poison;
            seen_poison = true;
          }
        } else ret_inner_type = input_i.item_type.at(expr.pos);
        break :blk input_i;
      } else {
        expr.data = .poison;
        seen_poison = true;
        break :blk undefined;
      }
    } else {
      seen_unfinished = true;
      break :blk undefined;
    }
  } else undefined;

  if (seen_poison) {
    map.node().data = .poison;
    return null;
  } else if (seen_unfinished) return null;

  const coll: ?*model.Expression = if (map.collector) |c_node| (
    (try self.tryInterpret(c_node, stage)) orelse return null
  ) else null;

  return try self.genMap(
    map.node().pos, map.input.data.expression, input,
    if (map.func) |f| f.data.expression else null, ret_inner_type.t, coll);
}

fn tryInterpretDef(
  self : *Interpreter,
  def  : *model.Node.Definition,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  const expr = (
    try self.tryInterpret(def.content, stage)
  ) orelse return null;
  const value = try self.ctx.evaluator().evaluate(expr);
  const content:
    std.meta.fieldInfo(model.Value.Definition, .content).field_type =
    switch (value.data) {
      .funcref => |f| .{.func = f.func},
      .@"type" => |tv| .{.@"type" = tv.t},
      else => {
        if (value.data != .poison) {
          self.ctx.logger.InvalidDefinitionValue(
            &.{try self.ctx.types().valueSpecType(value)});
        }
        return try self.ctx.createValueExpr(
          try self.ctx.values.poison(def.node().pos));
      }
    };
  const name = try self.ctx.values.textScalar(
    def.name.node().pos, self.ctx.types().literal(),
    try self.ctx.global().dupe(u8, def.name.content));

  const def_val = try self.ctx.values.definition(
    def.node().pos, name, content, def.node().pos);
  return try self.ctx.createValueExpr(def_val.value());
}

/// check whether input type t is iterable. if so, returns relevant data.
/// Else, reports error(s) and returns null.
fn inspectIterableInput(
  self      : *Interpreter,
  spec      : model.SpecType,
) !?IterableInput {
  return switch (spec.t) {
    .structural => |strct| switch (strct.*) {
      .concat => |*con| IterableInput{.kind = .concat, .item_type = con.inner},
      .list   => |*lst| IterableInput{.kind = .list, .item_type = lst.inner},
      .sequence => |*seq| IterableInput{
        .kind = .sequence, .item_type = try self.ctx.types().seqInnerType(seq),
      },
      else => {
        self.ctx.logger.NotIterable(&.{spec});
        return null;
      },
    },
    .named => |named| {
      if (named.data != .poison) self.ctx.logger.NotIterable(&.{spec});
      return null;
    },
  };
}

/// checks if input is interpretable. Returns the iterable
/// kind of the input on success, or null if either input or collector can't be
/// interpreted.
fn inspectForInput(
  self  : *Interpreter,
  f_node: *model.Node.For,
  stage : Stage,
) !?IterableInput {
  if (try self.tryInterpret(f_node.input, stage)) |expr| {
    f_node.input.data = .{.expression = expr};
    if (
      try self.inspectIterableInput(expr.expected_type.at(expr.pos))
    ) |input| {
      if (!f_node.gen_vars and f_node.captures.len > 0) {
        f_node.gen_vars = true;
        const mark = self.markSyms();
        defer self.resetSyms(mark);
        const item_sym = try self.ctx.global().create(model.Symbol);
        item_sym.* = .{
          .defined_at = f_node.captures[0].pos,
          .name       = f_node.captures[0].name,
          .data       = .{.variable = .{
            .spec       = input.item_type.at(f_node.input.pos),
            .container  = f_node.variables,
            .offset     = f_node.variables.num_values,
            .kind       = .given,
          }},
          .parent_type = null,
        };
        f_node.variables.num_values += 1;
        _ = try self.namespaces.items[f_node.captures[0].ns].tryRegister(
          self, item_sym);
        if (f_node.captures.len > 1) {
          const index_sym = try self.ctx.global().create(model.Symbol);
          index_sym.* = .{
            .defined_at = f_node.captures[1].pos,
            .name       = f_node.captures[1].name,
            .data       = .{.variable = .{
              .spec       = self.ctx.types().system.positive.predef(),
              .container  = f_node.variables,
              .offset     = f_node.variables.num_values,
              .kind       = .given,
            }},
            .parent_type = null,
          };
          f_node.variables.num_values += 1;
          _ = try self.namespaces.items[f_node.captures[1].ns].tryRegister(
            self, index_sym);
        }
        if (f_node.captures.len > 2) {
          self.ctx.logger.UnexpectedCaptureVars(
            f_node.captures[2].pos.span(last(f_node.captures).pos));
          f_node.captures = f_node.captures[0..1];
        }
        try Resolver.init(self, .{.kind = .intermediate}).resolve(f_node.body);
      }
      return input;
    } else {
      expr.data = .poison;
    }
  }
  return null;
}

fn genMapRetType(
  self     : *Interpreter,
  input    : IterableInput,
  body_pos : model.Position,
  collector: ?*model.Expression,
) !model.Type {
  const gen = if (collector) |expr| blk: {
    const value = try self.ctx.evaluator().evaluate(expr);
    expr.data = .{.value = value};
    switch (value.data) {
      .poison    => return self.ctx.types().poison(),
      .prototype => |*pv| switch (pv.pt) {
        .concat    => break :blk IterableInput.Kind.concat,
        .list      => break :blk IterableInput.Kind.list,
        .sequence  => break :blk IterableInput.Kind.sequence,
        else       => {},
      },
      else => {}
    }
    self.ctx.logger.InvalidCollector(expr.pos);
    return self.ctx.types().poison();
  } else input.kind;
  return switch (gen) {
    .concat => (
      try self.ctx.types().concat(input.item_type)
    ) orelse blk: {
      self.ctx.logger.InvalidInnerConcatType(&.{input.item_type.at(body_pos)});
      break :blk self.ctx.types().poison();
    },
    .list => (
      try self.ctx.types().list(input.item_type)
    ) orelse blk: {
      self.ctx.logger.InvalidInnerListType(&.{input.item_type.at(body_pos)});
      break :blk self.ctx.types().poison();
    },
    .sequence => blk: {
      var builder = Types.SequenceBuilder.init(
        self.ctx.types(), self.allocator(), true);
      const res = try builder.push(input.item_type.at(body_pos), true);
      res.report(input.item_type.at(body_pos), self.ctx.logger);
      break :blk if (res == .success) (
        (try builder.finish(null, null)).t
      ) else self.ctx.types().poison();
    },
  };
}

fn tryForBodyToFunc(
  self       : *Interpreter,
  f_node     : *model.Node.For,
  input      : IterableInput,
  scalar_type: ?model.SpecType,
  stage      : Stage,
) !?*model.Expression {
  if (
    if (scalar_type) |st| (
      try self.interpretWithTargetScalar(f_node.body, st, stage)
    ) else try self.tryInterpret(f_node.body, stage)
  ) |expr| {
    f_node.body.data = .{.expression = expr};

    var builder = try Types.SigBuilder.init(
      self.ctx, std.math.min(2, f_node.captures.len), expr.expected_type,
      false);
    if (f_node.captures.len > 0) {
      try builder.pushUnwrapped(
        f_node.captures[0].pos, f_node.captures[0].name,
        input.item_type.at(f_node.input.pos));
    }
    if (f_node.captures.len > 1) {
      try builder.pushUnwrapped(
        f_node.captures[1].pos, f_node.captures[1].name,
        self.ctx.types().system.positive.predef());
    }
    const builder_res = builder.finish();

    const ret = try self.ctx.global().create(model.Function);
    ret.* = .{
      .callable = try builder_res.createCallable(self.ctx.global(), .function),
      .name       = null,
      .defined_at = f_node.body.pos,
      .data       = .{.ny = .{.body = expr}},
      .variables  = f_node.variables,
    };
    return try self.ctx.createValueExpr((
      try self.ctx.values.funcRef(f_node.body.pos, ret)
    ).value());
  } else return null;
}

fn genMap(
  self     : *Interpreter,
  pos      : model.Position,
  input    : *model.Expression,
  input_i  : IterableInput,
  func     : ?*model.Expression,
  ret_inner: model.Type,
  collector: ?*model.Expression,
) !*model.Expression {
  const ret_type = try self.genMapRetType(.{
    .kind = input_i.kind,
    .item_type = ret_inner,
  }, if (func) |f| f.pos else input.pos, collector);

  const ret = try self.ctx.global().create(model.Expression);
  ret.* = .{
    .pos = pos,
    .data = .{.map = .{
      .input = input, .func = func,
    }},
    .expected_type = ret_type,
  };
  return ret;
}

fn tryInterpretFor(
  self  : *Interpreter,
  f_node: *model.Node.For,
  stage : Stage,
) !?*model.Expression {
  if (try self.inspectForInput(f_node, stage)) |input| {
    const coll: ?*model.Expression = if (f_node.collector) |c_node| (
      (try self.tryInterpret(c_node, stage)) orelse return null
    ) else null;

    if (try self.tryForBodyToFunc(f_node, input, null, stage)) |func| {
      return try self.genMap(
        f_node.node().pos, f_node.input.data.expression, input, func,
        f_node.body.data.expression.expected_type, coll);
    }
  }
  return null;
}

pub fn tryInterpretImport(
  self  : *Interpreter,
  import: *model.Node.Import,
) Parser.Error!?*model.Expression {
  const me = &self.ctx.data.known_modules.values()[import.module_index];
  switch (me) {
    .loaded => |module| {
      self.importModuleSyms(module, import.ns_index);
      return module.root;
    },
    .require_options => |ml| {
      me.* = .{.require_module = ml};
      return Parser.UnwindReason.referred_module_unavailable;
    },
    .require_module => {
      // cannot happen. if the module is further down the dependency chain
      // than the current one is, then it would have had priority before ours
      // after .require_module has been set.
      unreachable;
    }
  }
}

fn ensureResolved(
  self : *Interpreter,
  node : *model.Node,
  stage: Stage,
) nyarna.Error!?*model.Node {
  switch (node.data) {
    .unresolved_call, .unresolved_symref => {
      if (stage.kind == .final or stage.kind == .keyword) {
        const res = try Resolver.init(self, stage).resolveChain(node);
        switch (res) {
          .runtime => |*rc| {
            std.debug.assert(rc.indexes.items.len == 0);
            return rc.base;
          },
          .func_ref => |*fref| {
            std.debug.assert(fref.prefix == null);
            const expr = try self.ctx.createValueExpr(
              (try self.ctx.values.funcRef(node.pos, fref.target)).value());
            node.data = .{.expression = expr};
            return node;
          },
          .type_ref => |tref| {
            const expr = try self.ctx.createValueExpr(
              (try self.ctx.values.@"type"(node.pos, tref.*)).value());
            node.data = .{.expression = expr};
            return node;
          },
          .proto_ref => |pref| {
            const expr = try self.ctx.createValueExpr(
              (try self.ctx.value.prototype(node.pos, pref.*)).value());
            node.data = .{.expression = expr};
            return node;
          },
          .failed => return null,
          .poison => {
            node.data = .poison;
            return node;
          }
        }
      } else return null;
    },
    else => return node,
  }
}

fn tryInterpretOutput(
  self : *Interpreter,
  out  : *model.Node.Output,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  const schema = if (out.schema) |schema_node| blk: {
    const sexpr = (
      try self.associate(
        schema_node, self.ctx.types().schema().predef(), stage)
    ) orelse return null;
    switch ((try self.ctx.evaluator().evaluate(sexpr)).data) {
      .schema => |*sch| {
        sexpr.data = .{.value = sch.value()};
        schema_node.data = .{.expression = sexpr};
        break :blk sch;
      },
      .poison => {
        out.node().data = .poison;
        return null;
      },
      else => unreachable,
    }
  } else null;
  const root_type =
    if (schema) |schval| schval.root else self.ctx.types().text().predef();
  const expr = (
    try self.associate(out.body, root_type, stage)
  ) orelse return null;
  out.body.data = .{.expression = expr};
  const name_expr = (
    try self.associate(
      out.name, self.ctx.types().system.output_name.predef(), stage)
  ) orelse return null;
  if (name_expr.expected_type.isNamed(.poison)) {
    out.node().data = .poison;
    return null;
  }
  const out_expr = try self.ctx.global().create(model.Expression);
  out_expr.* = .{
    .pos = out.node().pos,
    .data = .{.output = .{
      .name   = name_expr,
      .schema = schema,
      .body   = expr,
    }},
    .expected_type = self.ctx.types().output(),
  };
  return out_expr;
}

fn tryInterpretRAccess(
  self : *Interpreter,
  racc : *model.Node.ResolvedAccess,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  std.debug.assert(racc.base != racc.node());
  const base = (try self.tryInterpret(racc.base, stage)) orelse return null;
  const res = try self.tryInterpretPath(base.expected_type, racc.path, stage);
  if (res == .unfinished) return null;

  const expr = try self.ctx.global().create(model.Expression);
  expr.* = switch (res) {
    .poison => .{
      .pos           = racc.node().pos,
      .data          = .poison,
      .expected_type = self.ctx.types().poison(),
    },
    .success => |s| .{
      .pos = racc.node().pos,
      .data = .{.access = .{
        .subject = base,
        .path    = s.path,
      }},
      .expected_type = s.t,
    },
    .unfinished => unreachable,
  };
  return expr;
}

pub fn locationsCanGenVars(
  self : *Interpreter,
  node : *model.Node,
  stage: Stage,
) nyarna.Error!bool {
  switch (node.data) {
    .location => |*loc| {
      if (
        try self.associate(
          loc.name, self.ctx.types().literal().predef(), stage)
      ) |nexpr| {
        loc.name.data = .{.expression = nexpr};
      } else return false;
      if (loc.@"type") |tnode| {
        if (
          try self.associate(
            tnode, self.ctx.types().@"type"().predef(), stage)
        ) |texpr| {
          tnode.data = .{.expression = texpr};
          return true;
        } else return false;
      } else {
        return (try self.probeType(loc.default.?, stage, false)) != null;
      }
    },
    .concat => |*con| {
      for (con.items) |item|
        if (!(try self.locationsCanGenVars(item, stage)))
          return false;
      return true;
    },
    else => if (
      try self.associate(node,
        (try self.ctx.types().concat(self.ctx.types().location())).?.predef(),
        stage)
    ) |expr| {
      node.data = .{.expression = expr};
      return true;
    } else return false,
  }
}

pub fn collectLocations(
  self     : *Interpreter,
  node     : *model.Node,
  collector: *std.ArrayList(model.locations.Ref),
) nyarna.Error!void {
  switch (node.data) {
    .location => |*loc| try collector.append(.{.node = loc}),
    .concat => |*con|
      for (con.items) |item| try self.collectLocations(item, collector),
    .void, .poison => {},
    else => {
      const value = try self.ctx.evaluator().evaluate(node.data.expression);
      switch (value.data) {
        .concat => |*con| {
          for (con.content.items) |item|
            try collector.append(.{.value = &item.data.location});
        },
        .poison => {},
        else => unreachable,
      }
    },
  }
}

pub fn tryInterpretLocationsList(
  self : *Interpreter,
  list : *model.locations.List(void),
  stage: Stage,
) !bool {
  switch (list.*) {
    .unresolved => |uc| {
      if (!(try self.locationsCanGenVars(uc, stage))) {
        return false;
      }
      var locs = std.ArrayList(model.locations.Ref).init(self.allocator());
      try self.collectLocations(uc, &locs);
      list.* = .{.resolved = .{.locations = locs.items}};
    },
    else => {},
  }
  return true;
}

pub fn variablesFromLocations(
  self     : *Interpreter,
  locs     : []model.locations.Ref,
  container: *model.VariableContainer,
) ![]*model.Symbol.Variable {
  var variables = try self.allocator().alloc(*model.Symbol.Variable, locs.len);
  var next: usize = 0;
  for (locs) |*loc, index| {
    var name: *model.Value.TextScalar = undefined;
    var loc_type: model.SpecType = undefined;
    var borrowed: bool = undefined;
    switch (loc.*) {
      .node => |nl| {
        switch (
          (try self.ctx.evaluator().evaluate(nl.name.data.expression)).data
        ) {
          .text   => |*txt| name = txt,
          .poison => {
            loc.* = .poison;
            continue;
          },
          else => unreachable,
        }
        if (nl.@"type") |lt| {
          switch (
            (try self.ctx.evaluator().evaluate(lt.data.expression)).data
          ) {
            .@"type" => |vt| loc_type = vt.t.at(lt.pos),
            .poison  => loc_type = self.ctx.types().poison().predef(),
            else     => unreachable,
          }
        } else {
          const probed = (
            try self.probeType(nl.default.?, .{.kind = .final}, false)
          ).?;
          loc_type = probed.at(nl.default.?.pos);
        }
        borrowed = if (nl.additionals) |a| a.borrow != null else false;
      },
      .expr => |expr| switch (expr.data) {
        .location => |*lexpr| {
          switch ((try self.ctx.evaluator().evaluate(lexpr.name)).data) {
            .text => |*txt| name = txt,
            .poison => {
              loc.* = .poison;
              continue;
            },
            else => unreachable,
          }
          if (lexpr.@"type") |texpr| switch (
            (try self.ctx.evaluator().evaluate(texpr)).data
          ) {
            .@"type" => |tv| loc_type = tv.t.at(texpr.pos),
            .poison  => loc_type = self.ctx.types().poison().predef(),
            else => unreachable,
          } else {
            loc_type = lexpr.default.?.expected_type.at(lexpr.default.?.pos);
          }
          borrowed = if (lexpr.additionals) |a| a.borrow != null else false;
        },
        else => switch ((try self.ctx.evaluator().evaluate(expr)).data) {
          .location => |*lval| {
            loc.* = .{.value = lval};
            name     = lval.name;
            loc_type = lval.spec;
            borrowed = lval.borrow != null;
          },
          .poison => {
            loc.* = .poison;
            continue;
          },
          else => unreachable,
        },
      },
      .value => |lval| {
        name     = lval.name;
        loc_type = lval.spec;
        borrowed = lval.borrow != null;
      },
      .poison => continue,
    }
    const sym = try self.ctx.global().create(model.Symbol);
    sym.* = .{
      .defined_at = name.value().origin,
      .name       = name.content,
      .data       = .{.variable = .{
        .spec       = loc_type,
        .container  = container,
        .offset     = container.num_values + @intCast(u15, index),
        .kind       = if (borrowed) .mutable else .given,
      }},
      .parent_type = null,
    };
    variables[next] = &sym.data.variable;
    next += 1;
  }
  container.num_values += @intCast(u15, next);
  return variables[0..next];
}

/// Tries to change func.params.unresolved to func.params.resolved.
/// returns true if that transition was successful. A return value of false
/// implies that there is at least one yet unresolved reference in the params.
///
/// On success, this function also resolves all unresolved references to the
/// variables in the function's body.
pub fn tryInterpretFuncParams(
  self : *Interpreter,
  func : *model.Node.Funcgen,
  stage: Stage,
) !bool {
  if (!(try self.locationsCanGenVars(func.params.unresolved, stage))) {
    return false;
  }
  var locs = std.ArrayList(model.locations.Ref).init(self.allocator());
  try self.collectLocations(func.params.unresolved, &locs);
  const variables =
    try self.variablesFromLocations(locs.items, func.variables);
  func.params = .{
    .resolved = .{.locations = locs.items},
  };

  // resolve references to arguments inside body.
  const mark = self.markSyms();
  defer self.resetSyms(mark);
  const ns = &self.namespaces.items[func.params_ns];
  for (variables) |v| _ = try ns.tryRegister(self, v.sym());
  try Resolver.init(self, .{.kind = .intermediate}).resolve(func.body);
  return true;
}

pub fn processLocations(
  self     : *Interpreter,
  locs     : *[]model.locations.Ref,
  stage    : Stage,
  collector: anytype,
) nyarna.Error!bool {
  var index: usize = 0;
  var failed_some = false;
  locsLoop: while (index < locs.len) {
    const loc = &locs.*[index];
    const lval = valueLoop: while (true) switch (loc.*) {
      .node => |nl| {
        const expr = (
          try self.tryInterpretLoc(nl, stage)
        ) orelse {
          failed_some = true;
          continue :locsLoop;
        };
        loc.* = .{.expr = expr};
      },
      .expr => |expr| switch (
        (try self.ctx.evaluator().evaluate(expr)).data
      ) {
        .location => |*locv| {
          loc.* = .{.value = locv};
          break :valueLoop locv;
        },
        .poison => {
          loc.* = .poison;
          continue :locsLoop;
        },
        else => unreachable,
      },
      .value  => |lval| break :valueLoop lval,
      .poison => continue :locsLoop,
    } else unreachable;
    try collector.push(lval);
    index += 1;
  }
  return !failed_some;
}

pub fn tryPregenFunc(
  self    : *Interpreter,
  func    : *model.Node.Funcgen,
  ret_type: model.Type,
  stage   : Stage,
) nyarna.Error!?*model.Function {
  switch (func.params) {
    .unresolved =>
      if (!try self.tryInterpretFuncParams(func, stage)) return null,
    .resolved => {},
    .pregen => |pregen| return pregen,
  }
  const params = &func.params.resolved;
  var finder = Types.CallableReprFinder.init(self.ctx.types());
  if (!(try self.processLocations(&params.locations, stage, &finder))) {
    return null;
  }
  const finder_res = try finder.finish(ret_type, false);
  var builder = try Types.SigBuilder.init(self.ctx, params.locations.len,
    ret_type, finder_res.needs_different_repr);
  for (params.locations) |loc| try builder.push(loc.value);
  const builder_res = builder.finish();

  const ret = try self.ctx.global().create(model.Function);
  ret.* = .{
    .callable   = try builder_res.createCallable(self.ctx.global(), .function),
    .name       = null,
    .defined_at = func.node().pos,
    .data = .{
      .ny = .{.body = undefined},
    },
    .variables = func.variables,
  };
  func.params = .{.pregen = ret};
  return ret;
}

pub fn tryInterpretFuncBody(
  self    : *Interpreter,
  func    : *model.Node.Funcgen,
  expected: ?model.SpecType,
  stage   : Stage,
) nyarna.Error!?*model.Expression {
  switch (func.body.data) {
    .expression => |expr| return expr,
    else => {},
  }

  const res = (
    if (expected) |spec| (
      try self.associate(func.body, spec, stage)
    ) else try self.tryInterpret(func.body, stage)
  ) orelse return null;
  func.body.data = .{.expression = res};
  return res;
}

pub fn tryInterpretFunc(
  self : *Interpreter,
  func : *model.Node.Funcgen,
  stage: Stage,
) nyarna.Error!?*model.Function {
  if (func.returns) |rnode| {
    const ret_val = try self.ctx.evaluator().evaluate(
      (try self.associate(rnode, self.ctx.types().@"type"().predef(),
        .{.kind = .final, .resolve_ctx = stage.resolve_ctx})).?);
    const returns = if (ret_val.data == .poison) (
      self.ctx.types().poison().predef()
    ) else ret_val.data.@"type".t.at(ret_val.origin);
    const ret = (
      try self.tryPregenFunc(func, returns.t, stage)
    ) orelse {
      // just for discovering potential dependencies during \declare
      // resolution.
      _ = try self.tryInterpretFuncBody(func, returns, stage);
      return null;
    };
    const ny = &ret.data.ny;
    ny.body = (
      try self.tryInterpretFuncBody(func, returns, stage)
    ) orelse return null;
    return ret;
  } else {
    var failed_parts = false;
    switch (func.params) {
      .unresolved => {
        if (!try self.tryInterpretFuncParams(func, stage)) {
          failed_parts = true;
        }
      },
      else => {},
    }
    const body_expr = (
      try self.tryInterpretFuncBody(func, null, stage)
    ) orelse return null;
    if (failed_parts) return null;
    const ret = (try self.tryPregenFunc(
      func, body_expr.expected_type, stage)).?;
    ret.data.ny.body = body_expr;
    return ret;
  }
}

pub const HighlighterContext = struct {
  ctx   : Resolver.Context,
  vname : []const u8,
  cur_t : model.Type,

  fn init(
    ns    : u15,
    vname : []const u8,
    t     : model.Type,
    parent: ?*Resolver.Context,
  ) @This() {
    return .{
      .ctx = .{
        .resolveNameFn = resolveVar,
        .target        = .{.ns = ns},
        .parent        = parent
      },
      .vname = vname,
      .cur_t = t,
    };
  }

  fn resolveVar(
    ctx : *Resolver.Context,
    name: []const u8,
    _   : model.Position,
  ) nyarna.Error!Resolver.Context.Result {
    const self = @fieldParentPtr(HighlighterContext, "ctx", ctx);
    if (std.mem.eql(u8, name, self.vname)) {
      return Resolver.Context.Result{
        .unfinished_variable = self.cur_t,
      };
    } else return Resolver.Context.Result.unknown;
  }
};

fn probeRenderer(
  self    : *Interpreter,
  renderer: *model.Node.Highlighter.Renderer,
  stage   : Stage,
  ret     : model.Type,
) nyarna.Error!?model.Type {
  var hlctx: HighlighterContext = undefined;
  var inner_stage = stage;
  if (renderer.variable) |v| {
    hlctx = HighlighterContext.init(v.ns, v.name, ret, stage.resolve_ctx);
    inner_stage.resolve_ctx = &hlctx.ctx;
  }
  const probed = try self.probeType(renderer.content, inner_stage, false);
  if (probed == null and stage.kind == .final) {
    // generate errors from unresolved symbols
    _ = try self.tryInterpret(renderer.content, inner_stage);
  }
  return probed;
}

pub fn tryInterpretHighlighter(
  self : *Interpreter,
  hl   : *model.Node.Highlighter,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  // we'll do a fixpoint iteration to determine the return type which will also
  // be the type of the processor variables.
  var res = self.ctx.types().system.text;
  var seen_unfinished = false;
  var seen_poison = false;
  var iter: usize = 0; while (
    iter == 0 or (iter == 1 and !seen_unfinished and !seen_poison)
  ) : (iter += 1) {
    for (hl.renderers) |*renderer, i| {
      const rt = (try self.probeRenderer(renderer, stage, res)) orelse {
        seen_unfinished = true;
        continue;
      };
      if (rt.isNamed(.poison)) {
        seen_poison = true;
        continue;
      }
      const new = try self.ctx.types().sup(res, rt);
      if (new.isNamed(.poison)) {
        seen_poison = true;
        const found = for (hl.renderers[0..i]) |*prev| {
          const prev_t = (
            try self.probeRenderer(prev, stage, res)
          ) orelse continue;
          if (prev_t.isNamed(.poison)) continue;
          if ((try self.ctx.types().sup(rt, prev_t)).isNamed(.poison)) {
            self.ctx.logger.IncompatibleTypes(&.{
              rt.at(renderer.content.pos), prev_t.at(prev.content.pos),
            });
            break true;
          }
        } else false;
        if (!found) {
          const pos = hl.renderers[0].content.pos.span(
            hl.renderers[i - 1].content.pos);
          self.ctx.logger.IncompatibleTypes(&.{
            rt.at(renderer.content.pos), res.at(pos),
          });
        }
        continue;
      }
      const cnew = (
        try self.ctx.types().concat(new)
      ) orelse {
        self.ctx.logger.InvalidInnerConcatType(
          &.{new.at(renderer.content.pos)});
        continue;
      };
      res = cnew;
    }
  }

  if (seen_unfinished) return null;
  if (seen_poison) {
    const node = hl.node();
    node.data = .poison;
    return null;
  }

  const expr = (
    try self.associate(
      hl.syntax, self.ctx.types().system.identifier.predef(), stage)
  ) orelse return null;
  const val = try self.ctx.evaluator().evaluate(expr);
  const syntax = switch (val.data) {
    .text => |*txt| blk: {
      if (std.mem.eql(u8, txt.content, "nyarna")) {
        break :blk &self.ctx.data.nyarna_syntax.syntax;
      } else {
        self.ctx.logger.UnknownSyntax(val.origin, txt.content);
        const node = hl.node();
        node.data = .poison;
        return null;
      }
    },
    .poison => {
      const node = hl.node();
      node.data = .poison;
      return null;
    },
    else => unreachable,
  };

  const container = try self.ctx.global().create(model.VariableContainer);
  container.* = .{.num_values = 3};
  const processors = try self.ctx.global().alloc(
    *model.Expression, syntax.tokens.len);

  for (hl.renderers) |renderer| {
    const index = for (syntax.tokens) |token, i| {
      if (std.mem.eql(u8, token, renderer.name.content)) break i;
    } else {
      self.ctx.logger.UnknownSyntaxToken(
        renderer.name.node().pos, renderer.name.content);
      continue;
    };

    if (renderer.variable) |v| {
      const sym = try self.ctx.global().create(model.Symbol);
      sym.* = .{
        .defined_at = v.pos,
        .name       = v.name,
        .data       = .{.variable = .{
          .spec       = res.at(v.pos),
          .container  = container,
          .offset     = 0,
          .kind       = .given,
        }},
        .parent_type = null,
      };
      const mark = self.markSyms();
      if (try self.namespace(v.ns).tryRegister(self, sym)) {
        try Resolver.init(self, .{.kind = .intermediate}).resolve(
          renderer.content);
        self.resetSyms(mark);
      }
    }

    processors[index] = (
      try self.associate(
        renderer.content, res.at(hl.node().pos), .{.kind = .final})
    ) orelse {
      seen_poison = true;
      continue;
    };
  }

  for (syntax.tokens) |token| {
    for (hl.renderers) |renderer| {
      if (std.mem.eql(u8, renderer.name.content, token)) break;
    } else {
      self.ctx.logger.MissingTokenHandler(hl.node().pos, token);
      seen_poison = true;
    }
  }

  if (seen_poison) {
    const node = hl.node();
    node.data = .poison;
    return null;
  }

  const opt_text =
    (try self.ctx.types().optional(self.ctx.types().system.text)).?;
  var finder = Types.CallableReprFinder.init(self.ctx.types());
  try finder.pushType(opt_text, "before");
  try finder.pushType(self.ctx.types().system.text, "code");
  const finder_res = try finder.finish(res, false);
  var builder = try Types.SigBuilder.init(
    self.ctx, 2, res, finder_res.needs_different_repr);
  try builder.pushUnwrapped(
    model.Position.intrinsic(), "before", opt_text.predef());
  try builder.pushUnwrapped(
    model.Position.intrinsic(), "code", self.ctx.types().system.text.predef());
  builder.val.primary = 1;
  const builder_res = builder.finish();
  const func = try self.ctx.global().create(model.Function);
  func.* = .{
    .callable   = try builder_res.createCallable(self.ctx.global(), .function),
    .name       = null,
    .data       = .{.hl = .{
      .syntax     = syntax,
      .processors = processors,
    }},
    .defined_at = hl.node().pos,
    .variables  = container,
  };

  return try self.ctx.createValueExpr(
    (try self.ctx.values.funcRef(hl.node().pos, func)).value()
  );
}

/// never creates an Expression because builtins may only occur as node in a
/// definition, where they are handled directly. Returns true iff all
/// components have been resolved. Issues error if called in .keyword or
/// .final stage because that implies it is used outside of a definition.
pub fn tryInterpretBuiltin(
  self : *Interpreter,
  bg   : *model.Node.BuiltinGen,
  stage: Stage,
) nyarna.Error!bool {
  switch (bg.returns) {
    .expr => {},
    .node => |rnode| {
      const expr = (
        try self.associate(rnode, self.ctx.types().@"type"().predef(), stage)
      ) orelse return false;
      bg.returns = .{.expr = expr};
    }
  }

  if (!(try self.tryInterpretLocationsList(&bg.params, stage))) return false;
  switch(stage.kind) {
    .keyword, .final => self.ctx.logger.BuiltinMustBeNamed(bg.node().pos),
    else => {}
  }
  return true;
}

pub fn interpretCallToChain(
  self     : *Interpreter,
  uc       : *model.Node.UnresolvedCall,
  chain_res: Resolver.Chain,
  stage    : Stage,
) nyarna.Error!?*model.Expression {
  const call_ctx =
    try Resolver.CallContext.fromChain(self, uc.target, chain_res);
  switch (call_ctx) {
    .known => |k| {
      var sm = try Parser.Mapper.ToSignature.init(
        self, k.target, k.ns, k.signature);
      if (k.first_arg) |prefix| {
        if (try sm.mapper.map(prefix.pos, .position, .flow)) |cursor| {
          try sm.mapper.push(cursor, prefix);
        }
      }
      for (uc.proto_args) |*arg, index| {
        const flag: Parser.Mapper.ProtoArgFlag = flag: {
          if (index < uc.first_block_arg) break :flag .flow;
          if (arg.had_explicit_block_config) break :flag .block_with_config;
          break :flag .block_no_config;
        };
        if (try sm.mapper.map(arg.content.pos, arg.kind, flag)) |cursor| {
          if (flag == .block_no_config and sm.mapper.config(cursor) != null) {
            self.ctx.logger.BlockNeedsConfig(arg.content.pos);
          }
          try sm.mapper.push(cursor, arg.content);
        }
      }
      const input = uc.node();
      const res = try sm.mapper.finalize(input.pos);
      input.* = res.*;
      return try self.tryInterpret(input, stage);
    },
    .unknown => return null,
    .poison  => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(uc.node().pos)),
  }
}

const CheckResult = enum {
  success, unfinished, poison,
};

/// interprets the type expressions for the cases. If capture variables are
/// declared, creates them and resolves references to them inside the body.
pub fn ensureMatchTypesPresent(
  self : *Interpreter,
  cases: []model.Node.Match.Case,
  stage: Stage,
) nyarna.Error!CheckResult {
  var res: CheckResult = .success;
  for (cases) |*case| {
    const t = if (
      try self.associate(case.t, self.ctx.types().@"type"().predef(), stage)
    ) |expr| blk: {
      case.t.data = .{.expression = expr};
      const value = try self.ctx.evaluator().evaluate(expr);
      expr.data = .{.value = value};
      expr.expected_type = try self.ctx.types().valueType(value);
      switch (value.data) {
        .@"type" => |tv| break :blk tv.t.at(value.origin),
        .poison => {
          res = .poison;
          continue;
        },
        else => unreachable,
      }
    } else {
      res = .unfinished;
      continue;
    };

    switch (case.variable) {
      .def => |val| {
        const sym = try self.ctx.global().create(model.Symbol);
        sym.* = .{
          .defined_at = val.pos,
          .name       = try self.ctx.global().dupe(u8, val.name),
          .data       = .{.variable = .{
            .spec       = t,
            .container  = case.content.container.?,
            .offset     = case.content.container.?.num_values,
            .kind       = .given,
          }},
        };
        case.variable = .{.sym = &sym.data.variable};
        const ns = self.namespace(val.ns);
        const mark = self.markSyms();
        defer self.resetSyms(mark);
        if (try ns.tryRegister(self, sym)) {
          try Resolver.init(self, .{.kind = .intermediate}).resolve(
            case.content.root);
        }
      },
      .sym, .none  => {},
    }
  }
  return res;
}

fn tryInterpretMatchCases(
  self : *Interpreter,
  match: *model.Node.Match,
  stage: Stage,
  builder: *MatchBuilder,
) nyarna.Error!CheckResult {
  var res = try self.ensureMatchTypesPresent(match.cases, stage);
  switch (res) {
    .unfinished, .poison => return res,
    .success => {
      for (match.cases) |case| {
        if (try self.tryInterpret(case.content.root, stage)) |content_expr| {
          case.content.root.data = .{.expression = content_expr};
          if (content_expr.expected_type.isNamed(.poison)) res = .poison;
        } else if (res != .poison) res = .unfinished;
      }
    },
  }

  if (res != .success) return res;

  for (match.cases) |case| {
    const has_var = case.content.capture.len > 0;
    try builder.push(
      &case.t.data.expression.data.value.data.@"type".t,
      case.t.pos,
      case.content.root.data.expression,
      case.content.container.?,
      has_var,
    );
  }
  return CheckResult.success;
}

fn tryInterpretMatch(
  self : *Interpreter,
  match: *model.Node.Match,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var builder = try MatchBuilder.init(self, match.node().pos, match.cases.len);
  switch (try self.tryInterpretMatchCases(match, stage, &builder)) {
    .poison => {
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos = match.node().pos,
        .data = .poison,
        .expected_type = self.ctx.types().poison(),
      };
      return expr;
    },
    .unfinished => return null,
    else        => {}
  }
  if (
    try self.associate(
      match.subject,
      (try builder.checker.finish(&builder.builder)).at(match.node().pos),
      stage)
  ) |expr| {
    return try builder.finalize(expr);
  } else return null;
}

pub fn tryPregenMatcherFunc(
  self    : *Interpreter,
  matcher : *model.Node.Matcher,
  ret_type: model.Type,
  stage   : Stage,
) !?*model.Function {
  if (matcher.pregen) |pregen| return pregen;
  if (
    (try self.ensureMatchTypesPresent(matcher.body.cases, stage)) == .success
  ) {
    const input_type = blk: {
      var builder = try Types.IntersectionBuilder.init(
        matcher.body.cases.len, self.allocator());
      var checker = IntersectionChecker.init(self, true);
      var seen_failed = false;
      for (matcher.body.cases) |case| {
        const val = case.t.data.expression.data.value;
        if (!(try checker.push(&builder, &val.data.@"type".t, val.origin))) {
          seen_failed = true;
        }
      }
      break :blk if (seen_failed) (
        self.ctx.types().poison()
      ) else try checker.finish(&builder);
    };
    matcher.variable.spec = input_type.at(matcher.node().pos);

    var finder = Types.CallableReprFinder.init(self.ctx.types());
    try finder.pushType(input_type, matcher.variable.sym().name);
    const finder_res = try finder.finish(ret_type, false);
    var builder = try Types.SigBuilder.init(
      self.ctx, 1, ret_type, finder_res.needs_different_repr);
    try builder.pushUnwrapped(
      matcher.node().pos, matcher.variable.sym().name, matcher.variable.spec);
    const builder_res = builder.finish();

    const ret = try self.ctx.global().create(model.Function);
    ret.* = .{
      .callable   =
        try builder_res.createCallable(self.ctx.global(), .function),
      .name       = null,
      .defined_at = matcher.node().pos,
      .data       = .{.ny = undefined},
      .variables  = matcher.container,
    };
    matcher.pregen = ret;
    return ret;
  } else return null;
}

pub fn tryInterpretMatcher(
  self   : *Interpreter,
  matcher: *model.Node.Matcher,
  stage  : Stage,
) nyarna.Error!?*model.Function {
  const pregen_func = if (matcher.pregen) |pregen| pregen else (
    if (try self.probeType(matcher.body.node(), stage, false)) |ret_type| (
      if (ret_type.isNamed(.poison)) {
        matcher.node().data = .poison;
        return null;
      } else (
        try self.tryPregenMatcherFunc(matcher, ret_type, stage)
      ) orelse return null
    ) else return null
  );

  var mb = try MatchBuilder.init(
    self, matcher.body.node().pos, matcher.body.cases.len);
  const match_expr = switch (
    try self.tryInterpretMatchCases(matcher.body, stage, &mb)
  ) {
    .poison => blk: {
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos = matcher.node().pos,
        .data = .poison,
        .expected_type = self.ctx.types().poison(),
      };
      break :blk expr;
    },
    .unfinished => return null,
    else        => if (
      try self.associate(matcher.body.subject, matcher.variable.spec, stage)
    ) |expr| (
      try mb.finalize(expr)
    ) else return null,
  };

  pregen_func.data.ny.body = match_expr;
  return pregen_func;
}

fn tryInterpretUCall(
  self : *Interpreter,
  uc   : *model.Node.UnresolvedCall,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  const resolver = Resolver.init(self, stage);
  var res = try resolver.resolveChain(uc.target);
  if (
    try resolver.trySubscript(&res, uc.proto_args, uc.node().pos)
  ) |subscr| {
    const node = uc.node();
    const rc = &subscr.runtime; // always a runtime chain
    node.data = .{.resolved_access = .{
      .base = rc.base,
      .path = rc.indexes.items,
      .last_name_pos = rc.last_name_pos,
      .ns = rc.ns,
    }};
    return self.tryInterpretRAccess(&node.data.resolved_access, stage);
  } else return self.interpretCallToChain(uc, res, stage);
}

fn tryInterpretVarargs(
  self : *Interpreter,
  va   : *model.Node.Varargs,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var seen_poison = false;
  var seen_unfinished = false;
  for (va.content.items) |item| {
    const t = if (item.direct) va.t.typedef() else va.t.inner;
    if (
      try self.associate(item.node, .{.t = t, .pos = va.spec_pos}, stage)
    ) |expr| {
      if (expr.expected_type.isNamed(.poison)) seen_poison = true;
      item.node.data = .{.expression = expr};
    } else seen_unfinished = true;
  }
  if (seen_unfinished) {
    return if (stage.kind == .keyword or stage.kind == .final)
      try self.ctx.createValueExpr(
        try self.ctx.values.poison(va.node().pos))
    else null;
  } else if (seen_poison) {
    return try self.ctx.createValueExpr(
      try self.ctx.values.poison(va.node().pos));
  }
  const items = try self.ctx.global().alloc(
    model.Expression.Varargs.Item, va.content.items.len);
  for (va.content.items) |item, index| {
    items[index] =
      .{.direct = item.direct, .expr = item.node.data.expression};
  }

  const vexpr = try self.ctx.global().create(model.Expression);
  vexpr.* = .{
    .pos  = va.node().pos,
    .data = .{.varargs = .{
      .items = items,
    }},
    .expected_type = va.t.typedef(),
  };
  return vexpr;
}

fn tryInterpretVarmap(
  self : *Interpreter,
  vm   : *model.Node.Varmap,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var seen_poison = false;
  var seen_unfinished = false;
  for (vm.content.items) |item| {
    switch (item.key) {
      .node => |node| {
        if (
          try self.associate(node, .{.t = vm.t.key, .pos = vm.spec_pos}, stage)
        ) |expr| {
          if (expr.expected_type.isNamed(.poison)) seen_poison = true;
          node.data = .{.expression = expr};
        } else seen_unfinished = true;
        if (
          try self.associate(
            item.value, .{.t = vm.t.value, .pos = vm.spec_pos}, stage)
        ) |expr| {
          if (expr.expected_type.isNamed(.poison)) seen_poison = true;
          item.value.data = .{.expression = expr};
        } else seen_unfinished = true;
      },
      .direct => {
        if (
          try self.associate(
            item.value, .{.t = vm.t.typedef(), .pos = vm.spec_pos}, stage)
        ) |expr| {
          if (expr.expected_type.isNamed(.poison)) seen_poison = true;
          item.value.data = .{.expression = expr};
        } else seen_unfinished = true;
      }
    }
  }
  if (seen_unfinished) {
    return if (stage.kind == .keyword or stage.kind == .final)
      try self.ctx.createValueExpr(
        try self.ctx.values.poison(vm.node().pos))
    else null;
  } else if (seen_poison) {
    return try self.ctx.createValueExpr(
      try self.ctx.values.poison(vm.node().pos));
  }
  const items = try self.ctx.global().alloc(
    model.Expression.Varmap.Item, vm.content.items.len);
  for (vm.content.items) |item, index| {
    items[index] = switch (item.key) {
      .node => |key_node| .{
        .key   = .{.expr = key_node.data.expression},
        .value = item.value.data.expression,
      },
      .direct => .{.key = .direct, .value = item.value.data.expression},
    };
  }

  const vexpr = try self.ctx.global().create(model.Expression);
  vexpr.* = .{
    .pos  = vm.node().pos,
    .data = .{.varmap = .{
      .items = items,
    }},
    .expected_type = vm.t.typedef(),
  };
  return vexpr;
}

fn tryInterpretVarTypeSetter(
  self : *Interpreter,
  vs   : *model.Node.VarTypeSetter,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  if (try self.tryInterpret(vs.content, stage)) |expr| {
    vs.v.spec = expr.expected_type.at(expr.pos);
    return expr;
  } else return null;
}

const TypeResult = union(enum) {
  finished  : model.Type,
  unfinished: model.Type,
  expression: *model.Expression,
  unavailable, failed,
};

fn tryGetType(
  self : *Interpreter,
  node : *model.Node,
  stage: Stage,
) !TypeResult {
  while (true) switch (node.data) {
    .unresolved_symref => |*usym| {
      if (stage.resolve_ctx) |ctx| {
        switch (try ctx.resolveSymbol(self, usym)) {
          .node => |repl| {
            node.data = repl.data;
            continue;
          },
          .unfinished_function => {
            self.ctx.logger.CantCallUnfinished(node.pos);
            return TypeResult.failed;
          },
          .unfinished_variable => |t| return TypeResult{.unfinished = t},
          .unfinished_type => |t| return TypeResult{.unfinished = t},
          .unknown => if (stage.kind == .keyword or stage.kind == .final) {
            self.ctx.logger.UnknownSymbol(node.pos, usym.name);
            node.data = .poison;
            return TypeResult.failed;
          } else return TypeResult.unavailable,
          .poison => {
            node.data = .poison;
            return TypeResult.failed;
          },
          .variable => |v| {
            if (
              self.ctx.types().lesserEqual(
                v.spec.t, self.ctx.types().@"type"())
            ) {
              const expr = try self.ctx.global().create(model.Expression);
              expr.* = .{
                .pos  = node.pos,
                .data = .{.var_retrieval = .{
                  .variable = v,
                }},
                .expected_type = self.ctx.types().@"type"(),
              };
              return TypeResult{.expression = expr};
            } else {
              self.ctx.logger.ExpectedExprOfTypeXGotY(&.{
                v.spec, self.ctx.types().@"type"().predef(),
              });
              return TypeResult.failed;
            }
          },
        }
      } else if (
        try self.associate(node, self.ctx.types().@"type"().predef(), stage)
      ) |expr| {
        return TypeResult{.expression = expr};
      } else return TypeResult.unavailable;
    },
    .expression => |expr| return TypeResult{.expression = expr},
    else => if (
      try self.associate(node, self.ctx.types().@"type"().predef(), stage)
    ) |expr| {
      return TypeResult{.expression = expr};
    } else return TypeResult.unavailable,
  };
}

/// try to generate a structural type with one inner type.
fn tryGenUnary(
           self         : *Interpreter,
  comptime name         : []const u8,
  comptime register_name: []const u8,
  comptime error_name   : []const u8,
           input        : anytype,
           stage        : Stage,
) nyarna.Error!?*model.Expression {
  const inner = switch (try self.tryGetType(input.inner, stage)) {
    .finished   => |t| t,
    .unfinished => |t| t,
    .expression => |expr| blk: {
      switch (expr.data) {
        .value => |val| switch (val.data) {
          .@"type" => |*tv| break :blk tv.t,
          .poison  => return try self.ctx.createValueExpr(
            try self.ctx.values.poison(input.node().pos)),
          else => unreachable,
        },
        else => {
          const ret = try self.ctx.global().create(model.Expression);
          ret.* = .{
            .pos  = input.node().pos,
            .data = @unionInit(model.Expression.Data, "tg_" ++ name, .{
              .inner = expr,
            }),
            .expected_type = self.ctx.types().@"type"(),
          };
          return ret;
        }
      }
    },
    .unavailable => return null,
    .failed      => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(input.node().pos)),
  };
  const ret: *model.Value = if (input.generated) |target| blk: {
    target.* = @unionInit(model.Type.Structural, name, .{.inner = inner});
    if (try @field(self.ctx.types(), register_name)(
        &@field(target.*, name))) {
      const t = model.Type{.structural = target};
      break :blk (try self.ctx.values.@"type"(input.node().pos, t)).value();
    } else {
      @field(self.ctx.logger, error_name)(
        &[_]model.SpecType{inner.at(input.inner.pos)});
      break :blk try self.ctx.values.poison(input.node().pos);
    }
  } else try self.ctx.unaryTypeVal(
    name, input.node().pos, inner, input.inner.pos, error_name);
  return try self.ctx.createValueExpr(ret);
}

fn tryGenConcat(
  self : *Interpreter,
  gc   : *model.Node.tg.Concat,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  return self.tryGenUnary(
    "concat", "registerConcat", "InvalidInnerConcatType", gc, stage);
}

fn tryGenEnum(
  self : *Interpreter,
  ge   : *model.Node.tg.Enum,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  // bootstrapping for system.ny
  const no_identifier =
    std.mem.eql(u8, ".std.system", ge.node().pos.source.locator.repr);

  var result = try self.tryProcessVarargs(
    ge.values, if (no_identifier) (
      self.ctx.types().literal()
    ) else self.ctx.types().system.identifier, stage);

  var builder = try Types.EnumBuilder.init(self.ctx, ge.node().pos);

  for (ge.values) |item| {
    if (item.direct) {
      switch (item.node.data.expression.data.value.data) {
        .poison => {},
        .list => |*list| for (list.content.items) |child| {
          try builder.add(child.data.text.content, child.origin);
        },
        else => unreachable,
      }
    } else {
      const expr = (
        try self.associate(
          item.node, self.ctx.types().literal().predef(), stage)
      ) orelse {
        if (result.kind != .poison) result.kind = .failed;
        continue;
      };
      const value = try self.ctx.evaluator().evaluate(expr);
      switch (value.data) {
        .poison => result.kind = .poison,
        .text => |*text| try builder.add(text.content, value.origin),
        else => unreachable,
      }
      expr.data = .{.value = value};
      item.node.data = .{.expression = expr};
    }
  }
  switch (result.kind) {
    .poison  => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(ge.node().pos)),
    .failed  => return null,
    .success => {
      const t = builder.finish().typedef();
      return try self.ctx.createValueExpr(
        (try self.ctx.values.@"type"(ge.node().pos, t)).value());
    },
  }
}

const VarargsProcessResult = struct {
  const Kind = enum{success, failed, poison};
  kind: Kind,
  /// the maximum number of value that can be produced. Sum of the number of
  /// children in direct items that can be interpreted, plus number of
  /// non-direct items.
  max: usize,
};

fn tryProcessVarargs(
  self      : *Interpreter,
  items     : []model.Node.Varargs.Item,
  inner_type: model.Type,
  stage     : Stage,
) nyarna.Error!VarargsProcessResult {
  const list_type = (try self.ctx.types().list(inner_type)).?;
  var failed_some = false;
  var poison = false;
  var count: usize = 0;
  for (items) |item| {
    if (item.direct) {
      const expr = (
        try self.associate(item.node, list_type.predef(), stage)
      ) orelse {
        failed_some = true;
        continue;
      };
      const value = try self.ctx.evaluator().evaluate(expr);
      switch (value.data) {
        .poison => poison = true,
        .list => |*list| count += list.content.items.len,
        else => unreachable,
      }
      expr.data = .{.value = value};
      item.node.data = .{.expression = expr};
    } else count += 1;
  }
  return VarargsProcessResult{
    .max = count,
    .kind = if (poison) (
      VarargsProcessResult.Kind.poison
    ) else if (failed_some) (
      VarargsProcessResult.Kind.failed
    ) else .success,
  };
}

fn tryGenIntersection(
  self : *Interpreter,
  gi   : *model.Node.tg.Intersection,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var result =
    try self.tryProcessVarargs(gi.types, self.ctx.types().@"type"(), stage);

  var builder = try Types.IntersectionBuilder.init(
    result.max + 1, self.allocator());
  var checker = IntersectionChecker.init(self, false);

  for (gi.types) |item| {
    if (item.direct) {
      const val = item.node.data.expression.data.value;
      switch (val.data) {
        .list => |*list| {
          for (list.content.items) |list_item| {
            _ = try checker.push(
              &builder, &list_item.data.@"type".t, list_item.origin);
          }
        },
        .poison => result.kind = .poison,
        else => unreachable,
      }
    } else {
      const inner = switch (try self.tryGetType(item.node, stage)) {
        .finished   => |t| t,
        .unfinished => |t| t,
        .expression => |expr| switch (
          (try self.ctx.evaluator().evaluate(expr)).data
        ) {
          .@"type" => |*tv| blk: {
            expr.data = .{.value = tv.value()};
            item.node.data = .{.expression = expr};
            break :blk tv.t;
          },
          .poison => {
            if (result.kind != .poison) result.kind = .failed;
            continue;
          },
          else => unreachable,
        },
        .unavailable => {
          if (result.kind != .poison) result.kind = .failed;
          continue;
        },
        .failed => {
          result.kind = .poison;
          continue;
        },
      };

      // needed because inner goes out of scope
      const inner_alloc = try self.allocator().create(model.Type);
      inner_alloc.* = inner;
      _ = try checker.push(&builder, inner_alloc, item.node.pos);
    }
  }
  switch (result.kind) {
    .poison  => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(gi.node().pos)),
    .failed  => return null,
    .success => {
      if (checker.scalar) |*found_scalar| {
        builder.push(@ptrCast([*]const model.Type, &found_scalar.t)[0..1]);
      }
      const t = try builder.finish(self.ctx.types());
      return try self.ctx.createValueExpr(
        (try self.ctx.values.@"type"(gi.node().pos, t)).value());
    }
  }
}

fn tryGenList(
  self : *Interpreter,
  gl   : *model.Node.tg.List,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  return self.tryGenUnary(
    "list", "registerList", "InvalidInnerListType", gl, stage);
}

fn tryGenMap(
  self : *Interpreter,
  gm   : *model.Node.tg.HashMap,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var inner_t: [2]model.SpecType = undefined;
  var inner_e = [2]?*model.Expression{null, null};
  var seen_poison = false;
  var seen_unfinished = false;
  var seen_expr = false;
  for ([_]*model.Node{gm.key, gm.value}) |item, index| {
    inner_t[index] = switch (try self.tryGetType(item, stage)) {
      .finished, .unfinished => |t| t.at(item.pos),
      .expression => |expr| blk: {
        inner_e[index] = expr;
        switch (expr.data) {
          .value => |val| switch (val.data) {
            .@"type" => |tv| break :blk tv.t.at(item.pos),
            .poison  => {
              seen_poison = true;
              continue;
            },
            else => unreachable,
          },
          else => {
            seen_expr = true;
            continue;
          },
        }
      },
      .unavailable => {
        seen_unfinished = true;
        continue;
      },
      .failed => {
        seen_poison = true;
        continue;
      }
    };
  }
  if (seen_poison) {
    return try self.ctx.createValueExpr(
      try self.ctx.values.poison(gm.node().pos));
  } else if (seen_unfinished) return null;

  if (seen_expr) {
    for (inner_e) |*target, index| {
      if (target.* == null) target.* = try self.ctx.createValueExpr((
          try self.ctx.values.@"type"(inner_t[index].pos, inner_t[index].t)
      ).value());
    }
    const expr = try self.ctx.global().create(model.Expression);
    expr.* = .{
      .pos  = gm.node().pos,
      .data = .{.tg_map = .{
        .key   = inner_e[0].?,
        .value = inner_e[1].?,
      }},
      .expected_type = self.ctx.types().@"type"(),
    };
    return expr;
  }

  const ret = if (gm.generated) |target| blk: {
    target.* = .{.hashmap = .{
      .key   = inner_t[0].t,
      .value = inner_t[1].t,
    }};
    if (try self.ctx.types().registerHashMap(&target.hashmap)) {
      break :blk (
        try self.ctx.values.@"type"(gm.node().pos, target.typedef())
      ).value();
    } else {
      self.ctx.logger.InvalidMappingKeyType(inner_t[0..1]);
      break :blk try self.ctx.values.poison(gm.node().pos);
    }
  } else if (try self.ctx.types().hashMap(inner_t[0].t, inner_t[1].t)) |t|
    (try self.ctx.values.@"type"(gm.node().pos, t)).value()
  else blk: {
    self.ctx.logger.InvalidMappingKeyType(inner_t[0..1]);
    break :blk try self.ctx.values.poison(gm.node().pos);
  };
  return try self.ctx.createValueExpr(ret);
}

fn doGenNumeric(
  self   : *Interpreter,
  builder: anytype,
  gn     : *model.Node.tg.Numeric,
  stage  : Stage,
) nyarna.Error!?*model.Expression {
  var seen_poison = false;
  var seen_unfinished = false;
  var iter = gn.suffixes.items.iterator();
  while (iter.next()) |entry| {
    const value = switch (entry.value_ptr.*.data) {
      .ast => |*ast| blk: {
        const expr = (try self.associate(
          ast.root, self.ctx.types().literal().predef(), stage)
        ) orelse {
          seen_unfinished = true;
          continue;
        };
        const val = try self.ctx.evaluator().evaluate(expr);
        entry.value_ptr.* = val;
        break :blk val;
      },
      else => entry.value_ptr.*,
    };
    switch (value.data) {
      .text => |*text| switch (
        Parser.LiteralNumber.from(text.content)
      ) {
        .too_large => {
          self.ctx.logger.NumberTooLarge(value.origin, text.content);
          value.data = .poison;
        },
        .invalid => {
          self.ctx.logger.InvalidNumber(value.origin, text.content);
          value.data = .poison;
        },
        .success => |num| try builder.unit(
          value.origin, num, entry.key_ptr.*.data.text.content),
      },
      .poison => {
        seen_poison = true;
      },
      else => unreachable,
    }
  }
  for ([_]?*model.Node{gn.min, gn.max}) |e, index| if (e) |item| {
    if (
      try self.associate(
        item, self.ctx.types().literal().predef(), stage)
    ) |expr| {
      item.data = .{.expression = expr};
      const value = try self.ctx.evaluator().evaluate(expr);
      switch (value.data) {
        .poison => seen_poison = true,
        .text => |*txt| switch (Parser.LiteralNumber.from(txt.content)) {
          .invalid => {
            self.ctx.logger.InvalidNumber(expr.pos, txt.content);
            seen_poison = true;
          },
          .too_large => {
            self.ctx.logger.NumberTooLarge(expr.pos, txt.content);
            seen_poison = true;
          },
          .success => |parsed| switch (index) {
            0 => builder.min(parsed, expr.pos),
            1 => builder.max(parsed, expr.pos),
            else => unreachable,
          },
        },
        else => unreachable,
      }
    } else seen_unfinished = true;
  };

  if (seen_unfinished) {
    builder.abort();
    return null;
  }
  const ret: ?@TypeOf(builder.ret) = if (seen_poison) blk: {
    builder.abort();
    break :blk null;
  } else builder.finish();
  if (ret) |numeric| {
    return try self.ctx.createValueExpr((try self.ctx.values.@"type"(
      gn.node().pos, numeric.typedef())).value());
  } else return try self.ctx.createValueExpr(
    try self.ctx.values.poison(gn.node().pos));
}

fn tryGenNumeric(
  self : *Interpreter,
  gn   : *model.Node.tg.Numeric,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  // bootstrapping for system.ny
  const needs_local_impl_enum =
    std.mem.eql(u8, ".std.system", gn.node().pos.source.locator.repr);

  var is_int = if (needs_local_impl_enum) blk: {
    const val = try self.ctx.evaluator().evaluate(
      try self.interpret(gn.backend));
    switch (val.data) {
      .text => |*txt| {
        if (std.mem.eql(u8, txt.content, "int")) break :blk true;
        if (std.mem.eql(u8, txt.content, "float")) break :blk false;
        self.ctx.logger.UnknownSymbol(val.origin, txt.content);
        return try self.ctx.createValueExpr(
          try self.ctx.values.poison(gn.node().pos));
      },
      .poison => return try self.ctx.createValueExpr(
        try self.ctx.values.poison(gn.node().pos)),
      else => unreachable,
    }
  } else if (
    try self.associate(
      gn.backend, self.ctx.types().system.numeric_impl.predef(), stage)
  ) |backend| switch ((try self.ctx.evaluator().evaluate(backend)).data) {
    .@"enum" => |*backend_val| switch (backend_val.index) {
      0 => true,
      1 => false,
      else => unreachable,
    },
    .poison => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(gn.node().pos)),
    else => unreachable,
  } else return null;

  if (is_int) {
    var ib = try Types.IntNumBuilder.init(
      self.ctx, self.allocator(), gn.node().pos);
    return try self.doGenNumeric(&ib, gn, stage);
  } else {
    var fb = try Types.FloatNumBuilder.init(
      self.ctx, self.allocator(), gn.node().pos);
    return try self.doGenNumeric(&fb, gn, stage);
  }
}

fn tryGenOptional(
  self : *Interpreter,
  go   : *model.Node.tg.Optional,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  return self.tryGenUnary(
    "optional", "registerOptional", "InvalidInnerOptionalType", go, stage);
}

fn ensureIsType(
  self: *Interpreter,
  expr: *model.Expression,
) bool {
  if (
    switch (expr.expected_type) {
      .named => |named| switch (named.data) {
        .poison  => return false,
        .@"type" => true,
        else => false,
      },
      .structural => |struc| switch (struc.*) {
        .callable => |*call| call.kind == .type,
        else => false,
      },
    }
  ) return true else {
    self.ctx.logger.ExpectedExprOfTypeXGotY(&.{
      expr.expected_type.at(expr.pos), self.ctx.types().@"type"().predef()
    });
    expr.data = .poison;
    expr.expected_type = self.ctx.types().poison();
    return false;
  }
}

fn tryGenSequence(
  self : *Interpreter,
  gs   : *model.Node.tg.Sequence,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var failed_some = false;
  var seen_poison = false;
  for ([_]?*model.Node{gs.direct, gs.auto}) |cur| {
    if (cur) |node| {
      const expr = switch (try self.tryGetType(node, stage)) {
        .finished, .unfinished => |t| try self.ctx.createValueExpr(
          (try self.ctx.values.@"type"(node.pos, t)).value()),
        .expression  => |expr| expr,
        .unavailable => {
          failed_some = true;
          continue;
        },
        .failed => {
          seen_poison = true;
          node.data = .poison;
          continue;
        }
      };
      if (!self.ensureIsType(expr)) seen_poison = true;
      node.data = .{.expression = expr};
    }
  }
  const list_type = (try self.ctx.types().list(self.ctx.types().@"type"())).?;
  for (gs.inner) |item| {
    const expr = if (item.direct) blk: {
      if (
        try self.associate(item.node, list_type.predef(), stage)
      ) |expr| break :blk expr;
      failed_some = true;
      continue;
    } else blk: {
      const inner = switch (try self.tryGetType(item.node, stage)) {
        .finished, .unfinished => |t| try self.ctx.createValueExprWithType(
          (try self.ctx.values.@"type"(item.node.pos, t)).value(),
          self.ctx.types().@"type"()),
        .expression  => |expr| expr,
        .unavailable => {
          failed_some = true;
          continue;
        },
        .failed => {
          seen_poison = true;
          continue;
        }
      };
      if (!self.ensureIsType(inner)) seen_poison = true;
      break :blk inner;
    };
    item.node.data = .{.expression = expr};
  }

  if (failed_some) return null;
  if (seen_poison) {
    const expr = try self.ctx.global().create(model.Expression);
    expr.* = .{
      .pos           = gs.node().pos,
      .data          = .poison,
      .expected_type = self.ctx.types().poison(),
    };
    return expr;
  }
  if (gs.generated) |gen| {
    var builder = Types.SequenceBuilder.init(
      self.ctx.types(), self.allocator(), true);
    if (gs.direct) |input| {
      const value = try self.ctx.evaluator().evaluate(input.data.expression);
      switch (value.data) {
        .poison  => {},
        .@"type" => |tv| {
          const st = tv.t.at(value.origin);
          const res = try builder.push(st, true);
          res.report(st, self.ctx.logger);
        },
        else => unreachable,
      }
    }
    for (gs.inner) |item| {
      const value =
        try self.ctx.evaluator().evaluate(item.node.data.expression);
      switch (value.data) {
        .poison => {},
        .list => |*lst| {
          std.debug.assert(item.direct);
          for (lst.content.items) |inner| {
            const t = inner.data.@"type".t.at(inner.origin);
            const res = try builder.push(t, false);
            res.report(t, self.ctx.logger);
          }
        },
        .@"type" => |tv| {
          std.debug.assert(!item.direct);
          const st = tv.t.at(value.origin);
          const res = try builder.push(st, false);
          res.report(st, self.ctx.logger);
        },
        else => unreachable,
      }
    }
    const auto_t: ?model.SpecType = if (gs.auto) |auto| blk: {
      const value = try self.ctx.evaluator().evaluate(auto.data.expression);
      switch (value.data) {
        .poison  => break :blk null,
        .@"type" => |tv| break :blk tv.t.at(auto.pos),
        else => unreachable,
      }
    } else null;
    gen.* = .{.sequence = undefined};
    const res = try builder.finish(auto_t, &gen.sequence);
    res.report(auto_t, self.ctx.logger);
    return try self.ctx.createValueExpr(
      (try self.ctx.values.@"type"(gs.node().pos, res.t)).value());
  } else {
    var inner = std.ArrayList(model.Expression.Varargs.Item).init(
      self.ctx.global());
    for (gs.inner) |item| {
      try inner.append(
        .{.direct = item.direct, .expr = item.node.data.expression});
    }
    const expr = try self.ctx.global().create(model.Expression);
    expr.* = .{
      .pos           = gs.node().pos,
      .expected_type = self.ctx.types().@"type"(),
      .data          = .{.tg_sequence = .{
        .direct = if (gs.direct) |direct| direct.data.expression else null,
        .inner  = inner.items,
        .auto   = if (gs.auto) |auto| auto.data.expression else null,
      }},
    };
    return expr;
  }
}

fn tryGenPrototype(
  self : *Interpreter,
  gp   : *model.Node.tg.Prototype,
  stage: Stage,
) nyarna.Error!bool {
  if (!(try self.tryInterpretLocationsList(&gp.params, stage))) return false;
  switch(stage.kind) {
    .keyword, .final => self.ctx.logger.BuiltinMustBeNamed(gp.node().pos),
    else => {}
  }
  return true;
}

const EmbedsMap = std.HashMapUnmanaged(
  model.Type, usize, model.Type.HashContext,
  std.hash_map.default_max_load_percentage);

fn addEmbeds(
  self  : *Interpreter,
  embeds: *EmbedsMap,
  spec  : model.SpecType,
  offset: usize,
) std.mem.Allocator.Error!void {
  var res = try embeds.getOrPut(self.allocator(), spec.t);
  if (!res.found_existing) {
    if (spec.t.isNamed(.record)) {
      for (spec.t.named.data.record.embeds) |inner| {
        try self.addEmbeds(embeds, inner.t.typedef().at(spec.pos), offset + 1);
      }
      res.value_ptr.* = embeds.count() - 1 - offset;
    } else {
      self.ctx.logger.InvalidEmbed(&.{spec});
    }
  }
}

fn tryGenRecord(
  self : *Interpreter,
  gr   : *model.Node.tg.Record,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  var failed_parts = false;
  var abstract = false;
  if (gr.abstract) |anode| if (
    try self.interpretWithTargetScalar(
      anode, self.ctx.types().system.boolean.predef(), stage)
  ) |expr| {
    anode.data = .{.expression = expr};
    const value = try self.ctx.evaluator().evaluate(expr);
    expr.data = .{.value = value};
    switch (value.data) {
      .poison  => {},
      .@"enum" => |*e| abstract = e.index == 1,
      else     => unreachable,
    }
  };

  var seen_poison = false;
  var embeds = EmbedsMap{};

  const list_type = (try self.ctx.types().list(self.ctx.types().@"type"())).?;
  for (gr.embed) |item| {
    if (item.direct) {
      if (
        try self.associate(item.node, list_type.predef(), stage)
      ) |expr| {
        const value = try self.ctx.evaluator().evaluate(expr);
        expr.data = .{.value = value};
        switch (value.data) {
          .list   => |*lst| for (lst.content.items) |v| {
            try self.addEmbeds(&embeds, v.data.@"type".t.at(v.origin), 0);
          },
          .poison => expr.expected_type = self.ctx.types().poison(),
          else    => unreachable,
        }
      } else failed_parts = true;
      continue;
    }
    const t: model.SpecType = switch (try self.tryGetType(item.node, stage)) {
      .finished, .unfinished => |t| t.at(item.node.pos),
      .expression  => |expr| blk: {
        const value = try self.ctx.evaluator().evaluate(expr);
        expr.data = .{.value = value};
        item.node.data = .{.expression = expr};
        switch (value.data) {
          .@"type" => |tv| break :blk tv.t.at(expr.pos),
          .poison => {
            seen_poison = true;
            continue;
          },
          else => unreachable,
        }
      },
      .unavailable => {
        failed_parts = true;
        continue;
      },
      .failed => {
        seen_poison = true;
        continue;
      }
    };
    try self.addEmbeds(&embeds, t, 0);
  }

  while (!failed_parts) switch (gr.fields) {
    .unresolved => {
      if (!try self.tryInterpretLocationsList(&gr.fields, stage)) {
        failed_parts = true;
      }
    },
    .resolved => |*res| {
      var finder = Types.CallableReprFinder.init(self.ctx.types());

      var i: usize = 0; while (i < embeds.count()) : (i += 1) {
        var iter = embeds.iterator();
        while (iter.next()) |entry| {
          if (entry.value_ptr.* == i) {
            const rec = &entry.key_ptr.named.data.record;
            for (rec.constructor.sig.parameters[rec.first_own..]) |param| {
              try finder.pushType(param.spec.t, param.name);
            }
            break;
          }
        }
      }
      const first_own = finder.count;

      if (!(try self.processLocations(&res.locations, stage, &finder))) {
        return null;
      }
      const embed_list = try self.ctx.global().alloc(
        model.Type.Record.Embed, embeds.count());
      var iter = embeds.iterator();
      while (iter.next()) |entry| {
        embed_list[entry.value_ptr.*] = .{
          .t           = &entry.key_ptr.named.data.record,
          .first_field = undefined,
        };
      }
      var field_index: usize = 0;
      for (embed_list) |*embed| {
        embed.first_field = field_index;
        field_index +=
          embed.t.constructor.sig.parameters.len - embed.t.first_own;
      }

      const target = &(gr.generated orelse blk: {
        const named = try self.ctx.global().create(model.Type.Named);
        named.* = .{
          .at   = gr.node().pos,
          .name = null,
          .data = .{.record = undefined},
        };
        gr.generated = named;
        break :blk named;
      }).data.record;
      target.embeds = embed_list;
      target.first_own = first_own;
      target.abstract = abstract;

      var names = std.StringHashMapUnmanaged(model.Position){};

      const target_type = model.Type{.named = target.named()};
      const finder_res = try finder.finish(target_type, true);
      std.debug.assert(finder_res.found.* == null);
      var b = try Types.SigBuilder.init(
        self.ctx, res.locations.len + field_index,
        target_type, finder_res.needs_different_repr);
      for (embed_list) |embed| {
        for (embed.t.constructor.sig.parameters[embed.t.first_own..]) |param| {
          const nres = try names.getOrPut(self.allocator(), param.name);
          if (nres.found_existing) {
            self.ctx.logger.DuplicateSymbolName(
              param.name, param.pos, nres.value_ptr.*);
          } else {
            try b.pushParam(param);
            nres.value_ptr.* = param.pos;
          }
        }
      }
      for (res.locations) |*loc| switch (loc.*) {
        .node => unreachable,
        .expr => |expr| switch (
          (try self.ctx.evaluator().evaluate(expr)).data
        ) {
          .location => |*lval| {
            loc.* = .{.value = lval};
            if (names.get(lval.name.content)) |pos| {
              self.ctx.logger.DuplicateSymbolName(
                lval.name.content, lval.value().origin, pos);
            } else try b.push(lval);
            // no need to push the name name into names because duplicate names
            // within locations have already been accounted for.
          },
          .poison => {},
          else => unreachable,
        },
        .value => |lval| if (names.get(lval.name.content)) |pos| {
          self.ctx.logger.DuplicateSymbolName(
            lval.name.content, lval.value().origin, pos);
        } else try b.push(lval),
        .poison => {},
      };
      const builder_res = b.finish();
      target.constructor =
        try builder_res.createCallable(self.ctx.global(), .@"type");
      gr.fields = .pregen;
    },
    .pregen => {
      return try self.ctx.createValueExpr(
        (try self.ctx.values.@"type"(gr.node().pos, .{
          .named = gr.generated.?,
        })).value());
    }
  };
  return null;
}

fn putIntoCategories(
  val : *model.Value,
  cats: *unicode.CategorySet
) bool {
  switch (val.data) {
    .@"enum" => |*e| switch (e.index) {
      0    => cats.include(.Lu),
      1    => cats.include(.Ll),
      2    => cats.include(.Lt),
      3    => cats.include(.Lm),
      4    => cats.include(.Lo),
      5    => cats.includeSet(unicode.Lut),
      6    => cats.includeSet(unicode.LC),
      7    => cats.includeSet(unicode.L),
      8    => cats.include(.Mn),
      9    => cats.include(.Mc),
      10   => cats.include(.Me),
      11   => cats.include(.Nd),
      12   => cats.include(.Nl),
      13   => cats.include(.No),
      14   => cats.includeSet(unicode.M),
      15   => cats.include(.Pc),
      16   => cats.include(.Pd),
      17   => cats.include(.Ps),
      18   => cats.include(.Pe),
      19   => cats.include(.Pi),
      20   => cats.include(.Pf),
      21   => cats.include(.Po),
      22   => cats.includeSet(unicode.P),
      23   => cats.include(.Sm),
      24   => cats.include(.Sc),
      25   => cats.include(.Sk),
      26   => cats.include(.So),
      27   => cats.includeSet(unicode.S),
      28   => cats.includeSet(unicode.MPS),
      29   => cats.include(.Zs),
      30   => cats.include(.Zl),
      31   => cats.include(.Zp),
      32   => cats.include(.Cc),
      33   => cats.include(.Cf),
      34   => cats.include(.Co),
      35   => cats.include(.Cn),
      else => unreachable,
    },
    .poison => return false,
    else => unreachable,
  }
  return true;
}

fn tryGenTextual(
  self : *Interpreter,
  gt   : *model.Node.tg.Textual,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  // bootstrapping for system.ny
  const needs_local_category_enum =
    std.mem.eql(u8, ".std.system", gt.node().pos.source.locator.repr);

  var seen_poison = false;
  var failed_some = false;
  var categories = unicode.CategorySet.empty();

  var unicode_category = if (needs_local_category_enum) blk: {
    if (
      self.namespaces.items[0].data.get("UnicodeCategory")
    ) |sym| {
      switch (sym.data) {
        .@"type" => |t| switch (t) {
          .named => |named| switch (named.data) {
            .@"enum" => |e| {
              if (e.values.count() == 36) break :blk t;
              self.ctx.logger.WrongNumberOfEnumValues(sym.defined_at, "36");
            },
            else =>
              self.ctx.logger.WrongType(sym.defined_at, "should be Enum"),
          },
          else => self.ctx.logger.WrongType(sym.defined_at, "should be Enum"),
        },
        else =>
          self.ctx.logger.ShouldBeType(sym.defined_at, "UnicodeCategory"),
      }
    } else self.ctx.logger.MissingType(gt.node().pos, "UnicodeCategory");
    return try self.ctx.createValueExpr(
      try self.ctx.values.poison(gt.node().pos));
  } else self.ctx.types().system.unicode_category;

  for (gt.categories) |item| {
    if (item.direct) {
      const expr = (
        try self.associate(item.node,
          (try self.ctx.types().list(unicode_category)).?.predef(), stage)
      ) orelse {
        failed_some = true;
        continue;
      };
      item.node.data = .{.expression = expr};
      const val = try self.ctx.evaluator().evaluate(expr);
      switch (val.data) {
        .list => |*list| for (list.content.items) |inner| {
          if (!putIntoCategories(inner, &categories)) seen_poison = true;
        },
        .poison => seen_poison = true,
        else => unreachable,
      }
    } else {
      const expr = (
        try self.associate(item.node, unicode_category.predef(), stage)
      ) orelse {
        failed_some = true;
        continue;
      };
      item.node.data = .{.expression = expr};
      const val = try self.ctx.evaluator().evaluate(expr);
      if (!putIntoCategories(val, &categories)) seen_poison = true;
    }
  }

  var chars = [2]std.hash_map.AutoHashMapUnmanaged(u21, void){.{}, .{}};
  for ([_]?*model.Node{gt.include_chars, gt.exclude_chars}) |item, index| {
    if (item) |node| {
      if (
        try self.associate(node, self.ctx.types().literal().predef(), stage)
      ) |expr| {
        node.data = .{.expression = expr};
        const val = try self.ctx.evaluator().evaluate(expr);
        switch (val.data) {
          .text => |*txt| {
            var iter = std.unicode.Utf8Iterator{.bytes = txt.content, .i = 0};
            while (iter.nextCodepoint()) |code_point| {
              try chars[index].put(self.ctx.global(), code_point, .{});
            }
          },
          .poison => seen_poison = true,
          else => unreachable,
        }
      } else failed_some = true;
    }
  }

  if (failed_some) {
    for (chars) |*map| map.clearAndFree(self.ctx.global());
    return null;
  }
  if (seen_poison) {
    for (chars) |*map| map.clearAndFree(self.ctx.global());
    return try self.ctx.createValueExpr(
      try self.ctx.values.poison(gt.node().pos));
  }

  if (categories.content == 0 and chars[0].count() == 0) {
    categories = unicode.CategorySet.all();
  }

  const named = try self.ctx.global().create(model.Type.Named);
  named.* = .{
    .at = gt.node().pos,
    .name = null,
    .data = .{.textual = .{
      .include = .{
        .chars = chars[0],
        .categories = categories,
      },
      .exclude = chars[1],
    }},
  };

  return try self.ctx.createValueExpr((try self.ctx.values.@"type"(
    named.at, model.Type{.named = named})).value());
}

fn tryGenUnique(
  self : *Interpreter,
  gu   : *model.Node.tg.Unique,
  stage: Stage,
) void {
  switch (stage.kind) {
    .keyword, .final => self.ctx.logger.BuiltinMustBeNamed(gu.node().pos),
    else => {}
  }
}

/// Tries to interpret the given node. Consumes the `input` node.
/// The node returned will be
///
///  * equal to the input node on failure
///  * an expression node containing the result of the interpretation
///
/// If a keyword call is encountered, that call will be evaluated and its
/// result will be processed again via tryInterpret.
///
/// if report_failure is set, emits errors to the handler if this or a child
/// node cannot be interpreted.
pub fn tryInterpret(
  self : *Interpreter,
  input: *model.Node,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  return switch (input.data) {
    .assign   => |*ass| self.tryInterpretAss(ass, stage),
    .backend  => {
      if (stage.kind == .keyword or stage.kind == .final) {
        self.ctx.logger.BackendOutsideSchemaDef(input.pos);
        const expr = try self.ctx.global().create(model.Expression);
        expr.* = .{
          .pos = input.pos,
          .data = .poison,
          .expected_type = self.ctx.types().poison(),
        };
        return expr;
      } else return null;
    },
    .builtingen => |*bg| {
      _ = try self.tryInterpretBuiltin(bg, stage);
      return null;
    },
    .capture => |*cpt|    self.tryInterpretCapture(cpt),
    .concat  => self.tryProbeAndInterpret(input, stage),
    .definition => |*def| self.tryInterpretDef(def, stage),
    .expression => |expr| return expr,
    .@"for" => |*f| try self.tryInterpretFor(f, stage),
    .funcgen => |*func| blk: {
      const val = (
        try self.tryInterpretFunc(func, stage)
      ) orelse break :blk null;
      break :blk try self.ctx.createValueExpr(
        (try self.ctx.values.funcRef(input.pos, val)).value());
    },
    .highlighter => |*hl| try self.tryInterpretHighlighter(hl, stage),
    .@"if" => self.tryProbeAndInterpret(input, stage),
    .import => unreachable, // this must always be handled directly
                            // by the parser.
    .literal => |lit| return switch (stage.kind) {
      .keyword, .final => try self.ctx.createValueExpr(
        (try self.ctx.values.textScalar(
            input.pos, if (lit.kind == .space) self.ctx.types().space()
                      else self.ctx.types().literal(),
            try self.ctx.global().dupe(u8, lit.content))).value()),
      else => null,
    },
    .location          => |*lo| self.tryInterpretLoc(lo, stage),
    .map               => |*mp| self.tryInterpretMap(mp, stage),
    .match             => |*mt| self.tryInterpretMatch(mt, stage),
    .matcher           => |*mt| blk: {
      const val = (
        try self.tryInterpretMatcher(mt, stage)
      ) orelse break :blk null;
      break :blk try self.ctx.createValueExpr(
        (try self.ctx.values.funcRef(input.pos, val)).value());
    },
    .output            => |*ou| self.tryInterpretOutput(ou, stage),
    .resolved_access   => |*ra| self.tryInterpretRAccess(ra, stage),
    .resolved_symref   => |*rs| self.tryInterpretSymref(rs),
    .resolved_call     => |*rc| self.tryInterpretCall(rc, stage),
    .seq               =>       self.tryProbeAndInterpret(input, stage),
    .gen_concat        => |*gc| self.tryGenConcat(gc, stage),
    .gen_enum          => |*ge| self.tryGenEnum(ge, stage),
    .gen_intersection  => |*gi| self.tryGenIntersection(gi, stage),
    .gen_list          => |*gl| self.tryGenList(gl, stage),
    .gen_map           => |*gm| self.tryGenMap(gm, stage),
    .gen_numeric       => |*gn| self.tryGenNumeric(gn, stage),
    .gen_optional      => |*go| self.tryGenOptional(go, stage),
    .gen_sequence      => |*gp| self.tryGenSequence(gp, stage),
    .gen_prototype     => |*gp| {
      _ = try self.tryGenPrototype(gp, stage);
      return null;
    },
    .gen_record        => |*gr| self.tryGenRecord(gr, stage),
    .gen_textual       => |*gt| self.tryGenTextual(gt, stage),
    .gen_unique        => |*gu| {
      self.tryGenUnique(gu, stage);
      return null;
    },
    .root_def          => |*rd| self.tryInterpretRootDef(rd),
    .unresolved_access => |*ua| self.tryInterpretUAccess(ua, stage),
    .unresolved_call   => |*uc| self.tryInterpretUCall(uc, stage),
    .unresolved_symref => |*us| self.tryInterpretURef(us, stage),
    .varargs           => |*va| self.tryInterpretVarargs(va, stage),
    .varmap            => |*vm| self.tryInterpretVarmap(vm, stage),
    .vt_setter         => |*vs| self.tryInterpretVarTypeSetter(vs, stage),
    .void, .poison => {
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos = input.pos,
        .data = if (input.data == .void) .void else .poison,
        .expected_type =
          if (input.data == .void) self.ctx.types().void()
          else self.ctx.types().poison(),
      };
      return expr;
    },
  };
}

pub fn interpret(
  self : *Interpreter,
  input: *model.Node,
) nyarna.Error!*model.Expression {
  return if (try self.tryInterpret(input, .{.kind = .final})) |expr| expr
  else try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos));
}

pub fn interpretAs(
  self : *Interpreter,
  input: *model.Node,
  item : model.SpecType,
) nyarna.Error!*model.Expression {
  return if (try self.associate(input, item, .{.kind = .final})) |expr| expr
  else try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos));
}

pub fn resolveSymbol(
  self      : *Interpreter,
  pos       : model.Position,
  ns        : u15,
  nschar_len: u3,
  name      : []const u8,
) !*model.Node {
  var syms = &self.namespaces.items[ns].data;
  var ret = try self.allocator().create(model.Node);
  ret.* = .{
    .pos  = pos,
    .data = if (syms.get(name)) |sym| .{
      .resolved_symref = .{
        .ns       = ns,
        .sym      = sym,
        .name_pos = pos.trimFrontChar(nschar_len),
      },
    } else .{
      .unresolved_symref = .{
        .ns = ns, .name = name, .nschar_len = nschar_len,
      }
    },
  };
  return ret;
}

/// Calculate the supremum of the given nodes' types and return it.
///
/// Substructures will be interpreted as necessary (see doc on probeType).
/// If some substructure cannot be interpreted, null is returned.
fn probeNodeList(
  self  : *Interpreter,
  nodes : []*model.Node,
  stage : Stage,
  sloppy: bool,
) !?model.Type {
  var sup: model.Type = self.ctx.types().every();
  var already_poison = false;
  var seen_unfinished = false;
  for (nodes) |node, i| {
    const t = (try self.probeType(node, stage, sloppy)) orelse {
      seen_unfinished = true;
      continue;
    };
    if (t.isNamed(.poison)) {
      already_poison = true;
      continue;
    }
    const new = try self.ctx.types().sup(sup, t);
    if (new.isNamed(.poison)) {
      if (self.ctx.types().convertible(t, sup)) continue;
      already_poison = true;
      const found = for (nodes[0..i]) |prev| {
        const prev_t = (
          try self.probeType(prev, stage, sloppy)
        ) orelse continue;
        if (prev_t.isNamed(.poison)) continue;
        if ((try self.ctx.types().sup(t, prev_t)).isNamed(.poison)) {
          self.ctx.logger.IncompatibleTypes(&.{
            t.at(node.pos), prev_t.at(prev.pos),
          });
          break true;
        }
      } else false;
      if (!found) {
        const pos = nodes[0].pos.span(nodes[i - 1].pos);
        self.ctx.logger.IncompatibleTypes(&.{t.at(node.pos), sup.at(pos)});
      }
    } else sup = new;
  }
  if (already_poison) {
    // we could not set nodes to .poison directly before, so that we could
    // issue correct error messages. but we do it now so that the issues will
    // not be reported again.
    sup = self.ctx.types().every();
    for (nodes) |node| {
      const t = (try self.probeType(node, stage, sloppy)) orelse continue;
      const new = try self.ctx.types().sup(sup, t);
      if (new.isNamed(.poison)) {
        if (try self.tryInterpret(node, .{.kind = .final})) |expr| {
          node.data = .{.expression = expr};
        } else node.data = .poison;
      } else sup = new;
    }
  }

  return if (seen_unfinished) null
  else if (already_poison) self.ctx.types().poison()
  else sup;
}

/// Calculate the supremum of all scalar types in the given node's Types.
/// considered are direct scalar types, as well as scalar types in
/// concatenations, optionals and paragraphs.
///
/// returns null only in the event of unfinished nodes.
fn probeForScalarType(
  self : *Interpreter,
  input: *model.Node,
  stage: Stage,
) !?model.Type {
  const t = (try self.probeType(input, stage, true)) orelse return null;
  if (t.isNamed(.poison)) return self.ctx.types().poison();
  return Types.containedScalar(t) orelse return self.ctx.types().@"void"();
}

fn typeFromSymbol(self: *Interpreter, sym: *model.Symbol) !model.Type {
  const callable = switch (sym.data) {
    .func      => |f| f.callable,
    .variable  => |v| return v.spec.t,
    .@"type"   => |t| return try self.ctx.types().typeType(t),
    .prototype => |pt| return switch (pt) {
      .record =>
        self.ctx.types().constructors.prototypes.record.callable.?.typedef(),
      .concat =>
        self.ctx.types().constructors.prototypes.concat.callable.?.typedef(),
      .list =>
        self.ctx.types().constructors.prototypes.list.callable.?.typedef(),
      else => self.ctx.types().prototype(),
    },
    .poison => return self.ctx.types().poison(),
  };
  // references to keywords must not be used as standalone values.
  std.debug.assert(!callable.sig.isKeyword());
  return callable.typedef();
}

fn tryResolveIfCond(
  self : *Interpreter,
  ifn  : *model.Node.If,
  stage: Stage,
) nyarna.Error!CheckResult {
  if (ifn.variable_state != .unprocessed) {
    if (ifn.condition.data.expression.expected_type.isNamed(.poison)) {
      return .poison;
    } else return .success;
  }
  const cond_expr = (
    if (ifn.condition.data == .literal) (
      try self.interpretWithTargetScalar(
        ifn.condition, self.ctx.types().system.boolean.predef(), stage)
    ) else try self.tryInterpret(ifn.condition, stage)
  ) orelse return .unfinished;
  ifn.condition.data = .{.expression = cond_expr};

  switch (cond_expr.expected_type) {
    .structural => |strct| switch (strct.*) {
      .optional => |opt| {
        lib.reportCaptures(self, ifn.then, 1);
        ifn.variable_state = if (ifn.then.capture.len > 0) blk: {
          const container =
            try self.ctx.global().create(model.VariableContainer);
          container.* = .{.num_values = 1};
          const cap = ifn.then.capture[0];
          const sym = try self.ctx.global().create(model.Symbol);
          sym.* = .{
            .defined_at = cap.pos,
            .name       = cap.name,
            .data       = .{.variable = .{
              .spec       = opt.inner.at(cap.pos),
              .container  = container,
              .offset     = 0,
              .kind       = .given,
            }},
            .parent_type = null,
          };

          const mark = self.markSyms();
          if (try self.namespace(cap.ns).tryRegister(self, sym)) {
            try Resolver.init(self, .{.kind = .intermediate}).resolve(
              ifn.then.root);
            self.resetSyms(mark);
          }

          break :blk .{.generated = &sym.data.variable};
        } else .none;
        return .success;
      },
      else => {},
    },
    .named => |named| switch (named.data) {
      .@"enum" => |*enum_type| if (
        enum_type == &self.ctx.types().system.boolean.named.data.@"enum"
      ) {
        lib.reportCaptures(self, ifn.then, 0);
        ifn.variable_state = .none;
        return .success;
      },
      .poison => {
        ifn.variable_state = .none;
        return .poison;
      },
      else => {},
    }
  }
  self.ctx.logger.InvalidIfCondType(&.{
    ifn.condition.data.expression.expected_type.at(ifn.condition.pos)
  });
  ifn.variable_state = .none;
  return .poison;
}

/// Returns the given node's type, if it can be calculated. If the node or its
/// substructures cannot be fully interpreted, null is returned.
///
/// This will modify the given node by interpreting all substructures that
/// are guaranteed not to be type-dependent on context. This means that all
/// nodes are evaluated except for literal nodes, paragraphs, concatenations
/// transitively.
///
/// Semantic errors that are discovered during probing will be logged and lead
/// to poison being returned if stage.kind != .intermediate.
pub fn probeType(
  self  : *Interpreter,
  node  : *model.Node,
  stage : Stage,
  sloppy: bool,
) nyarna.Error!?model.Type {
  switch (node.data) {
    .gen_concat, .gen_enum, .gen_intersection, .gen_list, .gen_map,
    .gen_numeric, .gen_optional, .gen_sequence, .gen_record, .gen_textual,
    .gen_unique => if (sloppy) (
      return self.ctx.types().@"type"()
    ) else if (try self.tryInterpret(node, stage)) |expr| {
      node.data = .{.expression = expr};
      return expr.expected_type;
    } else return null,
    .assign, .builtingen, .@"for", .funcgen, .highlighter, .import, .matcher,
    .root_def, .vt_setter => if (try self.tryInterpret(node, stage)) |expr| {
      node.data = .{.expression = expr};
      return expr.expected_type;
    } else return null,
    .backend => return null,
    .capture => |cpt| return try self.probeType(cpt.content, stage, sloppy),
    .concat  => |con| {
      var inner =
        (try self.probeNodeList(con.items, stage, sloppy)) orelse return null;
      if (!inner.isNamed(.poison)) {
        inner = (try self.ctx.types().concat(inner)) orelse blk: {
          self.ctx.logger.InvalidInnerConcatType(&.{inner.at(node.pos)});
          break :blk self.ctx.types().poison();
        };
      }
      if (inner.isNamed(.poison)) {
        node.data = .poison;
      }
      return inner;
    },
    .definition    => return self.ctx.types().definition(),
    .expression    => |e| return e.expected_type,
    .gen_prototype => return self.ctx.types().prototype(),
    .@"if"         => |*ifn| switch (try self.tryResolveIfCond(ifn, stage)) {
      .success => if (ifn.@"else") |en| {
        return try self.probeNodeList(&.{ifn.then.root, en}, stage, sloppy);
      } else {
        return try self.probeType(ifn.then.root, stage, sloppy);
      },
      .poison     => return self.ctx.types().poison(),
      .unfinished => return null,
    },
    .literal       => |l| if (l.kind == .space) {
      return self.ctx.types().space();
    } else {
      return self.ctx.types().literal();
    },
    .location => return self.ctx.types().location(),
    .map      => |*map| {
      // will be calculated when we need it first.
      var input_type: ?model.Type = null;
      var calc_inner_type = if (map.func) |func| (
        switch (try Resolver.init(self, stage).resolveChain(func)) {
          .runtime => |rc| switch (rc.t) {
            .structural => |strct| switch (strct.*) {
              .callable => |*call| call.sig.returns.at(func.pos),
              else => null,
            },
            .named => null,
          },
          .sym_ref => |sr| switch (sr.sym.data) {
            .func     => |sf| sf.callable.sig.returns.at(func.pos),
            .variable => |v| switch (v.spec.t) {
              .structural => |strct| switch (strct.*) {
                .callable => |*call| call.sig.returns.at(func.pos),
                else => null,
              },
              .named => null,
            },
            .@"type" => |t| switch (try self.ctx.types().typeType(t)) {
              .structural => |strct| switch (strct.*) {
                .callable => |*call| call.sig.returns.at(func.pos),
                else => null,
              },
              .named => null,
            },
            else => null,
          },
          .function_returning => |fr| (
            if (fr.returns.isNamed(.poison)) (
              self.ctx.types().every()
            ) else fr.returns
          ).at(func.pos),
          .failed => return null,
          .poison => null,
        }
      ) else blk: {
        input_type = (
          try self.probeType(map.input, stage, sloppy)
        ) orelse return null;
        switch (input_type.?) {
          .structural => |strct| switch (strct.*) {
            .concat   => |*con| break :blk con.inner.at(map.input.pos),
            .list     => |*lst| break :blk lst.inner.at(map.input.pos),
            .sequence => |*seq| break :blk (
              try self.ctx.types().seqInnerType(seq)
            ).at(map.input.pos),
            else => break :blk null,
          },
          .named => break :blk null,
        }
      };
      var inner_type = calc_inner_type orelse {
        // something's not right. call interpret to log errors.
        _ = try self.tryInterpret(node, stage);
        return self.ctx.types().poison();
      };
      if (map.collector) |coll| {
        if (try self.tryInterpret(coll, stage)) |expr| {
          const value = try self.ctx.evaluator().evaluate(expr);
          expr.data = .{.value = value};
          coll.data = .{.expression = expr};
          switch (value.data) {
            .poison    => return self.ctx.types().poison(),
            .prototype => |pv| switch (pv.pt) {
              .list => if (try self.ctx.types().list(inner_type.t)) |lt| (
                return lt
              ),
              .concat => if (try self.ctx.types().concat(inner_type.t)) |ct| (
                return ct
              ),
              .sequence => {
                var builder = Types.SequenceBuilder.init(
                  self.ctx.types(), self.allocator(), true);
                const res = try builder.push(inner_type, true);
                res.report(inner_type, self.ctx.logger);
                if (res == .success) return (try builder.finish(null, null)).t;
              },
              else => {},
            },
            else => {},
          }
          // collector is not right, log errors
          _ = try self.tryInterpret(node, stage);
          return self.ctx.types().poison();
        } else return null;
      } else {
        const it = input_type orelse (
          try self.probeType(map.input, stage, sloppy)
        ) orelse return null;
        switch (it) {
          .structural => |strct| switch (strct.*) {
            .list => if (try self.ctx.types().list(inner_type.t)) |lt| (
              return lt
            ),
            .concat => if (try self.ctx.types().concat(inner_type.t)) |ct| (
              return ct
            ),
            .sequence => {
              var builder = Types.SequenceBuilder.init(
                self.ctx.types(), self.allocator(), true);
              const res = try builder.push(inner_type, true);
              res.report(inner_type, self.ctx.logger);
              if (res == .success) return (try builder.finish(null, null)).t;
            },
            else => {},
          },
          else => {},
        }
        // input has invalid type, log errors
        _ = try self.tryInterpret(node, stage);
        return self.ctx.types().poison();
      }
    },
    .match    => |*match| {
      switch (try self.ensureMatchTypesPresent(match.cases, stage)) {
        .unfinished => return null,
        .poison     => {
          node.data = .poison;
          return self.ctx.types().poison();
        },
        .success => {
          var ret = self.ctx.types().every();
          var seen_poison = false;
          for (match.cases) |case, i| {
            if (try self.probeType(case.content.root, stage, sloppy)) |t| {
              if (t.isNamed(.poison)) {
                seen_poison = true;
              } else {
                const new = try self.ctx.types().sup(ret, t);
                if (new.isNamed(.poison)) {
                  seen_poison = true;
                  case.content.root.data = .poison;
                  self.ctx.logger.IncompatibleTypes(&.{
                    t.at(case.content.root.pos),
                    ret.at(match.cases[0].content.root.pos.span(
                      match.cases[i-1].content.root.pos))
                  });
                } else ret = new;
              }
            } else return null;
          }
          if (seen_poison) return self.ctx.types().poison();
          return ret;
        }
      }
    },
    .output          => return self.ctx.types().output(),
    .resolved_access => |*ra| {
      var t = (try self.probeType(ra.base, stage, sloppy)).?;
      for (ra.path) |item| t = switch(item) {
        .field     => |field| Types.descend(field.t.typedef(), field.index),
        .subscript => switch (t.structural.*) {
          .concat    => |*con| con.inner,
          .list      => |*lst| lst.inner,
          .sequence  => |*seq| try self.ctx.types().seqInnerType(seq),
          else       => unreachable,
        },
      };
      return t;
    },
    .resolved_call => |*rc| {
      if (rc.sig.returns.isNamed(.ast)) {
        // this is a keyword call. tryInterpretCall will attempt to
        // execute it.
        if (try self.tryInterpretCall(rc, stage)) |expr| {
          node.data = .{.expression = expr};
          return expr.expected_type;
        }
        // tryInterpretCall *will* have either called the keyword or
        // generated poison. The keyword may have returned an unresolvable
        // node, on which we recurse.
        std.debug.assert(node.data != .resolved_call);
        return try self.probeType(node, stage, sloppy);
      } else return rc.sig.returns;
    },
    .resolved_symref => |*ref| return try self.typeFromSymbol(ref.sym),
    .seq             => |*seq| {
      var builder = nyarna.Types.SequenceBuilder.init(
        self.ctx.types(), self.allocator(), false);
      var seen_unfinished = false;
      for (seq.items) |*item| {
        if (try self.probeType(item.content, stage, sloppy)) |t| {
          const st = t.at(item.content.pos);
          const res = try builder.push(st, false);
          if (res != .success) {
            item.content.data = .poison;
            res.report(st, self.ctx.logger);
          }
        } else seen_unfinished = true;
      }
      return
        if (seen_unfinished) null else (try builder.finish(null, null)).t;
    },
    .unresolved_access, .unresolved_call, .unresolved_symref => {
      return switch (try Resolver.init(self, stage).resolveChain(node)) {
        .runtime => |*rc| rc.t,
        .sym_ref => |*sr| try self.typeFromSymbol(sr.sym),
        .failed, .function_returning => null,
        .poison  => blk: {
          node.data = .poison;
          break :blk self.ctx.types().poison();
        },
      };
    },
    .varargs => |*varargs| return varargs.t.typedef(),
    .varmap  => |*varmap| return varmap.t.typedef(),
    .void    => return self.ctx.types().void(),
    .poison  => return self.ctx.types().poison(),
  }
}

pub fn genValueNode(
  self   : *Interpreter,
  content: *model.Value,
) !*model.Node {
  return try self.node_gen.expression(try self.ctx.createValueExpr(content));
}

fn createTextLiteral(
  self: *Interpreter,
  l   : *model.Node.Literal,
  spec: model.SpecType,
) nyarna.Error!*model.Value {
  switch (spec.t) {
    .structural => |struc| return switch (struc.*) {
      .optional => |*op|
        try self.createTextLiteral(l, op.inner.at(spec.pos)),
      .concat => |*con|
        try self.createTextLiteral(l, con.inner.at(spec.pos)),
      .sequence => |*seq| blk: {
        if (seq.direct) |direct| {
          if (Types.containedScalar(direct)) |scalar| {
            break :blk try self.createTextLiteral(l, scalar.at(spec.pos));
          }
        }
        const lt = self.ctx.types().litType(l);
        self.ctx.logger.ExpectedExprOfTypeXGotY(
          &.{lt.at(l.node().pos), spec});
        break :blk self.ctx.values.poison(l.node().pos);
      },
      .list, .hashmap, .callable => blk: {
        const lt = self.ctx.types().litType(l);
        self.ctx.logger.ExpectedExprOfTypeXGotY(
          &.{lt.at(l.node().pos), spec});
        break :blk try self.ctx.values.poison(l.node().pos);
      },
      .intersection => |*inter| if (inter.scalar) |scalar| {
        return try self.createTextLiteral(l, scalar.at(spec.pos));
      } else {
        const lt = self.ctx.types().litType(l);
        self.ctx.logger.ExpectedExprOfTypeXGotY(
          &.{lt.at(l.node().pos), spec});
        return try self.ctx.values.poison(l.node().pos);
      }
    },
    .named => |ti| switch (ti.data) {
      .textual => |*txt| return if (
        try self.ctx.textFromString(
          l.node().pos, try self.ctx.global().dupe(u8, l.content), txt)
      ) |scalar| scalar.value() else try self.ctx.values.poison(l.node().pos),
      .int => |*n| {
        return if (
          try self.ctx.intFromText(l.node().pos, l.content, n)
        ) |nv| nv.value()
        else try self.ctx.values.poison(l.node().pos);
      },
      .float => |*fl| return if (
        try self.ctx.floatFromText(l.node().pos, l.content, fl)
      ) |float| float.value() else try self.ctx.values.poison(l.node().pos),
      .@"enum" => |*e| {
        return if (try self.ctx.enumFrom(l.node().pos, l.content, e)) |ev|
          ev.value() else try self.ctx.values.poison(l.node().pos);
      },
      .record => {
        const lt = self.ctx.types().litType(l);
        self.ctx.logger.ExpectedExprOfTypeXGotY(
          &.{lt.at(l.node().pos), spec});
        return self.ctx.values.poison(l.node().pos);
      },
      .space => if (l.kind == .space) {
        return (try self.ctx.values.textScalar(
          l.node().pos, spec.t, try self.ctx.global().dupe(u8, l.content))
        ).value();
      } else {
        const lt = self.ctx.types().literal();
        self.ctx.logger.ExpectedExprOfTypeXGotY(
          &.{lt.at(l.node().pos), spec});
        return self.ctx.values.poison(l.node().pos);
      },
      .literal => return (try self.ctx.values.textScalar(
        l.node().pos, spec.t, try self.ctx.global().dupe(u8, l.content)
      )).value(),
      else => return (try self.ctx.values.textScalar(
        l.node().pos,
        if (l.kind == .text) self.ctx.types().literal()
        else self.ctx.types().space(),
        try self.ctx.global().dupe(u8, l.content)
      )).value(),
    },
  }
}

fn probeCheckOrPoison(
  self : *Interpreter,
  input: *model.Node,
  t    : model.Type,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  std.debug.assert(stage.kind != .resolve);
  var actual_type = (
    try self.probeType(input, stage, false)
  ) orelse return null;
  if (
    !actual_type == .poison and
    !self.ctx.types().lesserEqual(actual_type, t)
  ) {
    actual_type = .poison;
    self.ctx.logger.ExpectedExprOfTypeXGotY(
      input.pos, &[_]model.Type{t, actual_type});
  }
  return if (actual_type == .poison)
    try self.ctx.createValueExpr(try self.ctx.values.poison(input.pos))
  else null;
}

/// removes any .space type from concats and paragraphs within t and t itself
fn typeWithoutSpace(
  self: *Interpreter,
  t   : model.Type,
) std.mem.Allocator.Error!model.Type {
  return switch (t) {
    .structural => |struc| switch (struc.*) {
      .concat   => |*con|
        (try self.ctx.types().concat(try self.typeWithoutSpace(con.inner))).?,
      .optional => |*opt| (
        try self.ctx.types().optional(try self.typeWithoutSpace(opt.inner))
      ).?,
      .sequence => |*seq| blk: {
        if (seq.direct) |direct| {
          const dws = try self.typeWithoutSpace(direct);
          if (dws.eql(direct)) break :blk t;
          return try self.ctx.types().calcSequence(dws, seq.inner);
        }
        break :blk t;
      },
      else => return t,
    },
    .named => t,
  };
}

fn mixIfCompatible(
  self  : *Interpreter,
  target: *model.Type,
  add   : model.Type,
  exprs : []*model.Expression,
  index : usize,
) !bool {
  if (add.isNamed(.poison)) return false;
  const new = try self.ctx.types().sup(target.*, add);
  if (new.isNamed(.poison)) {
    if (self.ctx.types().convertible(add, target.*)) {
      const conv = try self.ctx.global().create(model.Expression);
      conv.* = .{
        .pos = exprs[index].pos,
        .data = .{.conversion = .{
          .inner       = exprs[index],
          .target_type = target.*,
        }},
        .expected_type = target.*,
      };
      exprs[index] = conv;
      return true;
    }
    for (exprs[0..index]) |prev| {
      const mixed =
        try self.ctx.types().sup(prev.expected_type, add);
      if (mixed.isNamed(.poison)) {
        const expr = exprs[index];
        self.ctx.logger.IncompatibleTypes(&.{
          expr.expected_type.at(expr.pos), prev.expected_type.at(prev.pos),
        });
        return false;
      }
    }
    unreachable;
  }
  target.* = new;
  return true;
}

/// Same as tryInterpret, but takes a target type that may be used to generate
/// typed literal values from text literals. The target type *must* be a
/// scalar type, .void (in which case .space literals will be removed), or
/// .poison (in which case no scalar checking occurs);
pub fn interpretWithTargetScalar(
  self : *Interpreter,
  input: *model.Node,
  spec : model.SpecType,
  stage: Stage,
) nyarna.Error!?*model.Expression {
  std.debug.assert(switch (spec.t) {
    .structural => false,
    .named => |named| switch (named.data) {
      .textual, .int, .float, .@"enum", .literal, .space, .every, .void,
      .poison => true,
      else => false,
    },
  });
  switch (input.data) {
    .assign, .backend, .builtingen, .capture, .definition, .funcgen, .import,
    .location, .map, .match, .matcher, .output, .resolved_access,
    .resolved_symref, .resolved_call, .gen_concat, .gen_enum, .gen_intersection,
    .gen_list, .gen_map, .gen_numeric, .gen_optional, .gen_sequence,
    .gen_prototype, .gen_record, .gen_textual, .gen_unique, .highlighter,
    .root_def, .unresolved_access, .unresolved_call, .unresolved_symref,
    .varargs, .varmap => {
      if (try self.tryInterpret(input, stage)) |expr| {
        if (Types.containedScalar(expr.expected_type)) |scalar_type| {
          if (self.ctx.types().lesserEqual(scalar_type, spec.t)) return expr;
          const possible_target_type = if (
            expr.expected_type.isNamed(.space) and spec.t.isNamed(.void)
          ) try self.typeWithoutSpace(expr.expected_type) else if (
            self.ctx.types().convertible(scalar_type, spec.t)
          ) try self.ctx.types().replaceScalar(expr.expected_type, spec.t)
          else null;
          if (possible_target_type) |target_type| {
            const conv = try self.ctx.global().create(model.Expression);
            conv.* = .{
              .pos = expr.pos,
              .expected_type = target_type,
              .data = .{.conversion = .{
                .inner = expr,
                .target_type = target_type,
              }},
            };
            return conv;
          } else {
            self.ctx.logger.ScalarTypesMismatch(
              &.{scalar_type.at(input.pos), spec});
            expr.data = .{.value = try self.ctx.values.poison(input.pos)};
          }
        }
        return expr;
      }
      return null;
    },
    .concat => |con| {
      // force non-concatenable scalars to coerce to Raw
      const inner_scalar = switch (spec.t) {
        .named => |named| switch (named.data) {
          .@"enum", .int, .float => self.ctx.types().text().at(spec.pos),
          else => spec,
        },
        .structural => unreachable,
      };

      var failed_some = false;
      for (con.items) |item| {
        if (
          try self.interpretWithTargetScalar(item, inner_scalar, stage)
        ) |expr| {
          item.data = .{.expression = expr};
        } else failed_some = true;
      }
      if (failed_some) return null;
      const exprs = try self.ctx.global().alloc(
        *model.Expression, con.items.len);
      var inner_type = self.ctx.types().every();
      var seen_sequence = false;
      var seen_poison = false;
      for (con.items) |item, i| {
        const expr = item.data.expression;
        exprs[i] = expr;
        if (
          switch (expr.expected_type) {
            .structural => |struc| switch (struc.*) {
              .sequence => |*sec| blk: {
                seen_sequence = true;
                var already_poison = false;
                if (sec.direct) |direct| {
                  if (
                    !(try self.mixIfCompatible(&inner_type, direct, exprs, i))
                  ) {
                    seen_poison = true;
                    already_poison = true;
                  }
                }
                if (!already_poison) for (sec.inner) |inner| {
                  if (
                    !(try self.mixIfCompatible(
                      &inner_type, inner.typedef(), exprs, i))
                  ) {
                    seen_poison = true;
                    already_poison = true;
                    break;
                  }
                };
                if (!already_poison) {
                  if (
                    !(try self.mixIfCompatible(
                      &inner_type, self.ctx.types().space(), exprs, i))
                  ) {
                    seen_poison = true;
                  }
                }
                break :blk false;
              },
              else => true,
            },
            else => true,
          }
        ) {
          if (
            !(try self.mixIfCompatible(
              &inner_type, expr.expected_type, exprs, i))
          ) seen_poison = true;
        }
      }
      const expr = try self.ctx.global().create(model.Expression);
      const expr_type =
        if (seen_poison) null else try self.ctx.types().concat(inner_type);
      if (expr_type) |target_type| {
        if (seen_sequence) {
          for (exprs) |*item| {
            if (item.*.expected_type.isStruc(.sequence)) {
              const conv = try self.ctx.global().create(model.Expression);
              conv.* = .{
                .pos = item.*.pos,
                .data = .{.conversion = .{
                  .inner = item.*,
                  .target_type = target_type,
                }},
                .expected_type = target_type,
              };
              item.* = conv;
            }
          }
        }
        expr.* = .{
          .pos = input.pos,
          .data = .{.concatenation = exprs},
          .expected_type = target_type,
        };
        return expr;
      } else {
        if (!seen_poison) {
          self.ctx.logger.InvalidInnerConcatType(
            &.{inner_type.at(input.pos)});
        }
        expr.* = .{
          .pos = input.pos,
          .data = .poison,
          .expected_type = self.ctx.types().poison(),
        };
        return expr;
      }
    },
    .expression => |expr| return expr,
    .@"for" => |*f| {
      if (try self.inspectForInput(f, stage)) |input_i| {
        const coll = if (f.collector) |c_node| (
          (try self.tryInterpret(c_node, stage)) orelse return null
        ) else null;

        if (try self.tryForBodyToFunc(f, input_i, spec, stage)) |func| {
          return try self.genMap(
            input.pos, f.input.data.expression, input_i, func,
            f.body.data.expression.expected_type, coll);
        }
      }
      return null;
    },
    // for text literals, do compile-time type conversions if possible
    .literal => |*l| {
      if (spec.t.isNamed(.void)) return try self.ctx.createValueExpr(
        try self.ctx.values.void(input.pos));
      if (spec.t.isNamed(.poison)) return try self.ctx.createValueExpr(
        try self.ctx.values.poison(input.pos));
      const expr = try self.ctx.global().create(model.Expression);
      expr.pos = input.pos;
      expr.data = .{.value = try self.createTextLiteral(l, spec)};
      expr.expected_type = spec.t;
      return expr;
    },
    .@"if" => |*ifn| {
      var seen_unfinished = false;
      var seen_poison = false;

      switch (try self.tryResolveIfCond(ifn, stage)) {
        .success    => {},
        .poison     => seen_poison     = true,
        .unfinished => seen_unfinished = true,
      }

      if (
        try self.interpretWithTargetScalar(ifn.then.root, spec, stage)
      ) |expr| {
        ifn.then.root.data = .{.expression = expr};
        if (expr.expected_type.isNamed(.poison)) seen_poison = true;
      } else seen_unfinished = true;
      if (ifn.@"else") |en| {
        if (try self.interpretWithTargetScalar(en, spec, stage)) |expr| {
          en.data = .{.expression = expr};
          if (expr.expected_type.isNamed(.poison)) seen_poison = true;
        } else seen_unfinished = true;
      }

      if (seen_unfinished) return null;
      if (seen_poison) {
        input.data = .poison;
        return null;
      }

      const tt =
        ifn.then.root.data.expression.expected_type.at(ifn.then.root.pos);
      const et = if (ifn.@"else") |en| (
        en.data.expression.expected_type.at(en.pos)
      ) else self.ctx.types().@"void"().at(input.pos);
      const out_type = try self.ctx.types().sup(tt.t, et.t);
      if (out_type.isNamed(.poison)) {
        self.ctx.logger.IncompatibleTypes(&.{et, tt});
        input.data = .poison;
        return null;
      }

      const res = try self.ctx.global().create(model.Expression);
      switch (ifn.condition.data.expression.expected_type) {
        .structural => |strct| switch (strct.*) {
          .optional => {
            res.* = .{
              .pos  = input.pos,
              .data = .{.ifopt = .{
                .condition = ifn.condition.data.expression,
                .then      = ifn.then.root.data.expression,
                .@"else"   = if (ifn.@"else") |en| en.data.expression else null,
                .variable  = switch (ifn.variable_state) {
                  .generated   => |v| v,
                  .none        => null,
                  .unprocessed => unreachable,
                },
              }},
              .expected_type = out_type,
            };
            return res;
          },
          else => unreachable,
        },
        .named => {
          const else_expr = if (ifn.@"else") |en| en.data.expression else b: {
            const ve = try self.ctx.global().create(model.Expression);
            ve.* = .{
              .pos           = input.pos,
              .data          = .void,
              .expected_type = self.ctx.types().@"void"(),
            };
            break :b ve;
          };
          const arr = try self.ctx.global().alloc(*model.Expression, 2);
          arr[1] = ifn.then.root.data.expression;
          arr[0] = else_expr;
          res.* = .{
            .pos = input.pos,
            .data = .{.branches = .{
              .condition = ifn.condition.data.expression,
              .branches  = arr,
            }},
            .expected_type = out_type,
          };
          return res;
        }
      }
    },
    .seq => |*seq| {
      var seen_unfinished = false;
      for (seq.items) |item| {
        const res = try self.probeType(item.content, stage, false);
        if (res == null) seen_unfinished = true;
      }
      if (seen_unfinished) return null;
      var builder = Types.SequenceBuilder.init(
        self.ctx.types(), self.allocator(), false);
      const res = try self.ctx.global().alloc(
        model.Expression.Paragraph, seq.items.len);
      var next: usize = 0;
      for (seq.items) |item| {
        var para_type = (try self.probeType(item.content, stage, false)).?;
        var stype = spec;
        if (Types.containedScalar(para_type)) |contained| {
          if (contained.isNamed(.space)) {
            stype = self.ctx.types().@"void"().at(spec.pos);
            para_type = try self.typeWithoutSpace(para_type);
          } else {
            para_type = if (
              try self.ctx.types().replaceScalar(para_type, stype.t)
            ) |repl| repl else {
              self.ctx.logger.ExpectedExprOfTypeXGotY(&.{
                para_type.at(item.content.pos), stype,
              });
              _ = try builder.push(self.ctx.types().poison().predef(), false);
              continue;
            };
          }
        }
        const pst = para_type.at(item.content.pos);
        const bres = try builder.push(pst, false);
        if (bres == .success) {
          res[next] = .{
            .content = (try self.interpretWithTargetScalar(
              item.content, stype, stage)).?,
            .lf_after = item.lf_after,
          };
          next += 1;
        } else {
          bres.report(pst, self.ctx.logger);
        }
      }
      const expr = try self.ctx.global().create(model.Expression);
      expr.* = .{
        .pos = input.pos,
        .data = .{.sequence = res[0..next]},
        .expected_type = (try builder.finish(null, null)).t,
      };
      return expr;
    },
    // cannot happen, because the vt_setter defines a type, nothing can force
    // a type on the vt_setter.
    .vt_setter => unreachable,
    .void      => return try self.ctx.createValueExpr(
      try self.ctx.values.void(input.pos)),
    .poison    => return try self.ctx.createValueExpr(
      try self.ctx.values.poison(input.pos)),
  }
}

/// associates the given node with the given data type, returning an
/// expression. association takes care of:
///  * interpreting the node
///  * checking whether the resulting expression is compatible with t –
///    if not, generate a poison expression
///  * checking whether the resulting expression needs to be converted to
///    conform to the given type, and if yes, wraps the expression in a
///    conversion.
/// null is returned if the association cannot be made currently because of
/// unresolved symbols.
pub fn associate(
  self : *Interpreter,
  node : *model.Node,
  item : model.SpecType,
  stage: Stage,
) !?*model.Expression {
  const scalar_type = Types.containedScalar(item.t) orelse
    (try self.probeForScalarType(node, stage)) orelse return null;

  return if (
    try self.interpretWithTargetScalar(node, scalar_type.predef(), stage)
  ) |expr| blk: {
    if (expr.expected_type.isNamed(.poison)) break :blk expr;
    if (self.ctx.types().lesserEqual(expr.expected_type, item.t)) {
      expr.expected_type = item.t;
      break :blk expr;
    }
    if (self.ctx.types().convertible(expr.expected_type, item.t)) {
      const conv = try self.ctx.global().create(model.Expression);
      conv.* = .{
        .pos = expr.pos,
        .data = .{.conversion = .{
          .inner = expr,
          .target_type = item.t,
        }},
        .expected_type = item.t,
      };
      break :blk conv;
    } else {
      self.ctx.logger.ExpectedExprOfTypeXGotY(
        &.{expr.expected_type.at(node.pos), item});
      expr.data = .{.value = try self.ctx.values.poison(expr.pos)};
      expr.expected_type = self.ctx.types().poison();
      break :blk expr;
    }
  } else null;
}