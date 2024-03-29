const nyarna = @import("nyarna");
const std    = @import("std");

const EncodedCharacter = @import("../src/nyarna/unicode.zig").EncodedCharacter;
const Globals          = @import("../src/nyarna/Globals.zig");

const errors = nyarna.errors;
const model  = nyarna.model;

pub const TestDataResolver = @import("resolve.zig").TestDataResolver;

const Error = error {
  no_match,
};

const FileTerm = errors.Terminal(std.fs.File.Writer, true);

pub fn lexTest(data: *TestDataResolver) !void {
  var r = FileTerm.init(std.io.getStdOut().writer());
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &r.reporter,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.initMainModule(&data.api, "input", .full);
  const ml = loader.loader.data.known_modules.values()[1].require_module;
  defer loader.destroy();
  var expected_content = data.valueLines("tokens");
  var lexer = try ml.initLexer();
  defer lexer.deinit();
  var startpos = lexer.recent_end;
  var t = try lexer.next();
  while(true) : (t = try lexer.next()) {
    const actual =
      try if (@enumToInt(t) >= @enumToInt(model.Token.skipping_call_id))
        std.fmt.allocPrint(
          std.testing.allocator, "{}:{}[{}] skipping_call_id({})", .{
            startpos.at_line, startpos.before_column, startpos.byte_offset,
            @enumToInt(t) - @enumToInt(model.Token.skipping_call_id) + 1
          })
      else
        std.fmt.allocPrint(std.testing.allocator, "{}:{}[{}] {s}", .{
            startpos.at_line, startpos.before_column, startpos.byte_offset,
            @tagName(t)
          });
    defer std.testing.allocator.free(actual);
    const expected = expected_content.next() orelse {
      std.log.err("got more tokens than expected, first unexpected token: {s}",
        .{actual});
      return Error.no_match;
    };
    try std.testing.expectEqualStrings(expected, actual);
    if (t == .end_source) break;
    startpos = lexer.recent_end;
  }
  while (expected_content.next()) |unmatched| {
    if (unmatched.len > 0) {
      std.log.err("got fewer tokens than expected, first missing token: {s}",
        .{unmatched});
      return Error.no_match;
    }
  }
}

const AdditionalsWithGlobal = struct {
  value: *const model.Node.Location.Additionals,
  data : *Globals,

  fn format(
             self   : AdditionalsWithGlobal,
    comptime fmt    : []const u8,
             options: std.fmt.FormatOptions,
             writer : anytype,
  ) !void {
    try writer.writeByte('{');
    var first = true;
    inline for ([_][]const u8{"primary", "varargs", "varmap", "borrow"}) |f| {
      if (@field(self.value, f) != null) {
        if (first) first = false else try writer.writeAll(", ");
        try writer.writeAll(f);
      }
    }
    try writer.writeAll("}");
    if (self.value.header) |h|
      try (HeaderWithGlobal{.header = h, .data = self.data,}).format(
        fmt, options, writer);
  }

  fn formatter(self: AdditionalsWithGlobal) std.fmt.Formatter(format) {
    return .{.data = self};
  }
};

const HeaderWithGlobal = struct {
  header: *const model.Value.BlockHeader,
  data  : *Globals,

  fn format(
             self  : HeaderWithGlobal,
    comptime _     : []const u8,
             _     : std.fmt.FormatOptions,
             writer: anytype,
  ) !void {
    if (self.header.config) |config| {
      try writer.writeAll(":<");
      var first = true;
      for (config.map) |*item| {
        if (item.to == 0) {
          if (first) first = false else try writer.writeAll(", ");
          const ec = EncodedCharacter.init(item.from);
          try writer.print("off {s}", .{ec.repr()});
        }
      }
      for (config.map) |*item| {
        if (item.from == 0) {
          if (first) first = false else try writer.writeAll(", ");
          const ec = EncodedCharacter.init(item.to);
          try writer.print("csym {s}", .{ec.repr()});
        }
      }
      for (config.map) |*item| {
        if (item.from != 0 and item.to != 0) {
          if (first) first = false else try writer.writeAll(", ");
          const fc = EncodedCharacter.init(item.from);
          const tc = EncodedCharacter.init(item.to);
          try writer.print("map {s} {s}", .{fc.repr(), tc.repr()});
        }
      }
      if (config.full_ast) |_| {
        if (first) first = false else try writer.writeAll(", ");
        try writer.writeAll("fullast");
      }
      if (config.syntax) |def| {
        if (first) first = false else try writer.writeAll(", ");
        // TODO: user-define syntaxes
        try writer.print("syntax {s}", .{switch (def.index) {
          0 => @as([]const u8, "locations"), 1 => "definitions",
          else => unreachable
        }});
      }
      try writer.writeByte('>');
    }
    if (self.header.swallow_depth) |swallow_depth| {
      try if (swallow_depth > 0) writer.print(":{}>", .{swallow_depth})
          else writer.writeAll(":>");
    } else if (self.header.config == null) try writer.writeAll("null");
  }

  fn formatter(self: HeaderWithGlobal) std.fmt.Formatter(format) {
    return .{.data = self};
  }
};

