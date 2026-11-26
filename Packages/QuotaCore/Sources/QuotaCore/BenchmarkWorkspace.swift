import Foundation

/// Creates disposable checkouts without writing the source repository or
/// sharing its Git object files. Trials all use the same pinned commit.
public struct BenchmarkWorkspace {
  private static let git = URL(fileURLWithPath: "/usr/bin/git")
  private static let safeArguments = [
    "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
    "-c", "protocol.allow=never", "-c", "protocol.file.allow=always",
    "-c", "core.attributesFile=/dev/null", "-c", "submodule.recurse=false"
  ]
  private static let diffArguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary",
    "--src-prefix=a/", "--dst-prefix=b/", "--unified=3"]
  private static let reservedOutputNames = ["LLIMIT_BENCHMARK_RESULT.md", "LLIMIT_RESEARCH.md"]

  public static func commit(repository: URL, process: BenchmarkProcess) async throws -> String {
    let result = try await checkedGit(
      ["rev-parse", "--verify", "HEAD^{commit}"], directory: repository, process: process)
    let commit = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard validCommit(commit) else { throw BenchmarkWorkspaceError.invalidRepository }
    let submodules = try await checkedGit(
      ["ls-tree", "-r", commit], directory: repository, process: process)
    guard !submodules.split(separator: "\n").contains(where: { $0.hasPrefix("160000 ") }) else {
      throw BenchmarkWorkspaceError.submodulesUnsupported
    }
    return commit
  }

  public static func create(
    repository: URL, commit: String, destination: URL, process: BenchmarkProcess
  ) async throws {
    guard validCommit(commit), repository.isFileURL, destination.isFileURL,
          !FileManager.default.fileExists(atPath: destination.path) else {
      throw BenchmarkWorkspaceError.invalidRepository
    }
    let parent = destination.deletingLastPathComponent()
    // The caller owns this private reports directory. Resolve it once so a
    // symlink in a user-selected path cannot redirect a disposable checkout.
    guard parent.standardizedFileURL.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      _ = try await checkedGit(
        ["clone", "--no-local", "--no-hardlinks", "--no-checkout", "--no-recurse-submodules", "--", repository.path, destination.path],
        directory: parent, process: process)
      _ = try await checkedGit(
        ["checkout", "--detach", commit, "--"], directory: destination, process: process)
      // A normal clone points origin back at the source checkout. An agent
      // following repository push instructions must not write into that source.
      _ = try await checkedGit(
        ["remote", "remove", "origin"], directory: destination, process: process)
      try rejectEscapingSymlinks(in: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  public static func patch(directory: URL, baselineCommit: String? = nil, process: BenchmarkProcess) async throws -> String {
    if let baselineCommit, !validCommit(baselineCommit) { throw BenchmarkWorkspaceError.invalidRepository }
    try await rejectRelevantSymlinks(in: directory, process: process)
    // Intent-to-add includes untracked output in the review without running
    // clean filters or changing the agent's file bytes.
    _ = try await checkedGit(
      ["-c", "core.safecrlf=false", "add", "--intent-to-add", "--all", "--", "."],
      directory: directory, process: process, disablingFilters: true)
    // Capture only these reserved outputs when project rules ignore Markdown.
    // Other ignored files, including credentials and build output, stay excluded.
    for name in reservedOutputNames {
      let output = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: output.path) {
        let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BenchmarkWorkspaceError.invalidEvidence }
        _ = try await checkedGit(
          ["-c", "core.safecrlf=false", "add", "--intent-to-add", "--force", "--", name],
          directory: directory, process: process, disablingFilters: true)
      }
    }
    return try await checkedGit(
      diffArguments + [baselineCommit ?? "HEAD", "--", "."],
      directory: directory, process: process, disablingFilters: true)
  }

  /// Freeze every distinct candidate result while the trial still exists. An
  /// agent may leave its work on a branch or in a registered linked worktree.
  public static func captureEvidence(
    directory: URL, baselineCommit: String, process: BenchmarkProcess
  ) async throws -> (patch: String, additionalArtifacts: [BenchmarkEvidenceArtifact], warnings: [String]) {
    guard validCommit(baselineCommit) else { throw BenchmarkWorkspaceError.invalidRepository }
    let ownedGit = try ownedGitDirectory(in: directory)
    let primary = try await patch(directory: directory, baselineCommit: baselineCommit, process: process)
    var seen: Set<String> = [primary, ""]
    var artifacts: [BenchmarkEvidenceArtifact] = []
    var warnings: [String] = []

    do {
      let refs = try await checkedGit(["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads/"],
        directory: directory, process: process)
      for line in refs.split(separator: "\n") {
        let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 2 else {
          warnings.append("A local branch could not be inspected.")
          continue
        }
        let ref = String(fields[0])
        let revision = String(fields[1])
        do {
          guard ref.hasPrefix("refs/heads/"), validCommit(revision) else { throw BenchmarkWorkspaceError.invalidEvidence }
          _ = try await checkedGit(["check-ref-format", ref], directory: directory, process: process)
          let ancestry = try await gitResult(["merge-base", "--is-ancestor", baselineCommit, revision], directory: directory, process: process)
          guard ancestry.status == 0 else {
            warnings.append("Skipped local branch \(ref): its history does not descend from the benchmark baseline.")
            continue
          }
          let value = try await checkedGit(diffArguments + [baselineCommit, revision, "--", "."],
            directory: directory, process: process, disablingFilters: true)
          if seen.insert(value).inserted {
            artifacts.append(BenchmarkEvidenceArtifact(kind: .localBranch, name: String(ref.dropFirst("refs/heads/".count)), patch: value))
          }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Local branch \(ref) could not be inspected.") }
      }
    } catch is CancellationError { throw CancellationError() }
    catch { warnings.append("Local branch evidence could not be inspected.") }

    do {
      let listing = try await checkedGit(["worktree", "list", "--porcelain", "-z"], directory: directory, process: process)
      let paths = listing.split(separator: "\0").compactMap { item -> String? in
        guard item.hasPrefix("worktree ") else { return nil }
        return String(item.dropFirst("worktree ".count))
      }
      let root = directory.standardizedFileURL.resolvingSymlinksInPath()
      for path in paths {
        let worktree = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        if worktree.path == root.path { continue }
        do {
          try verifyLinkedWorktree(worktree, ownedGitDirectory: ownedGit)
          // Verify Git's interpretation too, after the on-disk metadata proves
          // that invoking Git here cannot select a foreign repository.
          let common = try await checkedGit(["rev-parse", "--git-common-dir"], directory: worktree, process: process)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard resolve(common, relativeTo: worktree).path == ownedGit.path else { throw BenchmarkWorkspaceError.invalidEvidence }
          let revision = try await checkedGit(["rev-parse", "--verify", "HEAD^{commit}"], directory: worktree, process: process)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard validCommit(revision) else { throw BenchmarkWorkspaceError.invalidEvidence }
          let ancestry = try await gitResult(["merge-base", "--is-ancestor", baselineCommit, revision], directory: worktree, process: process)
          guard ancestry.status == 0 else { throw BenchmarkWorkspaceError.invalidEvidence }
          let value = try await patch(directory: worktree, baselineCommit: baselineCommit, process: process)
          if seen.insert(value).inserted {
            artifacts.append(BenchmarkEvidenceArtifact(kind: .linkedWorktree, name: path, patch: value))
          }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Skipped linked worktree \(path): it is missing, unrelated, unsafe, or could not be inspected.") }
      }
    } catch is CancellationError { throw CancellationError() }
    catch { warnings.append("Linked worktree evidence could not be inspected.") }
    return (primary, artifacts, warnings)
  }

  /// Additional results have thin, independent file views, without merging
  /// branches or executing any candidate code. The complete patches remain.
  @discardableResult
  public static func prepareJudge(
    repository: URL, baselineCommit: String, destination: URL, patch: String,
    additionalArtifacts: [BenchmarkEvidenceArtifact], process: BenchmarkProcess
  ) async throws -> [String] {
    try await create(repository: repository, commit: baselineCommit, destination: destination, process: process)
    do {
      let evidenceDirectory = destination.appendingPathComponent(".llimit-evidence", isDirectory: true)
      guard !FileManager.default.fileExists(atPath: evidenceDirectory.path),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: evidenceDirectory.path)) == nil else {
        throw BenchmarkWorkspaceError.invalidEvidence
      }
      if !patch.isEmpty {
        _ = try await checkedGit(["apply", "--binary", "--whitespace=nowarn", "-"], directory: destination,
          process: process, input: patch, disablingFilters: true)
      }
      try rejectEscapingSymlinks(in: destination)
      guard !FileManager.default.fileExists(atPath: evidenceDirectory.path),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: evidenceDirectory.path)) == nil else {
        throw BenchmarkWorkspaceError.invalidEvidence
      }
      try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try writeOwnerOnlyAtomicallyLocked(Data(patch.utf8), to: evidenceDirectory.appendingPathComponent("primary.patch"))
      var warnings: [String] = []
      let primaryPaths = patch.isEmpty ? [] : try await materializeFileView(patch: patch,
        baselineCommit: baselineCommit, directory: destination,
        destination: evidenceDirectory.appendingPathComponent("primary"), output: .pathsOnly, process: process).changedPaths
      var contextPaths = Set(primaryPaths)
      var manifestArtifacts: [[String: Any]] = []
      for (index, artifact) in additionalArtifacts.enumerated() {
        let filename = "artifact-\(index + 1).patch"
        try writeOwnerOnlyAtomicallyLocked(Data(artifact.patch.utf8), to: evidenceDirectory.appendingPathComponent(filename))
        var row: [String: Any] = ["kind": artifact.kind.rawValue, "name": artifact.name, "patchFile": filename]
        let filesName = "artifact-\(index + 1)"
        do {
          let view = try await materializeFileView(patch: artifact.patch, baselineCommit: baselineCommit,
            directory: destination, destination: evidenceDirectory.appendingPathComponent(filesName), process: process)
          row["filesDirectory"] = filesName
          row["deletedPaths"] = view.deletedPaths
          row["changedPaths"] = view.changedPaths
          contextPaths.formUnion(view.changedPaths)
        } catch is CancellationError { throw CancellationError() }
        catch {
          let warning = "Artifact \(index + 1) could not be materialized as files because its patch is invalid, unsafe, or cannot be applied to the baseline. Its full patch remains available."
          row["warning"] = warning
          warnings.append(warning)
        }
        manifestArtifacts.append(row)
      }
      var manifest: [String: Any] = ["baselineCommit": baselineCommit, "primaryPatch": "primary.patch",
        "primaryChangedPaths": primaryPaths, "additionalArtifacts": manifestArtifacts]
      do {
        _ = try await materializeFileView(patch: nil, selectedPaths: contextPaths, baselineCommit: baselineCommit,
          directory: destination, destination: evidenceDirectory.appendingPathComponent("baseline"), process: process)
        manifest["baselineFilesDirectory"] = "baseline"
      } catch is CancellationError { throw CancellationError() }
      catch {
        let warning = "Some original baseline files could not be prepared safely for comparison. Use the patches to identify unavailable context."
        manifest["baselineFilesWarning"] = warning
        warnings.append(warning)
      }
      try writeOwnerOnlyAtomicallyLocked(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        to: evidenceDirectory.appendingPathComponent("manifest.json"))
      return warnings
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: destination)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw BenchmarkWorkspaceError.invalidEvidence
    }
  }

  private struct FileView {
    let changedPaths: [String]
    let deletedPaths: [String]
  }

  private enum FileViewOutput { case files, pathsOnly }

  /// An alternate index can construct blobs without touching the judge's
  /// primary index or worktree. Checkout only changed files, not another clone.
  private static func materializeFileView(
    patch: String?, selectedPaths: Set<String> = [], baselineCommit: String,
    directory: URL, destination: URL, output: FileViewOutput = .files, process: BenchmarkProcess
  ) async throws -> FileView {
    let indexFile = destination.deletingLastPathComponent().appendingPathComponent(".artifact-index-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: indexFile)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: indexFile.path + ".lock"))
    }
    let overrides = try await filterOverrides(directory: directory, process: process)
      + ["-c", "core.protectHFS=true", "-c", "core.protectNTFS=true"]
    func indexedGit(_ arguments: [String], input: String? = nil) async throws -> String {
      try await checkedGit(overrides + arguments, directory: directory, process: process,
        input: input, indexFile: indexFile)
    }
    _ = try await indexedGit(["read-tree", baselineCommit])
    let paths: [String]
    if let patch {
      _ = try await indexedGit(["apply", "--cached", "--binary", "--whitespace=nowarn", "-"], input: patch)
      paths = try await indexedGit(["diff-index", "--cached", "--no-renames", "--name-only", "-z", baselineCommit, "--"])
        .split(separator: "\0").map(String.init).sorted()
    } else {
      paths = selectedPaths.sorted()
    }
    for path in paths { try validateViewPath(path) }
    if output == .pathsOnly { return FileView(changedPaths: paths, deletedPaths: []) }
    let staged = try await indexedGit(["ls-files", "--stage", "-z"])
    var entries: [String: (mode: String, object: String)] = [:]
    for record in staged.split(separator: "\0") {
      guard let tab = record.firstIndex(of: "\t") else { throw BenchmarkWorkspaceError.invalidEvidence }
      let fields = record[..<tab].split(separator: " ")
      guard fields.count == 3, fields[2] == "0", validCommit(String(fields[1])) else {
        throw BenchmarkWorkspaceError.invalidEvidence
      }
      entries[String(record[record.index(after: tab)...])] = (String(fields[0]), String(fields[1]))
    }
    let existing = paths.filter { entries[$0] != nil }
    let deleted = paths.filter { entries[$0] == nil }
    let viewRoot = destination.standardizedFileURL.resolvingSymlinksInPath().path
    for path in existing {
      guard let entry = entries[path] else { throw BenchmarkWorkspaceError.invalidEvidence }
      guard ["100644", "100755", "120000"].contains(entry.mode) else {
        throw BenchmarkWorkspaceError.submodulesUnsupported
      }
      if entry.mode == "120000" {
        let size = try await indexedGit(["cat-file", "-s", entry.object]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int(size), size <= 8_192 else { throw BenchmarkWorkspaceError.unsafePath }
        let target = try await indexedGit(["cat-file", "-p", entry.object])
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0"), !target.contains("\\"),
              !target.contains("\u{fffd}"), !target.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else {
          throw BenchmarkWorkspaceError.unsafePath
        }
        let resolved = destination.appendingPathComponent(path).deletingLastPathComponent()
          .appendingPathComponent(target).standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(viewRoot + "/") else { throw BenchmarkWorkspaceError.unsafePath }
      }
    }
    guard !FileManager.default.fileExists(atPath: destination.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      if !existing.isEmpty {
        let attributes = try rawCheckoutAttributes(in: directory)
        do {
          _ = try await indexedGit(["checkout-index", "-z", "--stdin", "--prefix=\(destination.path)/"],
            input: existing.joined(separator: "\0") + "\0")
          try attributes.restore()
        } catch {
          try? attributes.restore()
          throw error
        }
      }
      try rejectEscapingSymlinks(in: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return FileView(changedPaths: paths, deletedPaths: deleted)
  }

  private static func validateViewPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\u{fffd}"),
          !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }) else {
      throw BenchmarkWorkspaceError.unsafePath
    }
  }

  private struct CheckoutAttributes {
    let url: URL
    let original: Data?
    let mode: Int?

    func restore() throws {
      if let original {
        try writeOwnerOnlyAtomically(original, to: url)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
      } else {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  /// Highest-precedence attributes keep checkout-index from expanding Ids,
  /// recoding text or changing line endings. This private clone is not yet in
  /// use by a judge, and its previous metadata is restored before returning.
  private static func rawCheckoutAttributes(in directory: URL) throws -> CheckoutAttributes {
    let info = try ownedGitDirectory(in: directory).appendingPathComponent("info", isDirectory: true)
    if FileManager.default.fileExists(atPath: info.path) {
      let values = try info.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw BenchmarkWorkspaceError.unsafePath }
    } else {
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: info.path)) == nil else { throw BenchmarkWorkspaceError.unsafePath }
      try FileManager.default.createDirectory(at: info, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let url = info.appendingPathComponent("attributes")
    let original: Data?
    let mode: Int?
    if FileManager.default.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BenchmarkWorkspaceError.unsafePath }
      original = try Data(contentsOf: url)
      mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    } else {
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw BenchmarkWorkspaceError.unsafePath }
      original = nil
      mode = nil
    }
    try writeOwnerOnlyAtomically(Data("* -text -crlf -ident -filter -working-tree-encoding\n".utf8), to: url)
    return CheckoutAttributes(url: url, original: original, mode: mode)
  }

  private static func validCommit(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func checkedGit(
    _ arguments: [String], directory: URL, process: BenchmarkProcess, input: String? = nil, disablingFilters: Bool = false,
    indexFile: URL? = nil
  ) async throws -> String {
    let overrides = disablingFilters ? try await filterOverrides(directory: directory, process: process) : []
    let result = try await gitResult(overrides + arguments, directory: directory, process: process, input: input, indexFile: indexFile)
    guard result.status == 0 else { throw BenchmarkWorkspaceError.gitFailed }
    return result.stdout
  }

  private static func gitResult(
    _ arguments: [String], directory: URL, process: BenchmarkProcess, input: String? = nil, indexFile: URL? = nil
  ) async throws -> BenchmarkProcessResult {
    var environment = BenchmarkProcess.defaultEnvironment()
    // User/global Git filters and helpers can run arbitrary commands or change
    // checkout contents. A benchmark snapshot uses only repository file bytes.
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_LFS_SKIP_SMUDGE"] = "1"
    if let indexFile { environment["GIT_INDEX_FILE"] = indexFile.path }
    let result = try await process.run(
      executable: git, arguments: safeArguments + arguments, directory: directory,
      input: input, timeout: 60, environment: environment)
    guard !result.timedOut else { throw BenchmarkWorkspaceError.gitFailed }
    return result
  }

  private static func filterOverrides(directory: URL, process: BenchmarkProcess) async throws -> [String] {
    let result = try await gitResult(["config", "--includes", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|smudge|process|required)$"],
      directory: directory, process: process)
    guard result.status == 0 || result.status == 1 else { throw BenchmarkWorkspaceError.gitFailed }
    var drivers: Set<String> = []
    for key in result.stdout.split(separator: "\0") {
      guard key.hasPrefix("filter."), let period = key.lastIndex(of: ".") else { throw BenchmarkWorkspaceError.invalidEvidence }
      let driver = String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<period])
      guard !driver.isEmpty, !driver.contains("="), !driver.contains("\0") else { throw BenchmarkWorkspaceError.invalidEvidence }
      drivers.insert(driver)
    }
    var arguments = ["-c", "core.worktree=\(directory.path)", "-c", "core.bare=false"]
    for driver in drivers.sorted() {
      for setting in ["clean", "smudge", "process"] { arguments += ["-c", "filter.\(driver).\(setting)="] }
      arguments += ["-c", "filter.\(driver).required=false"]
    }
    return arguments
  }

  private static func ownedGitDirectory(in directory: URL) throws -> URL {
    let git = directory.appendingPathComponent(".git", isDirectory: true)
    let values = try git.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw BenchmarkWorkspaceError.invalidEvidence }
    return git.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func rejectRelevantSymlinks(in directory: URL, process: BenchmarkProcess) async throws {
    // Build tools create ignored SDK/plugin links outside the checkout. They
    // are not evidence and must neither be traversed nor block actual changes.
    let listed = try await checkedGit(["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      directory: directory, process: process, disablingFilters: true)
    var paths = Set(listed.split(separator: "\0").map(String.init))
    paths.formUnion(reservedOutputNames)
    let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
    for path in paths {
      guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
        throw BenchmarkWorkspaceError.unsafePath
      }
      let resolved = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath().path
      guard resolved == root || resolved.hasPrefix(root + "/") else { throw BenchmarkWorkspaceError.unsafePath }
    }
  }

  private static func verifyLinkedWorktree(_ directory: URL, ownedGitDirectory: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw BenchmarkWorkspaceError.invalidEvidence
    }
    let marker = try smallRegularFile(directory.appendingPathComponent(".git"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard marker.hasPrefix("gitdir: ") else { throw BenchmarkWorkspaceError.invalidEvidence }
    let git = resolve(String(marker.dropFirst("gitdir: ".count)), relativeTo: directory)
    guard git.path.hasPrefix(ownedGitDirectory.appendingPathComponent("worktrees").path + "/") else {
      throw BenchmarkWorkspaceError.invalidEvidence
    }
    let common = try smallRegularFile(git.appendingPathComponent("commondir")).trimmingCharacters(in: .whitespacesAndNewlines)
    guard resolve(common, relativeTo: git).path == ownedGitDirectory.path else { throw BenchmarkWorkspaceError.invalidEvidence }
    let backPointer = try smallRegularFile(git.appendingPathComponent("gitdir")).trimmingCharacters(in: .whitespacesAndNewlines)
    guard resolve(backPointer, relativeTo: git).path == directory.appendingPathComponent(".git").standardizedFileURL.resolvingSymlinksInPath().path else {
      throw BenchmarkWorkspaceError.invalidEvidence
    }
  }

  private static func smallRegularFile(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size <= 8_192 else { throw BenchmarkWorkspaceError.invalidEvidence }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private static func resolve(_ path: String, relativeTo directory: URL) -> URL {
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func rejectEscapingSymlinks(in directory: URL) throws {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
      throw BenchmarkWorkspaceError.unsafePath
    }
    for case let item as URL in enumerator {
      if item.lastPathComponent == ".git" { enumerator.skipDescendants(); continue }
      if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root) else { throw BenchmarkWorkspaceError.unsafePath }
      }
    }
  }
}

public enum BenchmarkWorkspaceError: LocalizedError {
  case invalidRepository
  case submodulesUnsupported
  case unsafePath
  case gitFailed
  case invalidEvidence

  public var errorDescription: String? {
    switch self {
    case .invalidRepository: return "Choose a Git repository with a committed revision and a new trial directory."
    case .submodulesUnsupported: return "Benchmark snapshots do not support Git submodules yet."
    case .unsafePath: return "The trial directory contains a path or symbolic link outside its checkout."
    case .gitFailed: return "Could not prepare or inspect the benchmark checkout. Check Git and the selected repository."
    case .invalidEvidence: return "The benchmark evidence is unsafe, unavailable, or cannot be applied to its baseline."
    }
  }
}
