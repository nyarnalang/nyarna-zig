const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) !void {
  // TODO: use these constants
  //const mode = b.standardReleaseOptions();
  //const target = b.standardTargetOptions(.{});
  const test_filter = b.option([]const u8, "test-filter", "filters tests when testing");

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

  const errors_pkg = std.build.Pkg{
    .name = "errors",
    .path = .{.path = "errors_generated.zig"},
  };

  const nyarna_pkg = std.build.Pkg{
    .name = "nyarna",
    .path = .{.path = "nyarna.zig"},
    .dependencies = &.{errors_pkg},
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

  var lex_test_step = b.step("lexTest", "Run lexer tests");
  lex_test_step.dependOn(&lex_test.step);

  var parse_test = b.addTest("test/parse_test.zig");
  parse_test.step.dependOn(&testgen_cmd.step);
  parse_test.step.dependOn(&ehgen_cmd.step);
  parse_test.addPackage(testing_pkg);
  parse_test.setFilter(test_filter);

  var parse_test_step = b.step("parseTest", "Run parser tests");
  parse_test_step.dependOn(&parse_test.step);

  var parse_test_orig = b.addTest("test/parse_test_orig.zig");
  parse_test_orig.step.dependOn(&ehgen_cmd.step);
  parse_test_orig.addPackage(testing_pkg);
  parse_test_orig.addPackage(nyarna_pkg);
  parse_test_orig.addPackage(errors_pkg);
  parse_test_orig.setFilter(test_filter);

  var parse_test_orig_step = b.step("parseTestOrig", "Run original parser tests");
  parse_test_orig_step.dependOn(&parse_test_orig.step);
}