const AstEmitter = struct {
  const Self = @This();

  const Popper = struct {
    e: *Self,
    name: []const u8,

    fn pop(self: Popper) !void {
      self.e.depth -= 1;
      try self.e.emitLine("-{s}", .{self.name});
    }
  };

  const LineBuilder = struct {
    buffer: [1024]u8 = undefined,
    i: usize = 0,

    fn init(depth: usize) LineBuilder {
      var ret = LineBuilder{};
      while (ret.i < depth) : (ret.i += 1) ret.buffer[ret.i] = ' ';
      return ret;
    }

    fn append(
               self: *LineBuilder,
      comptime fmt : []const u8,
               args: anytype,
    ) !void {
      const ret = try std.fmt.bufPrint(self.buffer[self.i..], fmt, args);
      self.i += ret.len;
    }

    fn finish(self: *LineBuilder, h: *Checker) !void {
      try h.handle(self.buffer[0..self.i]);
    }
  };

  handler: *Checker,
  depth  : usize,
  data   : *Globals,

  fn init(data: *Globals, handler: *Checker) AstEmitter {
    return .{.depth = 0, .handler = handler, .data = data};
  }

  fn emitLine(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    var lb = LineBuilder.init(self.depth * 2);
    try lb.append(fmt, args);
    try lb.finish(self.handler);
  }

  fn push(self: *Self, comptime name: []const u8) !Popper {
    try self.emitLine("+{s}", .{name});
    self.depth += 1;
    return Popper{.e = self, .name = name};
  }

  fn pushWithKey(
             self : *Self,
    comptime name : []const u8,
             key  : []const u8,
             value: ?[]const u8,
  ) !Popper {
    if (value) |v| try self.emitLine("+{s} {s}=\"{s}\"", .{name, key, v})
    else try self.emitLine("+{s} {s}", .{name, key});
    self.depth += 1;
    return Popper{.e = self, .name = name};
  }

  fn pushWithType(
             self: *Self,
    comptime name: []const u8,
             t   : model.Type,
  ) !Popper {
    const t_fmt = t.formatter();
    try self.emitLine("+{s} {}", .{name, t_fmt});
    self.depth += 1;
    return Popper{.e = self, .name = name};
  }

  fn processNodePath(
    self : *Self,
    path : []const model.Node.Assign.PathItem,
    start: model.Type,
  ) anyerror!void {
    var t = start;
    for (path) |item| switch (item) {
      .field => |field| {
        const param =
          &field.t.constructor.sig.parameters[field.t.first_own + field.index];
        try self.emitLine("=FIELD {s}", .{param.name});
        t = param.spec.t;
      },
      .subscript => |node| {
        const subscr = try self.push("SUBSCRIPT");
        try self.process(node);
        try subscr.pop();
        t = switch (t.structural.*) {
          .concat   => |*con| con.inner,
          .list     => |*lst| lst.inner,
          .sequence => |*seq| try self.data.types.seqInnerType(seq),
          else      => unreachable,
        };
      },
    };
  }

  pub fn process(self: *Self, n: *model.Node) anyerror!void {
    switch (n.data) {
      .assign => |a| {
        const ass = try self.push("ASS");
        switch (a.target) {
          .unresolved => |u| {
            const target = try self.push("TARGET");
            try self.process(u);
            try target.pop();
          },
          .resolved => |r| {
            const target =
              try self.pushWithKey("TARGET", r.target.sym().name, null);
            try self.processNodePath(r.path, r.target.spec.t);
            try target.pop();
          }
        }
        try self.emitLine(">REPL", .{});
        try self.process(a.replacement);
        try ass.pop();
      },
      .backend => |back| {
        const b = try self.push("BACKEND");
        if (back.vars) |vars| {
          try self.emitLine(">VARS", .{});
          try self.process(vars);
        }
        if (back.funcs.len > 0) {
          try self.emitLine(">FUNCS", .{});
          for (back.funcs) |func| try self.process(func.node());
        }
        if (back.body) |body| {
          try self.emitLine(">BODY", .{});
          try self.process(body.root);
        }
        try b.pop();
      },
      .builtingen => |bg| {
        const lvl = try self.push("BUILTINGEN");
        switch (bg.returns) {
          .node => |rnode| try self.process(rnode),
          .expr => |expr| try self.processExpr(expr),
        }
        try self.emitLine(">PARAMS", .{});
        try self.process(bg.params.unresolved);
        try lvl.pop();
      },
      .capture => |cpt| {
        const c = try self.push("CAPTURE");
        for (cpt.vars) |v| {
          try self.emitLine("=VAR [{}]{s}", .{v.ns, v.name});
        }
        try self.emitLine(">CONTENT", .{});
        try self.process(cpt.content);
        try c.pop();
      },
      .concat => |c| {
        for (c.items) |item| try self.process(item);
      },
      .definition => |d| {
        const def = try self.pushWithKey("DEF", d.name.content, null);
        try self.process(d.content);
        try def.pop();
      },
      .expression => |e| try self.processExpr(e),
      .@"for" => |f| {
        const lvl = try self.push("FOR");
        try self.process(f.input);
        if (f.collector) |coll| {
          try self.emitLine(">COLLECTOR", .{});
          try self.process(coll);
        }
        if (f.captures.len > 0) {
          try self.emitLine(">CAPTURES", .{});
          for (f.captures) |v| {
            try self.emitLine("=VAR [{}]{s}", .{v.ns, v.name});
          }
        }
        try self.emitLine(">BODY", .{});
        try self.process(f.body);
        try lvl.pop();
      },
      .funcgen => |fg| {
        const func = try self.push("FUNC");
        if (fg.returns) |ret| {
          const rl = try self.push("RETURN");
          try self.process(ret);
          try rl.pop();
        }
        try self.process(fg.params.unresolved);
        const body = try self.push("BODY");
        try self.process(fg.body);
        try body.pop();
        try func.pop();
      },
      .highlighter => |hl| {
        const lvl = try self.push("HIGHLIGHT");
        try self.process(hl.syntax);
        for (hl.renderers) |renderer| {
          if (renderer.variable) |v| {
            try self.emitLine(">RENDERER {s} |[{}]{s}|", .{
              renderer.name.content, v.ns, v.name,
            });
          } else try self.emitLine(">RENDERER {s}", .{renderer.name.content});
          try self.process(renderer.content);
        }
        try lvl.pop();
      },
      .@"if" => |ifn| {
        const lvl = try self.push("IF");
        try self.process(ifn.condition);
        if (ifn.then.capture.len > 0) {
          try self.emitLine(">THEN |{s}|", .{ifn.then.capture[0].name});
        } else try self.emitLine(">THEN", .{});
        try self.process(ifn.then.root);
        if (ifn.@"else") |en| {
          try self.emitLine(">ELSE", .{});
          try self.process(en);
        }
        try lvl.pop();
      },
      .import => |i| {
        try self.emitLine("=IMPORT {s}", .{
          self.data.known_modules.keys()[i.module_index]});
      },
      .literal => |a| {
        try self.emitLine("=LIT {s} \"{}\"",
          .{@tagName(a.kind), std.zig.fmtEscapes(a.content)});
      },
      .location => |loc| {
        const l = try self.push("LOC");
        try self.process(loc.name);
        if (loc.@"type") |t| try self.process(t)
        else try self.emitLine("=TYPE <none>", .{});
        if (loc.additionals) |a| {
          if (
            a.primary != null or a.varargs != null or a.varmap != null or
            a.borrow != null or a.header != null
          ) {
            const fmt = (
              AdditionalsWithGlobal{.value = a, .data = self.data}
            ).formatter();
            try self.emitLine("=FLAGS {}", .{fmt});
          }
        }
        if (loc.default) |d| {
          const dnode = try self.push("DEFAULT");
          try self.process(d);
          try dnode.pop();
        }
        try l.pop();
      },
      .map => |map| {
        const lvl = try self.push("MAP");
        try self.process(map.input);
        if (map.func) |func| {
          try self.emitLine(">FUNC", .{});
          try self.process(func);
        }
        if (map.collector) |coll| {
          try self.emitLine(">COLLECTOR", .{});
          try self.process(coll);
        }
        try lvl.pop();
      },
      .match => |_| {
        const m = try self.push("MATCH");
        // TODO
        try m.pop();
      },
      .matcher => |_| {
        const m = try self.push("MATCHER");
        // TODO
        try m.pop();
      },
      .output => |out| {
        const o = try self.push("OUTPUT");
        try self.emitLine(">NAME", .{});
        try self.process(out.name);
        if (out.schema) |schema| {
          try self.emitLine(">SCHEMA", .{});
          try self.process(schema);
        }
        try self.emitLine(">BODY", .{});
        try self.process(out.body);
        try o.pop();
      },
      .seq => |s| {
        for (s.items) |i| {
          const para = try self.push("PARA");
          try self.process(i.content);
          try para.pop();
        }
      },
      .resolved_access => |ra| {
        const racc = try self.push("RACCESS");
        try self.process(ra.base);
        for (ra.path) |item| switch (item) {
          .field => |field| {
            const param = field.t.constructor.sig.parameters[
              field.t.first_own + field.index];
            try self.emitLine("=DESCEND {s}", .{param.name});
          },
          .subscript => |node| {
            const desc = try self.push("DESCEND");
            try self.process(node);
            try desc.pop();
          },
        };
        try racc.pop();
      },
      .resolved_call => |rc| {
        const rcall = try self.push("RCALL");
        try self.process(rc.target);
        for (rc.args) |a, i| {
          try self.emitLine(">ARG {s}", .{rc.sig.parameters[i].name});
          try self.process(a);
        }
        try rcall.pop();
      },
      .resolved_symref => |res|
        try self.emitLine("=SYMREF {s}.{s}",
          .{res.sym.defined_at.source.locator.repr, res.sym.name}),
      .gen_concat => |gc| {
        const gen = try self.pushWithKey("TGEN", "Concat", null);
        try self.process(gc.inner);
        try gen.pop();
      },
      .gen_enum => |ge| {
        const gen = try self.pushWithKey("TGEN", "Enum", null);
        for (ge.values) |value| try self.process(value.node);
        try gen.pop();
      },
      .gen_intersection => |gi| {
        const gen = try self.pushWithKey("TGEN", "Intersection", null);
        for (gi.types) |item| try self.process(item.node);
        try gen.pop();
      },
      .gen_list => |gl| {
        const gen = try self.pushWithKey("TGEN", "List", null);
        try self.process(gl.inner);
        try gen.pop();
      },
      .gen_map => |gm| {
        const gen = try self.pushWithKey("TGEN", "HashMap", null);
        try self.process(gm.key);
        try self.process(gm.value);
        try gen.pop();
      },
      .gen_numeric => |gn| {
        const gen = try self.pushWithKey("TGEN", "Numeric", null);
        if (gn.min) |min| {
          try self.emitLine(">MIN", .{});
          try self.process(min);
        }
        if (gn.max) |max| {
          try self.emitLine(">MAX", .{});
          try self.process(max);
        }
        try gen.pop();
      },
      .gen_optional => |go| {
        const gen = try self.pushWithKey("TGEN", "Optional", null);
        try self.process(go.inner);
        try gen.pop();
      },
      .gen_sequence => |gs| {
        const gen = try self.pushWithKey("TGEN", "Sequence", null);
        for (gs.inner) |inner| try self.process(inner.node);
        if (gs.auto) |auto| {
          try self.emitLine(">AUTO", .{});
          try self.process(auto);
        }
        try gen.pop();
      },
      .gen_prototype => |gp| {
        const gen = try self.pushWithKey("TGEN", "Prototype", null);
        try self.process(gp.params.unresolved);
        try gen.pop();
      },
      .gen_record => |gr| {
        const gen = try self.pushWithKey("TGEN", "Record", null);
        switch (gr.fields) {
          .unresolved => |node| try self.process(node),
          .resolved   => |*res| for (res.locations) |loc| switch (loc) {
            .node   => |lnode| try self.process(lnode.node()),
            .expr   => |lexpr| try self.processExpr(lexpr),
            .value  => |lval| try self.processValue(lval.value()),
            .poison => try self.emitLine("=POISON", .{}),
          },
          .pregen => try self.processType(.{.named = gr.generated.?}),
        }
        try gen.pop();
      },
      .gen_textual => |gt| {
        const gen = try self.pushWithKey("TGEN", "Textual", null);
        try self.emitLine(">CATEGORIES", .{});
        for (gt.categories) |cat| try self.process(cat.node);
        if (gt.include_chars) |ic| {
          try self.emitLine(">INCLUDE", .{});
          try self.process(ic);
        }
        if (gt.exclude_chars) |ec| {
          try self.emitLine(">EXCLUDE", .{});
          try self.process(ec);
        }
        try gen.pop();
      },
      .gen_unique => |gu| {
        if (gu.constr_params) |params| {
          const gen = try self.pushWithKey("TGEN", "Unique", null);
          try self.process(params);
          try gen.pop();
        } else {
          try self.emitLine("=UNIQUE", .{});
        }
      },
      .root_def => |rd| {
        const r = try self.pushWithKey("ROOTDEF", @tagName(rd.kind), null);
        if (rd.kind != .library) {
          if (rd.params) |params| {
            try self.emitLine(">PARAMS", .{});
            try self.process(params);
          }
          if (rd.root) |root| {
            try self.emitLine(">ROOT", .{});
            try self.process(root);
          }
        }
        try r.pop();
      },
      .unresolved_access => |a| {
        const access = try self.push("ACCESS");
        try self.emitLine(">SUBJECT", .{});
        try self.process(a.subject);
        try self.emitLine(">NAME", .{});
        try self.process(a.name);
        try access.pop();
      },
      .unresolved_call => |uc| {
        const ucall = try self.push("UCALL");
        {
          const t = try self.push("TARGET");
          try self.process(uc.target);
          try t.pop();
        }
        for (uc.proto_args) |a| {
          const parg = try switch (a.kind) {
            .position  => self.pushWithKey("PROTO", "pos", null),
            .named     => |named| self.pushWithKey("PROTO", "name", named),
            .direct    => |direct| self.pushWithKey("PROTO", "direct", direct),
            .primary   => self.pushWithKey("PROTO", "primary", null),
            .name_expr => |node| blk: {
              const lvl = self.pushWithKey("PROTO", "name_expr", null);
              try self.emitLine(">KEY", .{});
              try self.process(node);
              try self.emitLine(">VALUE", .{});
              break :blk lvl;
            },
          };
          try self.process(a.content);
          try parg.pop();
        }
        try ucall.pop();
      },
      .unresolved_symref => |u|
        try self.emitLine("=SYMREF [{}]{s}", .{u.ns, u.name}),
      .varargs => |va| {
        const varargs = try self.push("VARARGS");
        for (va.content.items) |item| {
          try self.emitLine(">ITEM {s}", .{
            if (item.direct) @as([]const u8, "direct") else "indirect",
          });
          try self.process(item.node);
        }
        try varargs.pop();
      },
      .varmap => |vm| {
        const varmap = try self.push("VARMAP");
        for (vm.content.items) |item| {
          switch (item.key) {
            .node   => |node| {
              try self.emitLine(">KEY", .{});
              try self.process(node);
              try self.emitLine(">VALUE", .{});
            },
            .direct => try self.emitLine(">DIRECT", .{}),
          }
          try self.process(item.value);
        }
        try varmap.pop();
      },
      .vt_setter => |vs| {
        const setter = try self.push("VT_SETTER");
        try self.emitLine("=VARIABLE {s}", .{vs.v.sym().name});
        try self.emitLine(">CONTENT", .{});
        try self.process(vs.content);
        try setter.pop();
      },
      .void => try self.emitLine("=VOID", .{}),
      .poison => try self.emitLine("=POISON", .{}),
    }
  }

  fn processExprPath(
    self : *Self,
    path : []const model.Expression.Access.PathItem,
    start: model.Type,
  ) anyerror!void {
    var t = start;
    for (path) |item| switch (item) {
      .field => |field| {
        const param =
          &field.t.constructor.sig.parameters[field.t.first_own + field.index];
        try self.emitLine("=FIELD {s}", .{param.name});
        t = param.spec.t;
      },
      .subscript => |expr| {
        const subscr = try self.push("SUBSCRIPT");
        try self.processExpr(expr);
        try subscr.pop();
        t = switch (t.structural.*) {
          .concat   => |*con| con.inner,
          .list     => |*lst| lst.inner,
          .sequence => |*seq| try self.data.types.seqInnerType(seq),
          else      => unreachable,
        };
      },
    };
  }

  pub fn processExpr(self: *Self, e: *model.Expression) anyerror!void {
    switch (e.data) {
      .access => |acc| {
        const a = try self.push("ACCESS");
        try self.processExpr(acc.subject);
        try self.processExprPath(acc.path, acc.subject.expected_type);
        try a.pop();
      },
      .assignment => |ass| {
        const a = try self.push("ASSIGNMENT");
        if (ass.path.len > 0) {
          const target =
            try self.pushWithKey("TARGET", ass.target.sym().name, null);
          try self.processExprPath(ass.path, ass.target.spec.t);
          try target.pop();
        } else try self.emitLine("=TARGET {s}", .{ass.target.sym().name});
        try self.emitLine(">EXPR", .{});
        try self.processExpr(ass.rexpr);
        try a.pop();
      },
      .branches => |b| {
        const branches = try self.push("BRANCHES");
        try self.processExpr(b.condition);
        for (b.branches) |branch, i| {
          try self.emitLine(">BRANCH {}", .{i});
          try self.processExpr(branch);
        }
        try branches.pop();
      },
      .call => |call| {
        const c = try self.push("CALL");
        try self.processExpr(call.target);
        const sig = call.target.expected_type.structural.callable.sig;
        for (call.exprs) |expr, i| {
          try self.emitLine(">ARG {s}", .{sig.parameters[i].name});
          try self.processExpr(expr);
        }
        try c.pop();
      },
      .concatenation => |c| for (c) |expr| try self.processExpr(expr),
      .conversion    => |c| {
        const conv = try self.pushWithType("CONVERT", c.target_type);
        try self.processExpr(c.inner);
        try conv.pop();
      },
      .ifopt    => |ifopt| {
        const lvl = try self.push("IFOPT");
        try self.processExpr(ifopt.condition);
        if (ifopt.variable) |v| {
          try self.emitLine(">THEN |{s}|", .{v.sym().name});
        } else try self.emitLine(">THEN", .{});
        try self.processExpr(ifopt.then);
        if (ifopt.@"else") |ee| {
          try self.emitLine(">ELSE", .{});
          try self.processExpr(ee);
        }
        try lvl.pop();
      },
      .location => |loc| {
        const l = try self.push("LOC");
        try self.emitLine(">NAME", .{});
        try self.processExpr(loc.name);
        if (loc.@"type") |t| {
          try self.emitLine(">TYPE", .{});
          try self.processExpr(t);
        }
        if (loc.additionals) |a| {
          if (
            a.primary != null or a.varargs != null or a.varmap != null or
            a.borrow != null or a.header != null
          ) {
            const fmt = (
              AdditionalsWithGlobal{.value = a, .data = self.data}
            ).formatter();
            try self.emitLine("=FLAGS {}", .{fmt});
          }
        }
        if (loc.default) |d| {
          try self.emitLine(">DEFAULT", .{});
          try self.processExpr(d);
        }
        try l.pop();
      },
      .map => |map| {
        const lvl = try self.pushWithType("MAP", e.expected_type);
        try self.processExpr(map.input);
        if (map.func) |func| {
          try self.emitLine(">FUNC", .{});
          try self.processExpr(func);
        }
        try lvl.pop();
      },
      .match => |match| {
        const m = try self.push("MATCH");
        try self.processExpr(match.subject);
        var iter = match.cases.iterator();
        while (iter.next()) |item| {
          const c = try self.push("CASE");
          try self.processType(item.key_ptr.t);
          try c.pop();
          try self.processExpr(item.value_ptr.expr);
        }
        try m.pop();
      },
      .output => |output| {
        const lvl = try self.push("OUTPUT");
        try self.processExpr(output.name);
        try self.emitLine(">BODY", .{});
        try self.processExpr(output.body);
        if (output.schema) |schema| {
          try self.emitLine(">SCHEMA", .{});
          try self.processValue(schema.value());
        }
        try lvl.pop();
      },
      .tg_concat => |tgc| {
        const c = try self.push("TG_CONCAT");
        try self.processExpr(tgc.inner);
        try c.pop();
      },
      .tg_list => |tgl| {
        const l = try self.push("TG_LIST");
        try self.processExpr(tgl.inner);
        try l.pop();
      },
      .tg_map => |tgm| {
        const m = try self.push("TG_MAP");
        try self.processExpr(tgm.key);
        try self.processExpr(tgm.value);
        try m.pop();
      },
      .tg_optional => |tgo| {
        const o = try self.push("TG_OPTIONAL");
        try self.processExpr(tgo.inner);
        try o.pop();
      },
      .tg_sequence => |tgs| {
        const s = try self.push("TG_SEQUENCE");
        for (tgs.inner) |inner| try self.processExpr(inner.expr);
        if (tgs.direct) |direct| {
          try self.emitLine(">DIRECT", .{});
          try self.processExpr(direct);
        }
        if (tgs.auto) |auto| {
          try self.emitLine(">AUTO", .{});
          try self.processExpr(auto);
        }
        try s.pop();
      },
      .value    => |value| try self.processValue(value),
      .sequence => |seq| {
        const p = try self.push("SEQUENCE");
        for (seq) |item| {
          try self.emitLine(">ITEM {}", .{item.lf_after});
          try self.processExpr(item.content);
        }
        try p.pop();
      },
      .varargs => |va| {
        const varargs = try self.push("VARARGS");
        for (va.items) |item| {
          try self.emitLine(">ITEM {s}", .{
            if (item.direct) @as([]const u8, "direct") else "indirect",
          });
          try self.processExpr(item.expr);
        }
        try varargs.pop();
      },
      .varmap => |vm| {
        const varmap = try self.push("VARMAP");
        for (vm.items) |item| {
          switch (item.key) {
            .direct => try self.emitLine(">DIRECT", .{}),
            .expr => |key_expr| {
              try self.emitLine(">KEY", .{});
              try self.processExpr(key_expr);
              try self.emitLine(">VALUE", .{});
            },
          }
          try self.processExpr(item.value);
        }
        try varmap.pop();
      },
      .var_retrieval => |v| {
        try self.emitLine("=GETVAR {s}", .{v.variable.sym().name});
      },
      .poison => try self.emitLine("=POISON", .{}),
      .void   => try self.emitLine("=VOID", .{}),
    }
  }

  fn processType(self: *Self, t: model.Type) anyerror!void {
    switch (t) {
      .structural => |struc| switch (struc.*) {
        .callable => {
          const t_fmt = t.formatter();
          try self.emitLine("=TYPE {s}", .{t_fmt});
        },
        .concat => |*con| {
          const c = try self.pushWithKey("TYPE", "Concat", null);
          try self.processType(con.inner);
          try c.pop();
        },
        .hashmap => |*map| {
          const m = try self.pushWithKey("TYPE", "HashMap", null);
          try self.processType(map.key);
          try self.processType(map.value);
          try m.pop();
        },
        .intersection => |*inter| {
          const i = try self.pushWithKey("TYPE", "Intersection", null);
          if (inter.scalar) |scalar| try self.processType(scalar);
          for (inter.types) |inner| try self.processType(inner);
          try i.pop();
        },
        .list => |*lst| {
          const l = try self.pushWithKey("TYPE", "List", null);
          try self.processType(lst.inner);
          try l.pop();
        },
        .optional => |*opt| {
          const o = try self.pushWithKey("TYPE", "Optional", null);
          try self.processType(opt.inner);
          try o.pop();
        },
        .sequence => |*seq| {
          const s = try self.pushWithKey("TYPE", "Sequence", null);
          if (seq.direct) |direct| try self.processType(direct);
          for (seq.inner) |inner| try self.processType(inner.typedef());
          try s.pop();
        }
      },
      .named => |i| {
        if (i.name) |sym| try self.emitLine("=TYPE {s} {s}.{s}",
          .{@tagName(i.data), sym.defined_at.source.locator.repr, sym.name})
        else {
          const tc = try self.pushWithKey("TYPE", @tagName(i.data), null);
          switch (i.data) {
            .textual => |_| unreachable,
            .int     => |_| unreachable,
            .float   => |_| unreachable,
            .@"enum" => |en| {
              for (en.values.entries.items(.key)) |*key| {
                try self.emitLine("=ITEM {s}", .{key});
              }
            },
            .record => |*rec| {
              for (rec.constructor.sig.parameters) |*param| {
                const p = try self.pushWithKey("PARAM", param.name, null);
                try self.processType(param.spec.t);
                if (param.default) |default| try self.processExpr(default);
                try p.pop();
              }
            },
            else => try self.emitLine("=TYPE {s}", .{@tagName(i.data)}),
          }
          try tc.pop();
        }
      },
    }
  }

  fn processValue(self: *Self, v: *const model.Value) anyerror!void {
    switch (v.data) {
      .ast => |a| {
        const ast = try self.push("AST");
        try self.process(a.root);
        try ast.pop();
      },
      .block_header => |*h| {
        const hf =
          (HeaderWithGlobal{.header = h, .data = self.data}).formatter();
        try self.emitLine("=HEADER {}", .{hf});
      },
      .concat => |*con| {
        const lvl = try self.pushWithType("CONCAT", con.t.typedef());
        for (con.content.items) |item| try self.processValue(item);
        try lvl.pop();
      },
      .definition => |def| {
        const wrap = try self.pushWithKey("DEF", def.name.content, null);
        switch (def.content) {
          .func => try self.emitLine("=FUNC", .{}),
          .@"type" => |t| try self.processType(t),
        }
        try wrap.pop();
      },
      .@"enum" => |ev| {
        const t_fmt = ev.t.typedef().formatter();
        try self.emitLine("=ENUM {} \"{s}\"",
          .{t_fmt, ev.t.values.entries.items(.key)[ev.index]});
      },
      .float => |fl| {
        const t_fmt = fl.t.typedef().formatter();
        try self.emitLine("=FLOAT {} {}", .{t_fmt, fl.formatter()});
      },
      .funcref => |fr| try self.emitLine("=FUNCREF {s}.{s}",
        .{fr.func.defined_at.source.locator.repr, if (fr.func.name) |sym|
          sym.name else "<anonymous>"}),
      .int => |int| {
        const t_fmt = int.t.typedef().formatter();
        try self.emitLine("=INT {} {}", .{t_fmt, int.formatter()});
      },
      .list => |lst| {
        const l = try self.push("LIST");
        for (lst.content.items) |item| try self.processValue(item);
        try l.pop();
      },
      .location => |loc| {
        const wrap = try self.pushWithKey("LOC", loc.name.content, null);
        try self.processType(loc.spec.t);
        inline for ([_][]const u8{"primary", "varargs", "varmap", "borrow"})
            |flag| {
          if (@field(loc, flag) != null)
            try self.emitLine("=FLAG {s}", .{flag});
        }
        if (loc.default) |defexpr| {
          const default = try self.push("DEFAULT");
          try self.processExpr(defexpr);
          try default.pop();
        }
        if (loc.header) |hval| {
          const header = try self.push("HEADER");
          try self.processValue(hval.value());
          try header.pop();
        }
        try wrap.pop();
      },
      .hashmap => |_| {
        unreachable;
      },
      .output => |out| {
        const o = try self.pushWithKey("OUTPUT", out.name.content, null);
        if (out.schema) |schema| try self.processValue(schema.value());
        try self.processValue(out.body);
        try o.pop();
      },
      .prototype => |pv| try self.emitLine("=PROTO {s}", .{@tagName(pv.pt)}),
      .record => |rec| {
        const lvl = try self.pushWithType("RECORD", rec.t.typedef());
        for (rec.fields) |val, index| {
          try self.emitLine(
            ">FIELD {s}", .{rec.t.constructor.sig.parameters[index].name});
          try self.processValue(val);
        }
        try lvl.pop();
      },
      .schema => |sch| {
        const s = try self.push("SCHEMA");
        try self.processType(sch.root.t);
        try s.pop();
      },
      .schema_def => |sd| {
        const def = try self.push("SCHEMA_DEF");
        for (sd.defs) |item| try self.process(item.node());
        try self.emitLine(">ROOT", .{});
        try self.process(sd.root);
        if (sd.backends.len > 0) {
          try self.emitLine(">BACKENDS", .{});
          for (sd.backends) |item| try self.process(item.node());
        }
        try def.pop();
      },
      .schema_ext => |se| {
        const ext = try self.push("SCHEMA_EXT");
        for (se.defs) |item| try self.process(item.node());
        if (se.backends.len > 0) {
          try self.emitLine(">BACKENDS", .{});
          for (se.backends) |item| try self.process(item.node());
        }
        try ext.pop();
      },
      .seq => |seq| {
        const lvl = try self.push("SEQUENCE");
        for (seq.content.items) |item, index| {
          try self.processValue(item.content);
          if (index < seq.content.items.len - 1) {
            try self.emitLine("=SEP {}", .{item.lf_after});
          }
        }
        try lvl.pop();
      },
      .text => |txt| {
        const t_fmt = txt.t.formatter();
        try self.emitLine("=TEXT {} \"{}\"",
          .{t_fmt, std.zig.fmtEscapes(txt.content)});
      },
      .@"type" => |tv| try self.processType(tv.t),
      .void    => try self.emitLine("=VOID", .{}),
      .poison  => try self.emitLine("=POISON", .{}),
    }
  }

  fn processModule(self: *Self, module: *const model.Module) !void {
    if (module.root) |root| {
      if (root.sig().parameters.len > 0) {
        for (root.sig().parameters) |*param| {
          const p = try self.pushWithKey("PARAM", param.name, null);
          try self.processType(param.spec.t);
          if (param.default) |default| try self.processExpr(default);
          try p.pop();
        }
        try self.emitLine(">BODY", .{});
      }
      try self.processExpr(root.data.ny.body);
    } else {
      try self.emitLine("=LIBRARY", .{});
    }
  }
};

