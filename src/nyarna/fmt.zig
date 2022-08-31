//! this module implements formatting of model data. mostly for debugging.

const std = @import("std");

const Globals = @import("Globals.zig");
const nyarna  = @import("../nyarna.zig");

const Expression = nyarna.model.Expression;
const Node       = nyarna.model.Node;
const Type       = nyarna.model.Type;
const Value      = nyarna.model.Value;

const EncodedCharacter = @import("unicode.zig").EncodedCharacter;

pub fn formatAdditionals(
           self   : *const Node.Location.Additionals,
  comptime fmt    : []const u8,
           options: std.fmt.FormatOptions,
           writer : anytype,
) !void {
  try writer.writeByte('{');
  var first = true;
  inline for ([_][]const u8{"primary", "varargs", "varmap", "borrow"}) |f| {
    if (@field(self, f) != null) {
      if (first) first = false else try writer.writeAll(", ");
      try writer.writeAll(f);
    }
  }
  try writer.writeAll("}");
  if (self.header) |h| try formatBlockHeader(h, fmt, options, writer);
}

pub fn formatBlockConfig(
           self  : nyarna.model.BlockConfig,
  comptime _     : []const u8,
           _     : std.fmt.FormatOptions,
           writer: anytype,
) !void {
  try writer.writeAll(":<");
  var first = true;
  for (self.map) |*item| {
    if (item.to == 0) {
      if (first) first = false else try writer.writeAll(", ");
      const ec = EncodedCharacter.init(item.from);
      try writer.print("off {s}", .{ec.repr()});
    }
  }
  for (self.map) |*item| {
    if (item.from == 0) {
      if (first) first = false else try writer.writeAll(", ");
      const ec = EncodedCharacter.init(item.to);
      try writer.print("csym {s}", .{ec.repr()});
    }
  }
  for (self.map) |*item| {
    if (item.from != 0 and item.to != 0) {
      if (first) first = false else try writer.writeAll(", ");
      const fc = EncodedCharacter.init(item.from);
      const tc = EncodedCharacter.init(item.to);
      try writer.print("map {s} {s}", .{fc.repr(), tc.repr()});
    }
  }
  if (self.full_ast) |_| {
    if (first) first = false else try writer.writeAll(", ");
    try writer.writeAll("fullast");
  }
  if (self.syntax) |def| {
    if (first) first = false else try writer.writeAll(", ");
    // TODO: user-define syntaxes
    try writer.print("syntax {s}", .{switch (def.index) {
      0 => @as([]const u8, "locations"), 1 => "definitions",
      else => unreachable
    }});
  }
  try writer.writeByte('>');
}

pub fn formatBlockHeader(
           self   : *const Value.BlockHeader,
  comptime fmt    : []const u8,
           options: std.fmt.FormatOptions,
           writer : anytype,
) !void {
  if (self.config) |config| try formatBlockConfig(config, fmt, options, writer);
  if (self.swallow_depth) |swallow_depth| {
    try if (swallow_depth > 0) (
      writer.print(":{}>", .{swallow_depth})
    ) else writer.writeAll(":>");
  } else if (self.config == null) try writer.writeByte(':');
}

