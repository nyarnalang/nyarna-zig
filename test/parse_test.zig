const std = @import("std");
const data = @import("data");
const parse = @import("parse");
const Source = @import("source").Source;
const Context = @import("interpret").Context;
const errors = @import("errors");

fn ensureLiteral(node: *data.Node, kind: @typeInfo(data.Node.Literal).Struct.fields[0].field_type, content: []const u8) !void {
  try std.testing.expectEqual(data.Node.Data.literal, node.data);
  try std.testing.expectEqual(kind, node.data.literal.kind);
  try std.testing.expectEqualStrings(content, node.data.literal.content);
}

fn ensureUnresSymref(node: *data.Node, ns: u16, id: []const u8) !void {
  try std.testing.expectEqual(data.Node.Data.symref, node.data);
  try std.testing.expectEqual(ns, node.data.symref.unresolved.ns);
  try std.testing.expectEqualStrings(id, node.data.symref.unresolved.name);
}

test "parse simple line" {
  var src = Source{
    .content = "Hello, World!\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .name = "helloworld",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try ensureLiteral(res, .text, "Hello, World!");
}

test "parse assignment" {
  var src = Source{
    .content = "\\foo:=(bar)\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .name = "assignment",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try std.testing.expectEqual(data.Node.Data.assignment, res.data);
  try ensureUnresSymref(res.data.assignment.target.unresolved, 0, "foo");
  try ensureLiteral(res.data.assignment.replacement, .text, "bar");
}

test "parse access" {
  var src = Source{
    .content = "\\a::b::c\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .name = "access",
    .locator = ".doc.document",
    .locator_ctx = ".doc."
  };

  var r = errors.CmdLineReporter.init();
  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try std.testing.expectEqual(data.Node.Data.access, res.data);
  try std.testing.expectEqual(data.Node.Data.access, res.data.access.subject.data);
  try std.testing.expectEqualStrings("c", res.data.access.id);
  try ensureUnresSymref(res.data.access.subject.data.access.subject, 0, "a");
  try std.testing.expectEqualStrings("b", res.data.access.subject.data.access.id);
}

test "parse concat" {
  var src = Source{
    .content = "lorem\\a:,ipsum\\b \\c\\#dolor\x04",
    .offsets = .{
      .line = 0, .column = 0,
    },
    .name = "access",
    .locator = ".doc.document",
    .locator_ctx = ".doc."
  };

  var r = errors.CmdLineReporter.init();
  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try std.testing.expectEqual(data.Node.Data.concatenation, res.data);
  try ensureLiteral(res.data.concatenation.content[0], .text, "lorem");
  try ensureUnresSymref(res.data.concatenation.content[1], 0, "a");
  try ensureLiteral(res.data.concatenation.content[2], .text, "ipsum");
  try ensureUnresSymref(res.data.concatenation.content[3], 0, "b");
  try ensureLiteral(res.data.concatenation.content[4], .space, " ");
  try ensureUnresSymref(res.data.concatenation.content[5], 0, "c");
  try ensureLiteral(res.data.concatenation.content[6], .text, "#dolor");
}

test "parse paragraphs" {
  var src = Source{
    .content = "lorem\n\nipsum\n\n\ndolor\x04",
    .offsets = .{},
    .name = "paragraphs",
    .locator = ".doc.document",
    .locator_ctx = ".doc."
  };

  var r = errors.CmdLineReporter.init();
  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try std.testing.expectEqual(data.Node.Data.paragraphs, res.data);
  try ensureLiteral(res.data.paragraphs.items[0].content, .text, "lorem");
  try std.testing.expectEqual(@as(usize, 2), res.data.paragraphs.items[0].lf_after);
  try ensureLiteral(res.data.paragraphs.items[1].content, .text, "ipsum");
  try std.testing.expectEqual(@as(usize, 3), res.data.paragraphs.items[1].lf_after);
  try ensureLiteral(res.data.paragraphs.items[2].content, .text, "dolor");
}

test "parse unknown call" {
  var src = Source{
    .content = "\\spam(egg, sausage=spam)\x04",
    .offsets = .{},
    .name = "unknownCall",
    .locator = ".doc.document",
    .locator_ctx = ".doc.",
  };

  var r = errors.CmdLineReporter.init();
  var p = parse.Parser.init();
  var ctx = try Context.init(std.testing.allocator, &r.reporter);
  defer ctx.deinit().deinit();
  var res = try p.parseSource(&src, &ctx);
  try std.testing.expectEqual(data.Node.Data.unresolved_call, res.data);
  try ensureUnresSymref(res.data.unresolved_call.target, 0, "spam");
  try std.testing.expectEqual(@as(usize, 2), res.data.unresolved_call.params.len);
  const p1 = &res.data.unresolved_call.params[0];
  try std.testing.expectEqual(data.Node.UnresolvedCall.ParamKind.position, p1.kind);
  try std.testing.expectEqual(false, p1.had_explicit_block_config);
  try ensureLiteral(p1.content, .text, "egg");
  const p2 = &res.data.unresolved_call.params[1];
  try std.testing.expectEqual(data.Node.UnresolvedCall.ParamKind.named, p2.kind);
  try std.testing.expectEqualStrings("sausage", p2.kind.named);
  try std.testing.expectEqual(false, p2.had_explicit_block_config);
  try ensureLiteral(p2.content, .text, "spam");
}