/// implements Reporter. forwards lines to the registered checker.
const ErrorEmitter = struct {
  api    : errors.Reporter,
  buffer : [1024]u8 = undefined,
  handler: *Checker,

  fn init(handler: *Checker) ErrorEmitter {
    return .{
      .api = .{
        .lexerErrorFn        = lexerError,
        .parserErrorFn       = parserError,
        .wrongItemErrorFn    = wrongItemError,
        .scalarErrorFn       = scalarError,
        .wrongIdErrorFn      = wrongIdError,
        .previousOccurenceFn = previousOccurence,
        .posChainFn          = posChain,
        .typeErrorFn         = typeError,
        .constructionErrorFn = constructionError,
        .runtimeErrorFn      = runtimeError,
        .systemNyErrorFn     = systemNyError,
        .fileErrorFn         = fileError,
      },
      .handler = handler,
    };
  }

  fn forwardError(
    self: *ErrorEmitter,
    id  : anytype,
    pos : model.Position,
  ) void {
    const line = std.fmt.bufPrint(&self.buffer, "{} - {} {s}",
      .{pos.start.formatter(), pos.end.formatter(), @tagName(id)})
      catch unreachable;
    self.handler.handle(line) catch unreachable;
  }

  fn forwardArg(
             self : *ErrorEmitter,
             name : []const u8,
    comptime fmt  : []const u8,
             value: anytype,
  ) void {
    const line = std.fmt.bufPrint(
      &self.buffer, "  {s} = " ++ fmt, .{name, value}) catch unreachable;
    self.handler.handle(line) catch unreachable;
  }

  fn forwardArgAt(
             self : *ErrorEmitter,
             name : []const u8,
             pos  : model.Position,
    comptime fmt  : []const u8,
             value: anytype,
  ) void {
    var line = (if (std.mem.eql(u8, pos.source.locator.resolver.?, "doc")) (
      std.fmt.bufPrint(&self.buffer, "  {s} = {s}", .{name, pos})
    ) else std.fmt.bufPrint(
      &self.buffer, "  {s} = {s}", .{name, pos.source.locator.repr})
    ) catch unreachable;
    if (fmt.len == 0) self.handler.handle(line) catch unreachable
    else {
      var a = std.fmt.bufPrint(self.buffer[line.len..], " " ++ fmt, .{value})
        catch unreachable;
      line.len += a.len;
      self.handler.handle(line) catch unreachable;
    }
  }

  fn lexerError(
    reporter: *errors.Reporter,
    id      : errors.LexerError,
    pos     : model.Position,
  ) void {
    @fieldParentPtr(ErrorEmitter, "api", reporter).forwardError(id, pos);
  }

  fn parserError(
    reporter: *errors.Reporter,
    id      : errors.GenericParserError,
    pos     : model.Position,
  ) void {
    @fieldParentPtr(ErrorEmitter, "api", reporter).forwardError(id, pos);
  }

  fn wrongItemError(
    reporter: *errors.Reporter,
    id      : errors.WrongItemError,
    pos     : model.Position,
    expected: []const errors.WrongItemError.ItemDescr,
    got     : errors.WrongItemError.ItemDescr,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    const expected_fmt = errors.WrongItemError.ItemDescr.formatterAll(expected);
    self.forwardArg("expected", "{}", expected_fmt);
    self.forwardArg("got", "{}", got.formatter());
  }

  fn scalarError(
    reporter: *errors.Reporter,
    id      : errors.ScalarError,
    pos     : model.Position,
    repr    : []const u8,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    self.forwardArg("repr", "{s}", repr);
  }

  fn wrongIdError(
    reporter  : *errors.Reporter,
    id        : errors.WrongIdError,
    pos       : model.Position,
    expected  : []const u8,
    got       : []const u8,
    defined_at: model.Position,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    self.forwardArg("expected", "'{s}'", expected);
    self.forwardArg("got", "'{s}'", got);
    self.forwardArgAt("defined_at", defined_at, "", void);
  }

  fn previousOccurence(
    reporter: *errors.Reporter,
    id      : errors.PreviousOccurenceError,
    repr    : []const u8,
    pos     : model.Position,
    previous: model.Position,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    self.forwardArg("repr", "{s}", repr);
    self.forwardArgAt("previous", previous, "", void);
  }

  fn posChain(
    reporter  : *errors.Reporter,
    id        : errors.PositionChainError,
    pos       : model.Position,
    referenced: []model.Position,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    for (referenced) |ref| self.forwardArgAt("referenced", ref, "", void);
  }

  fn typeError(
    reporter: *errors.Reporter,
    id      : errors.TypeError,
    types   : []const model.SpecType,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, types[0].pos);
    const t1_format = types[0].t.formatter();
    self.forwardArg("main", "{}", t1_format);
    if (types.len == 2) {
      const t2_format = types[1].t.formatter();
      self.forwardArgAt("other", types[1].pos, "{}", t2_format);
    }
  }

  fn constructionError(
    reporter: *errors.Reporter,
    id      : errors.ConstructionError,
    pos     : model.Position,
    t       : model.Type,
    repr: []const u8
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    const t_fmt = t.formatter();
    self.forwardArg("t", "{}", t_fmt);
    self.forwardArg("repr", "{s}", repr);
  }

  fn runtimeError(
    reporter: *errors.Reporter,
    id      : errors.RuntimeError,
    pos     : model.Position,
    msg     : []const u8,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    self.forwardArg("msg", "{s}", msg);
  }

  fn systemNyError(
    reporter: *errors.Reporter,
    id      : errors.SystemNyError,
    pos     : model.Position,
    msg     : []const u8,
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    self.forwardArg("msg", "{s}", msg);
  }

  fn fileError(
    reporter: *errors.Reporter,
    id      : errors.FileError,
    pos     : model.Position,
    path    : []const u8,
    message : []const u8
  ) void {
    const self = @fieldParentPtr(ErrorEmitter, "api", reporter);
    self.forwardError(id, pos);
    self.forwardArg("path", "{s}", path);
    self.forwardArg("message", "{s}", message);
  }
};

