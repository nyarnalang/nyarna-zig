const std = @import("std");
const Builder = std.build.Builder;

fn testEmitOption(
  emit_bin: bool,
  name: []const u8,
) std.build.LibExeObjStep.EmitOption {
  return if (!emit_bin) std.build.LibExeObjStep.EmitOption.default else
    std.build.LibExeObjStep.EmitOption{.emit_to = name};
}

pub fn build(b: *Builder) !void {
  // TODO: use these constants
  //const mode = b.standardReleaseOptions();
  //const target = b.standardTargetOptions(.{});
  const test_filter =
    b.option([]const u8, "test-filter", "filters tests when testing");
  const emit_bin = (
    b.option(bool, "emit_bin", "emit binaries for tests")
  ) orelse false;

  var ehgen_exe = b.addExecutable("ehgen", "build/gen_errorhandler.zig");
  ehgen_exe.main_pkg_path = ".";
  var ehgen_cmd = ehgen_exe.run();
  ehgen_cmd.cwd = ".";
  ehgen_cmd.step.dependOn(&ehgen_exe.step);

  var testgen_exe = b.addExecutable("testgen", "build/gen_tests.zig");
  testgen_exe.addPackage(.{
    .name = "tml",
    .path = .{.path = "test/tml.zig"},
  });
  var testgen_cmd = testgen_exe.run();
  testgen_cmd.cwd = "test";
  testgen_cmd.step.dependOn(&testgen_exe.step);

  const nyarna_pkg = std.build.Pkg{
    .name = "nyarna",
    .path = .{.path = "src/nyarna.zig"},
  };

  const testing_pkg = std.build.Pkg{
    .name = "testing",
    .path = .{.path = "test/testing.zig"},
    .dependencies = &.{nyarna_pkg},
  };

  var lex_test = b.addTest("test/lex_test.zig");
  lex_test.step.dependOn(&testgen_cmd.step);
  lex_test.step.dependOn(&ehgen_cmd.step);
  lex_test.addPackage(nyarna_pkg);
  lex_test.addPackage(testing_pkg);
  lex_test.setFilter(test_filter);
  lex_test.emit_bin = testEmitOption(emit_bin, "lex_test");

  var lex_test_step = b.step("lexTest", "Run lexer tests");
  lex_test_step.dependOn(&lex_test.step);

  var parse_test = b.addTest("test/parse_test.zig");
  parse_test.step.dependOn(&testgen_cmd.step);
  parse_test.step.dependOn(&ehgen_cmd.step);
  parse_test.addPackage(testing_pkg);
  parse_test.setFilter(test_filter);
  parse_test.emit_bin = testEmitOption(emit_bin, "parse_test");

  var parse_test_step = b.step("parseTest", "Run parser tests");
  parse_test_step.dependOn(&parse_test.step);

  var interpret_test = b.addTest("test/interpret_test.zig");
  interpret_test.step.dependOn(&testgen_cmd.step);
  interpret_test.step.dependOn(&ehgen_cmd.step);
  interpret_test.addPackage(testing_pkg);
  interpret_test.setFilter(test_filter);
  interpret_test.emit_bin = testEmitOption(emit_bin, "interpret_test");

  var interpret_test_step = b.step("interpretTest", "Run interpreter tests");
  interpret_test_step.dependOn(&interpret_test.step);

  var load_test = b.addTest("test/load_test.zig");
  load_test.step.dependOn(&testgen_cmd.step);
  load_test.step.dependOn(&ehgen_cmd.step);
  load_test.addPackage(testing_pkg);
  load_test.setFilter(test_filter);
  load_test.emit_bin = testEmitOption(emit_bin, "load_test");

  var load_test_step = b.step("loadTest", "Run loading tests");
  load_test_step.dependOn(&load_test.step);

  var output_test = b.addTest("test/output_test.zig");
  output_test.step.dependOn(&testgen_cmd.step);
  output_test.step.dependOn(&ehgen_cmd.step);
  output_test.addPackage(testing_pkg);
  output_test.setFilter(test_filter);
  output_test.emit_bin = testEmitOption(emit_bin, "output_test");

  var output_test_step = b.step("outputTest", "Run output tests");
  output_test_step.dependOn(&output_test.step);

  var type_test = b.addTest("test/type_test.zig");
  type_test.step.dependOn(&ehgen_cmd.step);
  type_test.addPackage(nyarna_pkg);
  type_test.setFilter(test_filter);
  type_test.emit_bin = testEmitOption(emit_bin, "type_test");

  var type_test_step = b.step("typeTest", "Run type tests");
  type_test_step.dependOn(&type_test.step);
}