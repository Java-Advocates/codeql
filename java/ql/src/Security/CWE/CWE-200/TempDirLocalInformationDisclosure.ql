/**
 * @name Temporary Directory Local information disclosure
 * @description Writing information without explicit permissions to a shared temporary directory may disclose it to other users.
 * @kind path-problem
 * @problem.severity warning
 * @precision very-high
 * @id java/local-temp-file-or-directory-information-disclosure
 * @tags security
 *       external/cwe/cwe-200
 *       external/cwe/cwe-732
 */

import java
import TempDirUtils
import DataFlow::PathGraph

private class MethodFileSystemFileCreation extends Method {
  MethodFileSystemFileCreation() {
    this.getDeclaringType() instanceof TypeFile and
    this.hasName(["mkdir", "mkdirs", "createNewFile"])
  }
}

abstract private class FileCreationSink extends DataFlow::Node { }

/**
 * The qualifier of a call to one of `File`'s file-creating or directory-creating methods,
 * treated as a sink by `TempDirSystemGetPropertyToCreateConfig`.
 */
private class FileFileCreationSink extends FileCreationSink {
  FileFileCreationSink() {
    exists(MethodAccess ma |
      ma.getMethod() instanceof MethodFileSystemFileCreation and
      ma.getQualifier() = this.asExpr()
    )
  }
}

/**
 * The argument to a call to one of `Files` file-creating or directory-creating methods,
 * treated as a sink by `TempDirSystemGetPropertyToCreateConfig`.
 */
private class FilesFileCreationSink extends FileCreationSink {
  FilesFileCreationSink() {
    exists(FilesVulnerableCreationMethodAccess ma | ma.getArgument(0) = this.asExpr())
  }
}

/**
 * A call to a `Files` method that create files/directories without explicitly
 * setting the newly-created file or directory's permissions.
 */
private class FilesVulnerableCreationMethodAccess extends MethodAccess {
  FilesVulnerableCreationMethodAccess() {
    exists(Method m |
      m = this.getMethod() and
      m.getDeclaringType().hasQualifiedName("java.nio.file", "Files")
    |
      m.hasName(["write", "newBufferedWriter", "newOutputStream"])
      or
      m.hasName(["createFile", "createDirectory", "createDirectories"]) and
      this.getNumArgument() = 1
      or
      m.hasName("newByteChannel") and
      this.getNumArgument() = 2
    )
  }
}

/**
 * A call to a `File` method that create files/directories with a specific set of permissions explicitly set.
 * We can safely assume that any calls to these methods with explicit `PosixFilePermissions.asFileAttribute`
 * contains a certain level of intentionality behind it.
 */
private class FilesSanitizingCreationMethodAccess extends MethodAccess {
  FilesSanitizingCreationMethodAccess() {
    exists(Method m |
      m = this.getMethod() and
      m.getDeclaringType().hasQualifiedName("java.nio.file", "Files")
    |
      m.hasName(["createFile", "createDirectory", "createDirectories"]) and
      this.getNumArgument() = 2
    )
  }
}

/**
 * The temp directory argument to a call to `java.io.File::createTempFile`,
 * treated as a sink by `TempDirSystemGetPropertyToCreateConfig`.
 */
private class FileCreateTempFileSink extends FileCreationSink {
  FileCreateTempFileSink() {
    exists(MethodAccess ma |
      ma.getMethod() instanceof MethodFileCreateTempFile and ma.getArgument(2) = this.asExpr()
    )
  }
}

private class TempDirSystemGetPropertyToCreateConfig extends TaintTracking::Configuration {
  TempDirSystemGetPropertyToCreateConfig() { this = "TempDirSystemGetPropertyToCreateConfig" }

  override predicate isSource(DataFlow::Node source) {
    source.asExpr() instanceof MethodAccessSystemGetPropertyTempDirTainted
  }