const Checker = struct {
  expected_iter: std.mem.SplitIterator(u8),
  line         : usize,
  full_output  : std.ArrayListUnmanaged(u8),
  failed       : bool,
  data         : *TestDataResolver,

  fn init(data: *TestDataResolver, name_in_input: []const u8) Checker {
    return Checker{
      .expected_iter = data.valueLines(name_in_input),
      .line = data.source.items.get(name_in_input).?.line_offset + 1,
      .full_output = .{}, .failed = false,
      .data = data,
    };
  }

  fn initErrorChecker(
    data          : *TestDataResolver,
    name_in_errors: []const u8,
  ) Checker {
    return Checker{
      .expected_iter = data.paramLines("errors", name_in_errors),
      .line          =
        data.source.params.errors.get(name_in_errors).?.line_offset + 1,
      .full_output = .{},
      .failed      = false,
      .data        = data,
    };
  }

  fn deinit(self: *@This()) void {
    self.full_output.deinit(std.testing.allocator);
  }

  fn finish(self: *@This()) !void {
    if (self.expected_iter.next()) |line| {
      if (line.len > 0 or self.expected_iter.next() != null) {
        if (!self.failed) {
          std.log.err("got less output than expected, line {} missing:\n{s}\n",
            .{self.line, line});
          self.failed = true;
        }
      }
    }
    if (self.failed) {
      std.log.err(
        \\==== Full output ====
        \\{s}
        \\
        \\
        , .{self.full_output.items});
      return Error.no_match;
    }
  }

  fn handle(self: *@This(), line: []const u8) !void {
    defer {
      self.line += 1;
      self.full_output.appendSlice(std.testing.allocator, line)
        catch unreachable;
      self.full_output.append(std.testing.allocator, '\n') catch unreachable;
    }
    const expected = self.expected_iter.next() orelse {
      if (!self.failed) {
        std.log.err(
          "got more output than expected, first unexpected line:\n  {s}",
          .{line});
        self.failed = true;
      }
      return;
    };
    if (!self.failed) {
      if (!std.mem.eql(u8, expected, line)) {
        std.log.err(
          \\Wrong output at line {}:
          \\==== expected content ====
          \\{s}
          \\
          \\===== actual content =====
          \\{s}
          \\
          \\
        , .{self.line, expected, line});
        self.failed = true;
      }
    }
  }
};