pub fn IndentingFormatter(comptime T: type) type {
  return struct {
    fn level(
      writer: anytype,
      depth: usize,
      data: *Globals,
    ) Level(@TypeOf(writer)) {
      return .{.writer = writer, .depth = depth, .data = data};
    }

    fn Level(comptime Writer: type) type {
      return struct {
        writer: Writer,
        depth : usize,
        data  : *Globals,
        state : enum {initial, args, braces} = .initial,

        fn id(
                   self : @This(),
          comptime sym  : []const u8,
                   value: []const u8,
        ) !void {
          try self.writer.writeAll(sym);
          var capitalize = true;
          for (value) |chr| {
            if (chr == '_') {
              capitalize = true;
            } else if (capitalize) {
              try self.writer.writeByte(chr - ('a' - 'A'));
              capitalize = false;
            } else try self.writer.writeByte(chr);
          }
        }

        fn close(self: @This()) !void {
          switch (self.state) {
            .initial => try self.writer.writeAll("()"),
            .args    => try self.writer.writeByte(')'),
            .braces  => {
              try self.writer.writeByte('\n');
              var i: usize = 0; while (i < self.depth) : (i += 1) {
                try self.writer.writeAll("  ");
              }
              try self.writer.writeByte('}');
            }
          }
        }

        fn arg(
                   self: *@This(),
                   name: ?[]const u8,
          comptime fmt : []const u8,
                   args: anytype,
        ) !void {
          switch (self.state) {
            .initial => try self.writer.writeByte('('),
            .args    => try self.writer.writeAll(", "),
            .braces  => unreachable,
          }
          if (name) |content| try self.writer.print("{s} = ", .{content});
          try self.writer.print(fmt, args);
          self.state = .args;
        }

        fn child(self: *@This(), name: ?[]const u8, value: anytype) !void {
          switch (self.state) {
            .initial => try self.writer.writeAll("{\n"),
            .args    => try self.writer.writeAll("){\n"),
            .braces  => try self.writer.writeByte('\n'),
          }
          const child_fmt = IndentingFormatter(@TypeOf(value)).init(
            value, self.depth + 1, self.data);
          var i: usize = 0; while (i < child_fmt.depth) : (i += 1) {
            try self.writer.writeAll("  ");
          }
          if (name) |content| try self.writer.print("{s}: ", .{content});
          try self.writer.print("{}", .{child_fmt});
          self.state = .braces;
        }

        fn innerLvl(self: *@This(), name: ?[]const u8) !@This() {
          switch (self.state) {
            .initial => try self.writer.writeAll("{\n"),
            .args    => try self.writer.writeAll("){\n"),
            .braces  => try self.writer.writeByte('\n'),
          }
          const ret = level(self.writer, self.depth + 1, self.data);
          var i: usize = 0; while (i < ret.depth) : (i += 1) {
            try self.writer.writeAll("  ");
          }
          if (name) |content| try self.writer.print("{s}: ", .{content});
          return ret;
        }
      };
    }

    payload: T,
    depth  : usize,
    data   : *Globals,

    pub fn init(payload: T, depth: usize, data: *Globals) @This() {
      return .{.payload = payload, .depth = depth, .data = data};
    }

    pub fn format(
               self   : @This(),
      comptime fmt    : []const u8,
               options: std.fmt.FormatOptions,
               writer : anytype,
    ) @TypeOf(writer).Error!void {
      _ = options;
      _ = fmt;
      var lvl = level(writer, self.depth, self.data);
      switch (T) {
        *Node       => try self.formatNode(self.payload, &lvl),
        *Expression => try self.formatExpr(self.payload, &lvl),
        *Value      => try self.formatValue(self.payload, &lvl),
        else        => unreachable,
      }
      try lvl.close();
    }

    fn formatVar(
      variable: anytype,
      lvl     : anytype,
    ) @TypeOf(lvl.writer).Error!void {
      switch (variable) {
        .def => |def| {
          try lvl.arg(null, "[{}]{s}", .{def.ns, def.name});
        },
        .sym => |sym| {
          try lvl.arg(null, "{s}.{s}", .{
            sym.sym().defined_at.source.locator.repr, sym.sym().name,
          });
        },
        .none => {},
      }
    }

    fn formatLocations(
      comptime name: []const u8,
               list: anytype,
               lvl : anytype,
    ) @TypeOf(lvl.writer).Error!void {
      switch (list.*) {
        .unresolved => |u| try lvl.child(name, u),
        .resolved   => |r| {
          var params_lvl = try lvl.innerLvl("params");
          for (r.locations) |ref| switch (ref) {
            .node   => |n| try params_lvl.child(null, n.node()),
            .expr   => |e| try params_lvl.child(null, e),
            .value  => |v| try params_lvl.child(null, v),
            .poison => try params_lvl.child("poison", .{}),
          };
          try params_lvl.close();
        },
        .pregen => unreachable,
      }
    }

    fn formatNode(
      self: @This(),
      node: *Node,
      lvl : anytype,
    ) @TypeOf(lvl.writer).Error!void {
      switch (node.data) {
        .expression => |expr| return self.formatExpr(expr, lvl),
        else => try lvl.id("⊙", @tagName(node.data)),
      }
      switch (node.data) {
        .assign => |a| {
          switch (a.target) {
            .resolved   => |r| {
              try lvl.arg("target", "{s}", .{r.target.sym().name});
            },
            .unresolved => |u| try lvl.child("target", u),
          }
          try lvl.child("replace", a.replacement);
        },
        .backend => |b| {
          if (b.vars) |vars| try lvl.child("vars", vars);
          if (b.funcs.len > 0) {
            var inner = try lvl.innerLvl("funcs");
            for (b.funcs) |func| try inner.child(null, func.node());
            try inner.close();
          }
          if (b.body) |body| try lvl.child("body", body.root);
        },
        .builtingen => |bg| {
          switch (bg.returns) {
            .node => |rnode| try lvl.child(null, rnode),
            .expr => |expr|  try lvl.child(null, expr),
          }
          try formatLocations("params", &bg.params, lvl);
        },
        .capture => |c| {
          for (c.vars) |v| try lvl.arg(null, "[{}]{s}", .{v.ns, v.name});
          try lvl.child(null, c.content);
        },
        .concat => |c| for (c.items) |item| try lvl.child(null, item),
        .definition => |d| {
          try lvl.arg(null, "{s}", .{d.name.content});
          try lvl.child(null, d.content);
        },
        .expression => unreachable,
        .@"for" => |f| {
          for (f.captures) |c| try lvl.arg(null, "[{}]{s}", .{c.ns, c.name});
          try lvl.child("input", f.input);
          if (f.collector) |coll| try lvl.child("collector", coll);
          try lvl.child("body", f.body);
        },
        .funcgen => |fg| {
          if (fg.returns) |ret| try lvl.child("returns", ret);
          try formatLocations("params", &fg.params, lvl);
          try lvl.child("body", fg.body);
        },
        .highlight => |hl| {
          try lvl.child("syntax", hl.syntax);
          for (hl.renderers) |renderer| {
            var render_lvl = try lvl.innerLvl(null);
            try render_lvl.id("", "Renderer");
            try render_lvl.arg(null, "{s}", .{renderer.name});
            try formatVar(renderer.variable, &render_lvl);
            try render_lvl.child(null, renderer.content.root);
            try render_lvl.close();
          }
        },
        .@"if" => |i| {
          try lvl.child("condition", i.condition);
          var then_lvl = try lvl.innerLvl(null);
          try then_lvl.id("", "then");
          for (i.then.capture) |c| {
            try then_lvl.arg(null, "[{}]{s}", .{c.ns, c.name});
          }
          try then_lvl.child(null, i.then.root);
          try then_lvl.close();
          if (i.@"else") |e| {
            var else_lvl = try lvl.innerLvl(null);
            try else_lvl.id("", "else");
            try else_lvl.child(null, e);
            try else_lvl.close();
          }
        },
        .import => |i| try lvl.arg(
          null, "{s}", .{self.data.known_modules.keys()[i.module_index]}),
        .literal => |l| {
          try lvl.arg(null, "{s}", .{@tagName(l.kind)});
          try lvl.arg(null, "\"{}\"", .{std.zig.fmtEscapes(l.content)});
        },
        .location => |l| {
          if (l.additionals) |a| try lvl.arg("flags", "{}", .{a.formatter()});
          try lvl.child("name", l.name);
          if (l.@"type") |t| try lvl.child("type", t);
          if (l.default) |d| try lvl.child("default", d);
        },
        .map => |m| {
          try lvl.child("input", m.input);
          if (m.func) |f| try lvl.child("func", f);
          if (m.collector) |c| try lvl.child("collector", c);
        },
        .match => |m| {
          try lvl.child("subject", m.subject);
          for (m.cases) |c| {
            var case_lvl = try lvl.innerLvl(null);
            try case_lvl.id("", "case");
            try formatVar(c.variable, &case_lvl);
            try case_lvl.child("type", c);
            try case_lvl.child("body", c.content.root);
            try case_lvl.close();
          }
        },
        .matcher => |m| {
          for (m.body.cases) |c| {
            var case_lvl = try lvl.innerLvl(null);
            try case_lvl.id("", "case");
            try formatVar(c.variable, &case_lvl);
            try case_lvl.child("type", c);
            try case_lvl.child("body", c.content.root);
            try case_lvl.close();
          }
        },
        .output => |o| {
          try lvl.child("name", o.name);
          if (o.schema) |s| try lvl.child("schema", s);
          try lvl.child("body", o.body);
        },
        .seq => |s| {
          for (s.items) |i| try lvl.child(null, i.content);
        },
        .resolved_access => |ra| {
          try lvl.child("base", ra.base);
          for (ra.path) |i| switch (i) {
            .field => |f| {
              const param = f.t.constructor.sig.parameters[
                f.t.first_own + f.index];
              var f_lvl = try lvl.innerLvl(null);
              try f_lvl.id("", "field");
              try f_lvl.arg(null, "{s}", .{param.name});
              try f_lvl.close();
            },
            .subscript => |s| try lvl.child(null, s),
          };
        },
        .resolved_call => |rc| {
          try lvl.child("target", rc.target);
          var arg_lvl = try lvl.innerLvl("args");
          for (rc.args) |a, i| {
            try arg_lvl.child(rc.sig.parameters[i].name, a);
          }
          try arg_lvl.close();
        },
        .resolved_symref => |rs| {
          try lvl.arg(null, "{s}.{s}", .{
            rs.sym.defined_at.source.locator.repr, rs.sym.name
          });
        },
        .gen_concat => |gc| try lvl.child(null, gc.inner),
        .gen_enum => |ge| {
          for (ge.values) |v| try lvl.child(null, v.node);
        },
        .gen_intersection => |gi| {
          for (gi.types) |t| try lvl.child(null, t.node);
        },
        .gen_list => |gl| {
          try lvl.child(null, gl.inner);
        },
        .gen_map => |gm| {
          try lvl.child("key", gm.key);
          try lvl.child("value", gm.value);
        },
        .gen_numeric => |gn| {
          try lvl.child("backend", gn.backend);
          if (gn.min) |min| try lvl.child("min", min);
          if (gn.max) |max| try lvl.child("max", max);
          // TODO: suffixes
        },
        .gen_optional => |go| {
          try lvl.child(null, go.inner);
        },
        .gen_sequence => |gs| {
          {
            var inner_lvl = try lvl.innerLvl("inner");
            for (gs.inner) |i| try inner_lvl.child(null, i.node);
            try inner_lvl.close();
          }
          if (gs.auto) |a| try lvl.child("auto", a);
        },
        .gen_prototype => |gp| {
          try lvl.child(null, gp.params.unresolved);
        },
        .gen_record => |gr| {
          switch (gr.fields) {
            .unresolved => |fnode| try lvl.child(null, fnode),
            .resolved   => |*res| for (res.locations) |loc| switch (loc) {
              .node   => |lnode| try lvl.child(null, lnode.node()),
              .expr   => |lexpr| try lvl.child(null, lexpr),
              .value  => |lval|  try lvl.child(null, lval.value()),
              .poison => try lvl.child("poison", .{}),
            },
            .pregen => try lvl.child(null, Type{.named = gr.generated.?}),
          }
        },
        .gen_textual => |gt| {
          if (gt.include_chars) |i| try lvl.child("include", i);
          if (gt.exclude_chars) |e| try lvl.child("exclude", e);
          var cat_lvl = try lvl.innerLvl("categories");
          for (gt.categories) |c| try cat_lvl.child(null, c.node);
          try cat_lvl.close();
        },
        .gen_unique => |gu| {
          if (gu.constr_params) |p| {
            try lvl.child(null, p);
          }
        },
        .root_def => |rd| {
          if (rd.kind != .library) {
            if (rd.params) |params| try lvl.child("params", params);
            if (rd.root) |root| try lvl.child("root", root);
          }
        },
        .unresolved_access => |ua| {
          try lvl.child("subject", ua.subject);
          try lvl.child("name", ua.name);
        },
        .unresolved_call => |uc| {
          try lvl.child("target", uc.target);
          var arg_lvl = try lvl.innerLvl("args");
          for (uc.proto_args) |a| switch (a.kind) {
            .position  => try arg_lvl.child(null, a.content),
            .named     => |named|  try arg_lvl.child(named, a.content),
            .direct    => |direct| try arg_lvl.child(direct, a.content),
            .primary   => try arg_lvl.child("[primary]", a.content),
            .name_expr => |nnode| {
              var expr_lvl = try arg_lvl.innerLvl(null);
              try expr_lvl.id("", "expr");
              try expr_lvl.child("name", nnode);
              try expr_lvl.child("arg", a.content);
              try expr_lvl.close();
            },
          };
          try arg_lvl.close();
        },
        .unresolved_symref => |us|
          try lvl.arg(null, "[{}]{s}", .{us.ns, us.name}),
        .varargs => |va| for (va.content.items) |item| {
          try lvl.child(if (item.direct) ":=" else null, item.node);
        },
        .varmap => |vm| for (vm.content.items) |item| {
          switch (item.key) {
            .node => |knode| {
              var pair_lvl = try lvl.innerLvl(null);
              try pair_lvl.id("", "pair");
              try pair_lvl.child("key", knode);
              try pair_lvl.child("value", item.value);
              try pair_lvl.close();
            },
            .direct => try lvl.child(":=", item.value),
          }
        },
        .vt_setter => |vs| {
          try lvl.arg(null, "{s}", .{vs.v.sym().name});
          try lvl.child(null, vs.content);
        },
        .void, .poison => {},
      }
    }

    fn formatExprPath(
      self : @This(),
      path : []const Expression.Access.PathItem,
      start: Type,
      lvl  : anytype,
    ) @TypeOf(lvl.writer).Error!void {
      var t = start;
      for (path) |item| switch (item) {
        .field => |f| {
          const param =
            &f.t.constructor.sig.parameters[f.t.first_own + f.index];
          var field_lvl = try lvl.innerLvl(null);
          try field_lvl.id("", "field");
          try field_lvl.arg(null, "{s}", .{param.name});
          try field_lvl.close();
          t = param.spec.t;
        },
        .subscript => |expr| {
          try lvl.child(null, expr);
          t = switch (t.structural.*) {
            .concat   => |con| con.inner,
            .list     => |lst| lst.inner,
            .sequence => |*seq|
              self.data.types.seqInnerType(seq) catch unreachable,
            else => unreachable,
          };
        },
      };
    }

    fn formatExpr(
      self: @This(),
      expr: *Expression,
      lvl : anytype,
    ) @TypeOf(lvl.writer).Error!void {
      switch (expr.data) {
        .value => |val| return self.formatValue(val, lvl),
        else   => try lvl.id("⊗", @tagName(expr.data)),
      }
      switch (expr.data) {
        .access => |a| {
          try lvl.child("subject", a.subject);
          try self.formatExprPath(a.path, a.subject.expected_type, lvl);
        },
        .assignment => |a| {
          try lvl.arg("target", "{s}", .{a.target.sym().name});
          try self.formatExprPath(a.path, a.target.spec.t, lvl);
          try lvl.child("expr", a.rexpr);
        },
        .branches => |b| {
          try lvl.child("condition", b.condition);
          const et = b.condition.expected_type.named.data.@"enum";
          var b_lvl = try lvl.innerLvl("branches");
          for (b.branches) |branch, i| {
            try b_lvl.child(et.values.keys()[i], branch);
          }
          try b_lvl.close();
        },
        .call => |c| {
          try lvl.child("target", c.target);
          const sig = c.target.expected_type.structural.callable.sig;
          var arg_lvl = try lvl.innerLvl("args");
          for (c.exprs) |aexpr, i| {
            try arg_lvl.child(sig.parameters[i].name, aexpr);
          }
          try arg_lvl.close();
        },
        .concatenation => |c| for (c) |item| try lvl.child(null, item),
        .conversion => |c| {
          try lvl.arg(null, "{}", .{c.target_type.formatter()});
          try lvl.child(null, c.inner);
        },
        .ifopt => |i| {
          if (i.variable) |v| try lvl.arg(null, "{s}", .{v.sym().name});
          try lvl.child("condition", i.condition);
          try lvl.child("then", i.then);
          if (i.@"else") |e| try lvl.child("else", e);
        },
        .location => |l| {
          if (l.additionals) |a| try lvl.arg("flags", "{}", .{a.formatter()});
          try lvl.child("name", l.name);
          if (l.@"type") |t| try lvl.child("type", t);
          if (l.default) |d| try lvl.child("default", d);
        },
        .map => |m| {
          try lvl.child("input", m.input);
          if (m.func) |f| try lvl.child("func", f);
        },
        .match => |m| {
          try lvl.child("subject", m.subject);
          var iter = m.cases.iterator();
          while (iter.next()) |item| {
            var case_lvl = try lvl.innerLvl(null);
            try case_lvl.id("", "case");
            try case_lvl.child("type", item.key_ptr.t);
            try case_lvl.child("body", item.value_ptr.expr);
            try case_lvl.close();
          }
        },
        .output => |o| {
          try lvl.child("name", o.name);
          try lvl.child("body", o.body);
          if (o.schema) |s| try lvl.child("schema", s.value());
        },
        .tg_concat => |tc| try lvl.child(null, tc.inner),
        .tg_list   => |tl| try lvl.child(null, tl.inner),
        .tg_map    => |tm| {
          try lvl.child("key", tm.key);
          try lvl.child("value", tm.value);
        },
        .tg_optional => |to| try lvl.child(null, to.inner),
        .tg_sequence => |ts| {
          for (ts.inner) |inner| try lvl.child(null, inner.expr);
          if (ts.direct) |direct| try lvl.child(":=", direct);
          if (ts.auto) |auto| try lvl.child("auto", auto);
        },
        .value => unreachable,
        .sequence => |s| for (s) |item, index| {
          try lvl.child(null, item.content);
          if (index != s.len - 1) {
            var sep_lvl = try lvl.innerLvl(null);
            try sep_lvl.id("", "separator");
            try sep_lvl.arg(null, "{}", .{item.lf_after});
            try sep_lvl.close();
          }
        },
        .varargs => |va| for (va.items) |item| {
          try lvl.child(if (item.direct) ":=" else null, item.expr);
        },
        .varmap => |vm| for (vm.items) |item| {
          switch (item.key) {
            .direct => try lvl.child(":=", item.value),
            .expr   => |key_expr| {
              var pair_lvl = try lvl.innerLvl(null);
              try pair_lvl.id("", "pair");
              try pair_lvl.child("key", key_expr);
              try pair_lvl.child("value", item.value);
              try pair_lvl.close();
            }
          }
        },
        .var_retrieval => |vr| {
          try lvl.arg(null, "{s}", .{vr.variable.sym().name});
        },
        .poison, .void => {},
      }
    }

    fn formatValue(
      self : @This(),
      value: *Value,
      lvl  : anytype,
    ) @TypeOf(lvl.writer).Error!void {
      switch (value.data) {
        .ast => |a| return self.formatNode(a.root, lvl),
        else => try lvl.id("□", @tagName(value.data)),
      }
      switch (value.data) {
        .ast => unreachable,
        .block_header => |*bh| try lvl.arg(null, "{}", .{bh.formatter()}),
        .concat => |c| for (c.content.items) |item| try lvl.child(null, item),
        .definition => |d| {
          try lvl.arg(null, "{s}", .{d.name.content});
          switch (d.content) {
            .func => |func| if (func.name) |name| {
              try lvl.arg("func", "{s}.{s}", .{
                name.defined_at.source.locator.repr, name.name,
              });
            } else try lvl.arg("func", "<anon>", .{}),
            .@"type" => |t| {
              try lvl.arg("type", "{}", .{t.formatter()});
            },
          }
        },
        .@"enum" => |ev| {
          try lvl.arg(null, "{}", .{ev.t.typedef().formatter()});
          try lvl.arg(
            null, "{s}", .{ev.t.values.entries.items(.key)[ev.index]});
        },
        .float => |fl| {
          try lvl.arg(null, "{}", .{fl.t.typedef().formatter()});
          try lvl.arg(null, "{}", .{fl.formatter()});
        },
        .funcref => |fr| try lvl.arg(null, "{s}.{s}", .{
          fr.func.defined_at.source.locator.repr,
          if (fr.func.name) |sym| sym.name else "<anon>"
        }),
        .int => |int| {
          try lvl.arg(null, "{}", .{int.t.typedef().formatter()});
          try lvl.arg(null, "{}", .{int.formatter()});
        },
        .list => |lst| for (lst.content.items) |item| try lvl.child(null, item),
        .location => |loc| {
          try lvl.arg(null, "{}", .{loc.spec.t.formatter()});
          inline for (
            [_][]const u8{"primary", "varargs", "varmap", "borrow"}
          ) |flag| {
            if (@field(loc, flag) != null) try lvl.arg(null, "{s}", .{flag});
          }
          if (loc.default) |defexpr| try lvl.child("default", defexpr);
          if (loc.header) |hval| try lvl.child("header", hval.value());
        },
        .hashmap => unreachable, // TODO
        .output => |o| {
          try lvl.arg(null, "{s}", .{o.name.content});
          if (o.schema) |schema| try lvl.child("schema", schema.value());
          try lvl.child("body", o.body);
        },
        .prototype => |pv| try lvl.arg(null, "{s}", .{@tagName(pv.pt)}),
        .record => |rec| {
          try lvl.arg(null, "{}", .{rec.t.typedef().formatter()});
          for (rec.fields) |val, index| {
            try lvl.child(rec.t.constructor.sig.parameters[index].name, val);
          }
        },
        .schema => |sch| try lvl.arg(null, "{}", .{sch.root.t.formatter()}),
        .schema_def => |sd| {
          try lvl.child("root", sd.root);
          for (sd.defs) |item| try lvl.child(null, item.node());
          if (sd.backends.len > 0) {
            var b_lvl = try lvl.innerLvl("backends");
            for (sd.backends) |b| try b_lvl.child(null, b.node());
            try b_lvl.close();
          }
        },
        .schema_ext => |se| {
          for (se.defs) |item| try lvl.child(null, item.node());
          if (se.backends.len > 0) {
            var b_lvl = try lvl.innerLvl("backends");
            for (se.backends) |b| try b_lvl.child(null, b.node());
            try b_lvl.close();
          }
        },
        .seq => |seq| for (seq.content.items) |item, index| {
          try lvl.child(null, item.content);
          if (index < seq.content.items.len - 1) {
            var lf_lvl = try lvl.innerLvl(null);
            try lf_lvl.id("", "separator");
            try lf_lvl.arg(null, "{}", .{item.lf_after});
            try lf_lvl.close();
          }
        },
        .text => |txt| {
          try lvl.arg(null, "{}", .{txt.t.formatter()});
          try lvl.arg(null, "\"{}\"", .{std.zig.fmtEscapes(txt.content)});
        },
        .@"type" => |tv| try lvl.arg(null, "{}", .{tv.t.formatter()}),
        .void, .poison => {},
      }
    }
  };
}