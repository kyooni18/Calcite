import Foundation
import XCTest

@testable import EditorServices

final class SingleFileExecutionPlanTests: XCTestCase {
  func testKnownExecutableLanguagesProduceRunPlans() throws {
    let cases: [(String, String)] = [
      ("main.swift", "print(1)\n"),
      ("main.c", "int main(void) { return 0; }\n"),
      ("main.cpp", "int main() { return 0; }\n"),
      ("main.m", "int main(void) { return 0; }\n"),
      ("main.rs", "fn main() {}\n"),
      ("main.go", "package main\nfunc main() {}\n"),
      ("main.py", "print(1)\n"),
      ("main.js", "console.log(1)\n"),
      ("main.ts", "console.log(1)\n"),
      ("Main.java", "public class Main { public static void main(String[] args) {} }\n"),
      ("main.kt", "fun main() {}\n"),
      ("main.lua", "print(1)\n"),
      ("main.rb", "puts 1\n"),
      ("main.php", "<?php echo 1;\n"),
      ("main.sh", "#!/bin/sh\necho 1\n"),
      ("main.pl", "print 1;\n"),
      ("main.r", "print(1)\n"),
      ("main.dart", "void main() {}\n"),
      ("main.jl", "println(1)\n"),
      ("main.nim", "echo 1\n"),
      ("main.hs", "main = print 1\n"),
      ("main.ml", "print_int 1;;\n"),
      ("main.exs", "IO.puts(1)\n"),
      ("main.erl", "#!/usr/bin/env escript\nmain(_) -> ok.\n"),
      ("main.scala", "@main def main = println(1)\n"),
      ("main.clj", "(println 1)\n"),
      ("main.groovy", "println 1\n"),
      ("main.fsx", "printfn \"1\"\n"),
      ("main.cs", "System.Console.WriteLine(1);\n"),
      ("main.zig", "pub fn main() void {}\n"),
    ]

    try withTemporaryDirectory { directory in
      for (name, contents) in cases {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let plan = try XCTUnwrap(
          EditorBuildDiscovery.singleFilePlan(fileURL: url),
          "Expected a single-file plan for \(name)"
        )
        XCTAssertNotNil(plan.command(for: .run), "Expected a run command for \(name)")
      }
    }
  }

  func testCompiledArtifactsUseCalciteCacheInsteadOfSourceDirectory() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("main.swift")
      try "print(1)\n".write(to: source, atomically: true, encoding: .utf8)
      let plan = try XCTUnwrap(EditorBuildDiscovery.singleFilePlan(fileURL: source))
      let run = try XCTUnwrap(plan.command(for: .run))
      XCTAssertTrue(run.executable.contains("Calcite"))
      XCTAssertTrue(run.executable.contains("SingleFileExecution"))
      XCTAssertFalse(run.executable.hasPrefix(directory.path + "/"))
    }
  }

  func testJavaPlanUsesDeclaredPackageAndMainType() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("Launcher.java")
      try """
      package sample.app;
      public final class Launcher {
        public static void main(String[] args) {}
      }
      """.write(to: source, atomically: true, encoding: .utf8)
      let plan = try XCTUnwrap(EditorBuildDiscovery.singleFilePlan(fileURL: source))
      let run = try XCTUnwrap(plan.command(for: .run))
      XCTAssertEqual(run.arguments.last, "sample.app.Launcher")
    }
  }

  func testShellPlanHonorsEnvShebang() throws {
    try withTemporaryDirectory { directory in
      let source = directory.appendingPathComponent("script.sh")
      try "#!/usr/bin/env zsh\necho hello\n".write(
        to: source, atomically: true, encoding: .utf8)
      let plan = try XCTUnwrap(EditorBuildDiscovery.singleFilePlan(fileURL: source))
      XCTAssertEqual(plan.command(for: .run)?.executable, "zsh")
    }
  }

  func testDocumentOnlyLanguagesDoNotPretendToBeExecutable() throws {
    try withTemporaryDirectory { directory in
      for name in ["index.html", "style.css", "README.md", "config.json"] {
        let source = directory.appendingPathComponent(name)
        try "test".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertNil(EditorBuildDiscovery.singleFilePlan(fileURL: source))
      }
    }
  }

  private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalciteSingleFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }
}