pub fn parseTest(data: *TestDataResolver) !void {
  var checker = Checker.init(data, "rawast");
  defer checker.deinit();
  var r = FileTerm.init(std.io.getStdOut().writer());
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &r.reporter,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.initMainModule(&checker.data.api, "input", .full);
  defer loader.destroy();
  const ml = try loader.finishMainAst();
  defer ml.destroy();
  const node = try ml.finalizeNode();
  try std.testing.expect(!loader.loader.data.seen_error);
  var emitter = AstEmitter.init(loader.loader.data, &checker);
  try emitter.process(node);
  try checker.finish();
}

pub fn parseErrorTest(data: *TestDataResolver) !void {
  var checker = Checker.initErrorChecker(data, "rawast");
  defer checker.deinit();
  var reporter = ErrorEmitter.init(&checker);
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &reporter.api,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.initMainModule(&checker.data.api, "input", .full);
  const ml = loader.loader.data.known_modules.values()[1].require_module;
  defer loader.destroy();
  while (!try ml.work()) {}
  try checker.finish();
}

pub fn interpretTest(data: *TestDataResolver) !void {
  var checker = Checker.init(data, "expr");
  defer checker.deinit();
  var r = FileTerm.init(std.io.getStdOut().writer());
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &r.reporter,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.startLoading(&data.api, "input");
  defer loader.destroy();
  const module = try loader.finishMainModule();
  try std.testing.expect(!loader.loader.data.seen_error);
  var emitter = AstEmitter.init(loader.loader.data, &checker);
  try emitter.processModule(module);
  try checker.finish();
}

