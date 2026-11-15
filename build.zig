const std = @import("std");

const test_kinds = [_][]const u8{"lex", "parse", "interpret", "load", "output"};

pub fn build(b: *std.Build) void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const version = b.option(
    []const u8, "version", "version string reported by the CLI",
  ) orelse "0.1.0-dev";
  // if not given, the CLI uses ../share/lib relative to its executable.
  const stdlib_path = b.option(
    []const u8, "stdlib_path",
    "path where the CLI searches for the standard library by default",
  );
  const test_filters = b.option(
    []const []const u8, "test-filter", "only run tests matching this filter",
  ) orelse &.{};
  const emit_bin = b.option(
    bool, "emit_bin", "install test executables for debugging",
  ) orelse false;

  // ---------------------------------------------------------------------------
  // generators. They write into the source tree; the outputs are gitignored.

  // ids.zig imports ../model/lexing.zig, which is outside of the module path
  // if ids.zig were the module root. Therefore, we stage both files in a
  // directory with an artificial root file.
  const ids_files = b.addWriteFiles();
  _ = ids_files.addCopyFile(
    b.path("src/nyarna/errors/ids.zig"), "errors/ids.zig");
  _ = ids_files.addCopyFile(
    b.path("src/nyarna/model/lexing.zig"), "model/lexing.zig");
  const ids_root = ids_files.add(
    "ids.zig", "pub const ids = @import(\"errors/ids.zig\");\n");
  const handler_gen = b.addExecutable(.{
    .name        = "handler_gen",
    .root_module = b.createModule(.{
      .root_source_file = b.path("build/gen_errorhandler.zig"),
      .target           = b.graph.host,
      .imports          = &.{.{
        .name   = "ids",
        .module = b.createModule(.{.root_source_file = ids_root}),
      }},
    }),
  });
  const run_handler_gen = b.addRunArtifact(handler_gen);
  const gen_handler     = b.addUpdateSourceFiles();
  gen_handler.addCopyFileToSource(
    run_handler_gen.addOutputFileArg("Handler.zig"),
    "src/nyarna/errors/Handler.zig");

  const tml_host = b.createModule(.{
    .root_source_file = b.path("test/tml.zig"),
    .target           = b.graph.host,
  });
  const test_gen = b.addExecutable(.{
    .name        = "test_gen",
    .root_module = b.createModule(.{
      .root_source_file = b.path("build/gen_tests.zig"),
      .target           = b.graph.host,
      .imports          = &.{.{.name = "tml", .module = tml_host}},
    }),
  });
  const run_test_gen = b.addRunArtifact(test_gen);
  run_test_gen.addDirectoryArg(b.path("test/data"));
  const test_gen_out = run_test_gen.addOutputDirectoryArg("tests");
  const gen_tests    = b.addUpdateSourceFiles();
  for (test_kinds) |kind| {
    const name = b.fmt("{s}_test.zig", .{kind});
    gen_tests.addCopyFileToSource(
      test_gen_out.path(b, name), b.fmt("test/{s}", .{name}));
  }

  // ---------------------------------------------------------------------------
  // CLI

  const clap = b.dependency("clap", .{
    .target   = target,
    .optimize = optimize,
  });
  const generated = b.addOptions();
  generated.addOption([]const u8, "version",     version);
  generated.addOption(?[]const u8, "stdlib_path", stdlib_path);

  const cli = b.addExecutable(.{
    .name        = "nyarna",
    .root_module = b.createModule(.{
      .root_source_file = b.path("src/cli.zig"),
      .target           = target,
      .optimize         = optimize,
      .imports          = &.{
        .{.name = "clap",      .module = clap.module("clap")},
        .{.name = "generated", .module = generated.createModule()},
      },
    }),
  });
  cli.step.dependOn(&gen_handler.step);
  b.installArtifact(cli);
  b.installDirectory(.{
    .source_dir     = b.path("lib"),
    .install_dir    = .prefix,
    .install_subdir = "share/lib",
  });

  // ---------------------------------------------------------------------------
  // WASM library for the website

  const wasm_mod = b.createModule(.{
    .root_source_file = b.path("src/wasm.zig"),
    .target           = b.resolveTargetQuery(.{
      .cpu_arch = .wasm32,
      .os_tag   = .freestanding,
    }),
    .optimize = optimize,
  });
  inline for (.{"system", "meta", "Schema"}) |name| {
    wasm_mod.addAnonymousImport(
      name ++ ".ny", .{.root_source_file = b.path("lib/" ++ name ++ ".ny")});
  }
  const wasm = b.addExecutable(.{
    .name        = "wasm",
    .root_module = wasm_mod,
  });
  wasm.entry    = .disabled;
  wasm.rdynamic = true;
  wasm.step.dependOn(&gen_handler.step);
  const wasm_install = b.addInstallArtifact(wasm, .{
    .dest_dir = .{.override = .lib},
  });
  b.step("wasm", "Build the Nyarna WASM library").dependOn(&wasm_install.step);

  // ---------------------------------------------------------------------------
  // tests

  const nyarna = b.createModule(.{
    .root_source_file = b.path("src/nyarna.zig"),
    .target           = target,
    .optimize         = optimize,
  });
  const testing = b.createModule(.{
    .root_source_file = b.path("test/testing.zig"),
    .target           = target,
    .optimize         = optimize,
    .imports          = &.{.{.name = "nyarna", .module = nyarna}},
  });

  const test_step = b.step("test", "Run all tests");
  for (test_kinds) |kind| {
    const t = b.addTest(.{
      .name        = b.fmt("{s}Test", .{kind}),
      .root_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("test/{s}_test.zig", .{kind})),
        .target           = target,
        .optimize         = optimize,
        .imports          = &.{
          .{.name = "nyarna",  .module = nyarna},
          .{.name = "testing", .module = testing},
        },
      }),
      .filters = test_filters,
    });
    t.step.dependOn(&gen_handler.step);
    t.step.dependOn(&gen_tests.step);
    if (emit_bin) b.installArtifact(t);

    const run = b.addRunArtifact(t);
    // tests load the stdlib from ./lib and test data from ./test/data
    run.setCwd(b.path("."));
    const kind_step = b.step(
      b.fmt("{s}Test", .{kind}), b.fmt("Run {s} tests", .{kind}));
    kind_step.dependOn(&run.step);
    test_step.dependOn(&run.step);
  }
}