  /**
   * Find dataflow from the temp directory system property to the `File` constructor.
   * Examples:
   *  - `new File(System.getProperty("java.io.tmpdir"))`
   *  - `new File(new File(System.getProperty("java.io.tmpdir")), "/child")`
   */
  override predicate isAdditionalTaintStep(DataFlow::Node node1, DataFlow::Node node2) {
    isAdditionalFileTaintStep(node1, node2)
  }

  override predicate isSink(DataFlow::Node sink) { sink instanceof FileCreationSink }

  override predicate isSanitizer(DataFlow::Node sanitizer) {
    exists(FilesSanitizingCreationMethodAccess sanitisingMethodAccess |
      sanitizer.asExpr() = sanitisingMethodAccess.getArgument(0)
    )
  }
}

//
// Begin configuration for tracking single-method calls that are vulnerable.
//
/**
 * A `MethodAccess` against a method that creates a temporary file or directory in a shared temporary directory.
 */
abstract class MethodAccessInsecureFileCreation extends MethodAccess {
  /**
   * Gets the type of entity created (e.g. `file`, `directory`, ...).
   */
  abstract string getFileSystemEntityType();
}

/**
 * An insecure call to `java.io.File.createTempFile`.
 */
class MethodAccessInsecureFileCreateTempFile extends MethodAccessInsecureFileCreation {
  MethodAccessInsecureFileCreateTempFile() {
    this.getMethod() instanceof MethodFileCreateTempFile and
    (
      // `File.createTempFile(string, string)` always uses the default temporary directory
      this.getNumArgument() = 2
      or
      // The default temporary directory is used when the last argument of `File.createTempFile(string, string, File)` is `null`
      DataFlow::localExprFlow(any(NullLiteral n), getArgument(2))
    )
  }

  override string getFileSystemEntityType() { result = "file" }
}

/**
 * The `com.google.common.io.Files.createTempDir` method.
 */
class MethodGuavaFilesCreateTempFile extends Method {
  MethodGuavaFilesCreateTempFile() {
    getDeclaringType().hasQualifiedName("com.google.common.io", "Files") and
    hasName("createTempDir")
  }
}

/**
 * A call to the `com.google.common.io.Files.createTempDir` method.
 */
class MethodAccessInsecureGuavaFilesCreateTempFile extends MethodAccessInsecureFileCreation {
  MethodAccessInsecureGuavaFilesCreateTempFile() {
    getMethod() instanceof MethodGuavaFilesCreateTempFile
  }

  override string getFileSystemEntityType() { result = "directory" }
}

/**
 * This is a hack: we include use of inherently insecure methods, which don't have any associated
 * flow path, in with results describing a path from reading `java.io.tmpdir` or similar to use
 * in a file creation op.
 *
 * We achieve this by making inherently-insecure method invocations both a source and a sink in
 * this configuration, resulting in a zero-length path which is type-compatible with the actual
 * path-flow results.
 */
class InsecureMethodPseudoConfiguration extends DataFlow::Configuration {
  InsecureMethodPseudoConfiguration() { this = "InsecureMethodPseudoConfiguration" }

  override predicate isSource(DataFlow::Node node) {
    node.asExpr() instanceof MethodAccessInsecureFileCreation
  }

  override predicate isSink(DataFlow::Node node) {
    node.asExpr() instanceof MethodAccessInsecureFileCreation
  }
}

from DataFlow::PathNode source, DataFlow::PathNode sink, string message
where
  any(TempDirSystemGetPropertyToCreateConfig conf).hasFlowPath(source, sink) and
  message =
    "Local information disclosure vulnerability from $@ due to use of file or directory readable by other local users."
  or
  any(InsecureMethodPseudoConfiguration conf).hasFlowPath(source, sink) and
  // Note this message has no "$@" placeholder, so the "system temp directory" template parameter below is not used.
  message =
    "Local information disclosure vulnerability due to use of " +
      source.getNode().asExpr().(MethodAccessInsecureFileCreation).getFileSystemEntityType() +
      " readable by other local users."
select source.getNode(), source, sink, message, source.getNode(), "system temp directory"