pub fn interpretErrorTest(data: *TestDataResolver) !void {
  var checker = Checker.initErrorChecker(data, "expr");
  defer checker.deinit();
  var reporter = ErrorEmitter.init(&checker);
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &reporter.api,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.startLoading(&data.api, "input");
  if (try loader.finalize()) |doc| {
    doc.destroy();
    std.debug.print("error: expected errors, but none were emitted\n", .{});
    return error.TestUnexpectedResult;
  }
  try checker.finish();
}

pub fn loadTest(data: *TestDataResolver) !void {
  var checker = Checker.init(data, "document");
  defer checker.deinit();
  var r = FileTerm.init(std.io.getStdOut().writer());
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &r.reporter,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.startLoading(&data.api, "input");
  var iter = data.source.params.@"inline".iterator();
  while (iter.next()) |item| {
    try loader.pushArg(item.key_ptr.*, item.value_ptr.content.items);
  }
  if (try loader.finalize()) |container| {
    defer container.destroy();
    var emitter = AstEmitter.init(container.globals, &checker);
    try emitter.processValue(container.documents.items[0].body);
    try checker.finish();
  } else return error.TestUnexpectedResult;
}

pub fn loadErrorTest(data: *TestDataResolver) !void {
  var checker = Checker.initErrorChecker(data, "document");
  defer checker.deinit();
  var reporter = ErrorEmitter.init(&checker);
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &reporter.api,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.startLoading(&data.api, "input");
  var iter = data.source.params.@"inline".iterator();
  while (iter.next()) |item| {
    try loader.pushArg(item.key_ptr.*, item.value_ptr.content.items);
  }
  if (try loader.finalize()) |container| {
    container.destroy();
    std.debug.print("error: expected errors, but none were emitted\n", .{});
    return error.TestUnexpectedResult;
  }
  try checker.finish();
}

