const std = @import("std");
const nyarna = @import("nyarna");
const model = nyarna.model;
const Interpreter = nyarna.Interpreter;
const errors = nyarna.errors;

fn ensureLiteral(node: *model.Node,
                 kind: @typeInfo(model.Node.Literal).Struct.fields[0].field_type,
                 content: []const u8) !void {
  try std.testing.expectEqual(model.Node.Data.literal, node.data);
  try std.testing.expectEqual(kind, node.data.literal.kind);
  try std.testing.expectEqualStrings(content, node.data.literal.content);
}

fn ensureUnresSymref(node: *model.Node, ns: usize, id: []const u8) !void {
  try std.testing.expectEqual(model.Node.Data.unresolved_symref, node.data);
  try std.testing.expectEqual(ns, node.data.unresolved_symref.ns);
  try std.testing.expectEqualStrings(id, node.data.unresolved_symref.name);
}

test "parse simple line" {
  var src_meta = model.Source.Descriptor{
    .name = "helloworld",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = model.Source{
    .meta = &src_meta,
    .content = "Hello, World!\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try ensureLiteral(res, .text, "Hello, World!");
}

test "parse assignment" {
  var src_meta = model.Source.Descriptor{
    .name = "assignment",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = model.Source{
    .meta = &src_meta,
    .content = "\\foo:=(bar)\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try std.testing.expectEqual(model.Node.Data.assign, res.data);
  try ensureUnresSymref(res.data.assign.target.unresolved, 0, "foo");
  try ensureLiteral(res.data.assign.replacement, .text, "bar");
}

test "parse access" {
  var src_meta = model.Source.Descriptor{
    .name = "access",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = model.Source{
    .meta = &src_meta,
    .content = "\\a::b::c\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .locator_ctx = ".doc."
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try std.testing.expectEqual(model.Node.Data.access, res.data);
  try std.testing.expectEqual(
    model.Node.Data.access, res.data.access.subject.data);
  try std.testing.expectEqualStrings("c", res.data.access.id);
  try ensureUnresSymref(res.data.access.subject.data.access.subject, 0, "a");
  try std.testing.expectEqualStrings(
    "b", res.data.access.subject.data.access.id);
}

test "parse concat" {
  var src_meta = model.Source.Descriptor{
    .name = "access",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = model.Source{
    .meta = &src_meta,
    .content = "lorem\\a:,ipsum\\b \\c\\#dolor\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .locator_ctx = ".doc."
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try std.testing.expectEqual(model.Node.Data.concat, res.data);
  try ensureLiteral(res.data.concat.items[0], .text, "lorem");
  try ensureUnresSymref(res.data.concat.items[1], 0, "a");
  try ensureLiteral(res.data.concat.items[2], .text, "ipsum");
  try ensureUnresSymref(res.data.concat.items[3], 0, "b");
  try ensureLiteral(res.data.concat.items[4], .space, " ");
  try ensureUnresSymref(res.data.concat.items[5], 0, "c");
  try ensureLiteral(res.data.concat.items[6], .text, "#dolor");
}

test "parse paragraphs" {
  var src_meta = model.Source.Descriptor{
    .name = "paragraphs",
    .locator = ".doc.document",
    .argument = false,
  };

  var src = model.Source{
    .meta = &src_meta,
    .content = "lorem\n\nipsum\n\n\ndolor\x04",
    .offsets = .{},
    .locator_ctx = ".doc."
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try std.testing.expectEqual(model.Node.Data.paras, res.data);
  try ensureLiteral(res.data.paras.items[0].content, .text, "lorem");
  try std.testing.expectEqual(
    @as(usize, 2), res.data.paras.items[0].lf_after);
  try ensureLiteral(res.data.paras.items[1].content, .text, "ipsum");
  try std.testing.expectEqual(
    @as(usize, 3), res.data.paras.items[1].lf_after);
  try ensureLiteral(res.data.paras.items[2].content, .text, "dolor");
}

test "parse unknown call" {
  var src_meta = model.Source.Descriptor{
    .name = "unknownCall",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = model.Source{
    .meta = &src_meta,
    .content = "\\spam(egg, sausage=spam)\x04",
    .offsets = .{},
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try std.testing.expectEqual(model.Node.Data.unresolved_call, res.data);
  try ensureUnresSymref(res.data.unresolved_call.target, 0, "spam");
  try std.testing.expectEqual(
    @as(usize, 2), res.data.unresolved_call.proto_args.len);
  const p1 = &res.data.unresolved_call.proto_args[0];
  try std.testing.expectEqual(
    model.Node.UnresolvedCall.ArgKind.position, p1.kind);
  try std.testing.expectEqual(false, p1.had_explicit_block_config);
  try ensureLiteral(p1.content, .text, "egg");
  const p2 = &res.data.unresolved_call.proto_args[1];
  try std.testing.expectEqual(model.Node.UnresolvedCall.ArgKind.named, p2.kind);
  try std.testing.expectEqualStrings("sausage", p2.kind.named);
  try std.testing.expectEqual(false, p2.had_explicit_block_config);
  try ensureLiteral(p2.content, .text, "spam");
}

test "parse block" {
  var src_meta = model.Source.Descriptor{
    .name = "block",
    .locator = ".doc.document",
    .argument = false,
  };
  var src = model.Source{
    .meta = &src_meta,
    .content = "\\block:<>\n  rock\n:droggel:\n  jug\n\\end(block)\x04",
    .offsets = .{},
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var ctx = try nyarna.Context.create(
    std.testing.allocator, &r.reporter, nyarna.default_stack_size);
  defer ctx.destroy();
  var ml = try nyarna.ModuleLoader.create(ctx, &src, &.{});
  defer ml.destroy();
  var res = try ml.loadAsNode(true);
  try std.testing.expectEqual(model.Node.Data.unresolved_call, res.data);
  try ensureUnresSymref(res.data.unresolved_call.target, 0, "block");
  try std.testing.expectEqual(
    @as(usize, 2), res.data.unresolved_call.proto_args.len);
  const p1 = &res.data.unresolved_call.proto_args[0];
  try std.testing.expectEqual(
    model.Node.UnresolvedCall.ArgKind.primary, p1.kind);
  try std.testing.expectEqual(true, p1.had_explicit_block_config);
  try ensureLiteral(p1.content, .text, "rock");
  const p2 = &res.data.unresolved_call.proto_args[1];
  try std.testing.expectEqual(model.Node.UnresolvedCall.ArgKind.named, p2.kind);
  try std.testing.expectEqual(false, p2.had_explicit_block_config);
  try ensureLiteral(p2.content, .text, "jug");
}