pub fn outputTest(data: *TestDataResolver) !void {
  var r = FileTerm.init(std.io.getStdErr().writer());
  var proc = try nyarna.Processor.init(
    std.testing.allocator, nyarna.default_stack_size, &r.reporter,
    &data.stdlib.api);
  defer proc.deinit();
  var loader = try proc.startLoading(&data.api, "input");
  var iter = data.source.params.@"inline".iterator();
  while (iter.next()) |item| {
    try loader.pushArg(item.key_ptr.*, item.value_ptr.content.items);
  }
  if (try loader.finalize()) |container| {
    defer container.destroy();
    try std.testing.expect(try container.process());

    for (container.documents.items) |output| {
      if (
        if (output.schema) |schema| schema.backend == null else true
      ) {
        const expected = (
          data.source.params.output.get(output.name.content)
        ) orelse {
          std.log.err("unexpected output: \"{s}\"", .{output.name.content});
          return error.TestUnexpectedResult;
        };
        switch (output.body.data) {
          .text => |*txt| try std.testing.expectEqualStrings(
            // ignore final line break
            expected.content.items[0..expected.content.items.len - 1],
            txt.content,
          ),
          else => {
            std.log.err(
              "unsupported non-text output: {s}", .{@tagName(output.body.data)});
            return error.TestUnexpectedResult;
          }
        }
      }
    }
  } else return error.TestUnexpectedResult;
}