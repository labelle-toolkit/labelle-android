//! Vendored verbatim from labelle-cli `src/cli/provider_contract.zig` at
//! d7827ebec1b936ad953ae1893a797ad115e791af (labelle-cli#443, contract 1.4.0). Re-vendor verbatim
//! (keep this header) when the CLI ships a new contract minor; do not edit below.
//!
//! Provider contract v1. Pure validation; does not resolve or execute packages.
const std = @import("std");

/// The contract version this CLI implements: the newest wire it speaks.
pub const version = "1.4.0";

/// Every wire version this CLI can speak, newest first. A minor is additive:
/// `1.1.0` is `1.0.0` plus the optional `build_number` key, `1.2.0` is
/// `1.1.0` plus `target_dir` and the `run` options, `1.3.0` is `1.2.0`
/// plus `cache_dir` and `env_file`, and `1.4.0` is `1.3.0` plus
/// `final_step` (§2). The version a provider receives is
/// negotiated from its `command_contract` range
/// (`provider_manifest.negotiate`), so a provider pinned to `<1.1.0` keeps
/// receiving the exact `1.0.0` wire and never sees a key it would reject as
/// unknown.
pub const supported_versions = [_][]const u8{ version, "1.3.0", "1.2.0", "1.1.0", "1.0.0" };

/// The first wire version that carries `build_number`.
pub const build_number_since = "1.1.0";

/// The first wire version that carries `target_dir` and `run`.
pub const run_context_since = "1.2.0";

/// The first wire version that carries `cache_dir` and `env_file`.
pub const toolchain_context_since = "1.3.0";

/// The first wire version whose `run` context carries `watch`.
pub const watch_context_since = "1.3.0";

/// The first wire version that carries `final_step`.
pub const final_step_since = "1.4.0";

fn atLeast(wire_version: []const u8, since: []const u8) bool {
    const wire = std.SemanticVersion.parse(wire_version) catch return false;
    const floor = std.SemanticVersion.parse(since) catch unreachable;
    return wire.order(floor) != .lt;
}

/// True when the wire `contract_version` carries the `build_number` key.
pub fn carriesBuildNumber(wire_version: []const u8) bool {
    return atLeast(wire_version, build_number_since);
}

/// True when the wire `contract_version` carries the `target_dir` key (on
/// every context) and the `run` key (on `run`-step hook contexts).
pub fn carriesRunContext(wire_version: []const u8) bool {
    return atLeast(wire_version, run_context_since);
}

/// True when the wire `contract_version` carries the `cache_dir` and
/// `env_file` keys (on every context).
pub fn carriesToolchainContext(wire_version: []const u8) bool {
    return atLeast(wire_version, toolchain_context_since);
}

/// True when the wire `contract_version`'s `run` context carries the
/// `watch` key (null outside a watch session).
pub fn carriesWatchContext(wire_version: []const u8) bool {
    return atLeast(wire_version, watch_context_since);
}

/// True when the wire `contract_version` carries the `final_step` key (on
/// every context).
pub fn carriesFinalStep(wire_version: []const u8) bool {
    return atLeast(wire_version, final_step_since);
}

/// Whether a command whose last lifecycle step is `final` runs the hooks of
/// `step` (contract §6): every command runs `generate`; `build`, `run` and
/// `bundle` run `build` first; and `run` and `bundle` are alternatives, so
/// a `bundle` hook never sees `final_step = run`, nor the reverse.
pub fn stepReaches(final: Step, step: Step) bool {
    return switch (step) {
        .generate => true,
        .build => final != .generate,
        .run, .bundle => final == step,
    };
}

/// The hook slots whose context names an `env_file` (wire `1.3.0`+): the
/// `before generate`, `after generate` and `before build` hooks, which run
/// ahead of the zig invocations a contributed environment is for (the
/// generation-time fingerprint pass and the compile). Every other hook and
/// every command gets `env_file: null`.
pub fn envFileSlot(invocation: Invocation) bool {
    if (invocation.kind != .hook) return false;
    const step = invocation.step orelse return false;
    const phase = invocation.phase orelse return false;
    return switch (step) {
        .generate => phase == .before or phase == .after,
        .build => phase == .before,
        .bundle, .run => false,
    };
}

/// Environment names a provider's `env_file` may not set are the CLI-owned
/// ones in `config.reserved_env` (`config.zig`, beside the CLI's own
/// environment access). The table names legacy toolchain variables, so it
/// lives in a file the agnosticism guard already tracks rather than in this
/// platform-neutral contract.
fn supported(wire_version: []const u8) bool {
    for (supported_versions) |candidate| {
        if (std.mem.eql(u8, wire_version, candidate)) return true;
    }
    return false;
}
pub const context_env = "LABELLE_CONTEXT";
pub const Step = enum { generate, build, bundle, run };
pub const Phase = enum { before, replace, after };
pub const Optimize = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };
pub const Progress = enum { human, json, off };

pub const Invocation = struct {
    kind: enum { command, hook },
    id: []const u8,
    step: ?Step,
    phase: ?Phase,
};

/// One `LABELLE_*` variable of a `run` context: a platform-neutral run
/// option the game reads from its environment. The provider decides how it
/// reaches the game on its target.
pub const RunEnv = struct {
    name: []const u8,
    value: []const u8,
};

/// A watch session (`labelle run --watch`, wire `1.3.0`+), handed to the
/// run replacement only. Both paths are absolute. `output_dir` names the
/// last successfully built output, switched atomically to each new
/// publication; `generation_file` holds that publication's number (ASCII
/// decimal and a newline, 0 first), advanced only AFTER `output_dir` was
/// switched. A consumer polls the generation and re-resolves `output_dir`
/// once it changes.
pub const WatchContext = struct {
    generation_file: []const u8,
    output_dir: []const u8,

    pub fn validate(self: WatchContext) !void {
        try absolute(self.generation_file);
        try absolute(self.output_dir);
    }
};

/// The `labelle run` options a `run`-step hook receives (wire `1.2.0`+).
/// Every key is required; `timeout_ms` is null when `--timeout` was not
/// given. `watch` (wire `1.3.0`+) is required there too: null outside a
/// watch session and on every hook but the replacement; absent below
/// `1.3.0`.
pub const RunContext = struct {
    /// The run options as `LABELLE_*` variables, in the order the core
    /// launch sets them. Empty when none was given.
    env: []const RunEnv,
    /// The tokens after `--`, verbatim.
    args: []const []const u8,
    /// `--timeout`, in milliseconds.
    timeout_ms: ?u64,
    /// The watch session, on the run replacement of `labelle run --watch`.
    watch: ?WatchContext = null,

    /// Whether the user passed any run option at all.
    pub fn given(self: RunContext) bool {
        return self.env.len != 0 or self.args.len != 0 or self.timeout_ms != null;
    }

    pub fn validate(self: RunContext) !void {
        for (self.env, 0..) |entry, i| {
            if (!envName(entry.name)) return error.InvalidRunEnv;
            if (std.mem.indexOfScalar(u8, entry.value, 0) != null) return error.InvalidRunEnv;
            for (self.env[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, entry.name)) return error.InvalidRunEnv;
            }
        }
        for (self.args) |arg| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidRunArgument;
        }
        if (self.watch) |w| try w.validate();
    }

    /// The object on `wire`: `watch` written (null or not) from `1.3.0`,
    /// never below.
    fn write(self: RunContext, jws: anytype, wire: []const u8) !void {
        try jws.beginObject();
        try jws.objectField("env");
        try jws.write(self.env);
        try jws.objectField("args");
        try jws.write(self.args);
        try jws.objectField("timeout_ms");
        try jws.write(self.timeout_ms);
        if (carriesWatchContext(wire)) {
            try jws.objectField("watch");
            try jws.write(self.watch);
        }
        try jws.endObject();
    }
};

/// A portable environment-variable name: `[A-Za-z_][A-Za-z0-9_]*`.
pub fn envName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// All fields are required on the wire, including explicitly null fields —
/// except the keys a wire version does not define and the optional ones:
///
/// - `build_number` (wire `1.1.0`+) is present only in a `bundle` hook's
///   context when the user passed `--build-number`, and absent (never null)
///   everywhere else, so a context without it is byte-identical to the
///   `1.0.0` wire.
/// - `target_dir` (wire `1.2.0`+) is required on every `1.2.0` context:
///   the absolute generated target directory on a hook, null on a command.
///   Never present below `1.2.0`.
/// - `run` (wire `1.2.0`+) is present on every `run`-step hook context and
///   absent (never null) everywhere else.
/// - `cache_dir` (wire `1.3.0`+) is required, and never null, on every
///   `1.3.0` context: the provider's persistent cache directory.
/// - `env_file` (wire `1.3.0`+) is required on every `1.3.0` context: an
///   absolute path on a hook in an `envFileSlot`, null everywhere else.
/// - `final_step` (wire `1.4.0`+) is required on every `1.4.0` context: on
///   a hook, the last lifecycle step the invoking CLI command runs (one the
///   hook's own step leads to, `stepReaches`); null on a command.
///
/// Paths are absolute for the host running the provider.
pub const Context = struct {
    contract_version: []const u8,
    invocation: Invocation,
    package_dir: []const u8,
    project_dir: ?[]const u8,
    target: ?[]const u8,
    lock_file: ?[]const u8,
    config_file: ?[]const u8,
    output_dir: []const u8,
    zig_executable: []const u8,
    optimize: Optimize,
    progress: Progress,
    /// The build number `labelle bundle --build-number=N` was given, for the
    /// provider that packages the target (its `bundle` hooks); the core
    /// packager stamps it itself. Optional on the wire (see above).
    build_number: ?[]const u8 = null,
    /// The generated target directory (`.labelle/<backend>_<target>/`) a
    /// hook's step works in, whatever `output_dir` is (a `bundle --output`
    /// elsewhere included). Wire `1.2.0`+ (see above).
    target_dir: ?[]const u8 = null,
    /// The `labelle run` options, for a `run`-step hook that stands in for
    /// or wraps the launch. Wire `1.2.0`+ (see above).
    run: ?RunContext = null,
    /// The provider's persistent cache directory,
    /// `<LABELLE_HOME>/providers/<canonical provider id>/`: created by the
    /// CLI, shared by every project that pins the same provider, and laid
    /// out by the provider. Wire `1.3.0`+ (see above).
    cache_dir: ?[]const u8 = null,
    /// Where a `before generate`, `after generate` or `before build` hook
    /// may write its environment contribution (contract §2, "Environment
    /// contributions"). The file does not exist when the hook starts. Wire
    /// `1.3.0`+ (see above).
    env_file: ?[]const u8 = null,
    /// The last lifecycle step of the CLI command that runs this hook:
    /// `generate` (`labelle generate`, and a legacy subcommand that only
    /// runs the generate hooks), `build`, `run` (`labelle run`, watched
    /// rebuilds included) or `bundle`. A hook uses it to tell a build it
    /// finalises from one a later step packages anyway: an `after build`
    /// hook that makes the installable package of `labelle build` and
    /// `labelle run` can skip that work when `final_step` is `bundle`,
    /// whose replacement produces the distributable (cli#443). Wire
    /// `1.4.0`+ (see above).
    final_step: ?Step = null,

    pub fn validate(self: Context, needs_project: bool) !void {
        if (!supported(self.contract_version)) return error.UnsupportedContract;
        if (!identifier(self.invocation.id)) return error.InvalidIdentifier;
        try absolute(self.package_dir);
        try absolute(self.output_dir);
        try absolute(self.zig_executable);
        if (self.project_dir) |project| {
            try absolute(project);
            try absolute(self.lock_file orelse return error.MissingProjectLock);
            if (!identifier(self.target orelse return error.MissingTarget)) return error.InvalidIdentifier;
            if (self.config_file) |path| try absolute(path);
        } else {
            if (needs_project) return error.ProjectRequired;
            if (self.target != null or self.lock_file != null or self.config_file != null)
                return error.InvalidProjectlessContext;
            if (self.optimize != .Debug) return error.InvalidProjectlessContext;
        }
        switch (self.invocation.kind) {
            .command => if (self.invocation.step != null or self.invocation.phase != null)
                return error.InvalidInvocation,
            .hook => {
                if (self.project_dir == null or self.invocation.step == null or self.invocation.phase == null)
                    return error.InvalidInvocation;
            },
        }
        if (self.build_number) |number| {
            // A `1.0.0` wire has no such key: its strict decoders reject it.
            if (!carriesBuildNumber(self.contract_version)) return error.UnsupportedContract;
            if (self.invocation.kind != .hook or self.invocation.step != .bundle) return error.InvalidInvocation;
            if (number.len == 0) return error.InvalidBuildNumber;
        }
        if (!carriesToolchainContext(self.contract_version)) {
            // Keys a `1.2.0` or older strict decoder would reject as unknown.
            if (self.cache_dir != null or self.env_file != null or self.final_step != null) return error.UnsupportedContract;
        }
        if (!carriesRunContext(self.contract_version)) {
            // Keys a `1.1.0`/`1.0.0` strict decoder would reject as unknown.
            if (self.target_dir != null or self.run != null) return error.UnsupportedContract;
            return;
        }
        const hook = self.invocation.kind == .hook;
        if (hook) {
            try absolute(self.target_dir orelse return error.MissingTargetDir);
        } else if (self.target_dir != null) return error.InvalidInvocation;
        const run_hook = hook and self.invocation.step == .run;
        if (self.run) |run| {
            if (!run_hook) return error.InvalidInvocation;
            try run.validate();
            if (run.watch != null) {
                // A `1.2.0` strict decoder rejects the key.
                if (!carriesWatchContext(self.contract_version)) return error.UnsupportedContract;
                // Only the replacement is the session's long-lived launch.
                if (self.invocation.phase != .replace) return error.WatchNotAllowed;
            }
        } else if (run_hook) return error.MissingRunContext;
        if (!carriesToolchainContext(self.contract_version)) return;
        try absolute(self.cache_dir orelse return error.MissingCacheDir);
        if (envFileSlot(self.invocation)) {
            try absolute(self.env_file orelse return error.MissingEnvFile);
        } else if (self.env_file != null) return error.EnvFileNotAllowed;
        if (!carriesFinalStep(self.contract_version)) {
            // A `1.3.0` strict decoder rejects the key as unknown.
            if (self.final_step != null) return error.UnsupportedContract;
            return;
        }
        if (hook) {
            const final = self.final_step orelse return error.MissingFinalStep;
            if (!stepReaches(final, self.invocation.step.?)) return error.InvalidFinalStep;
        } else if (self.final_step != null) return error.InvalidInvocation;
    }

    /// Every field in declaration order, nulls included, except the keys the
    /// context's wire does not carry (`target_dir` below `1.2.0`, `cache_dir`
    /// and `env_file` below `1.3.0`, `final_step` below `1.4.0`) and the
    /// optional ones when absent (`build_number`, `run`), which are omitted
    /// rather than written as null.
    pub fn jsonStringify(self: Context, jws: anytype) !void {
        try jws.beginObject();
        inline for (std.meta.fields(Context)) |field| {
            const value = @field(self, field.name);
            const optional = comptime std.mem.eql(u8, field.name, "build_number") or std.mem.eql(u8, field.name, "run");
            const run_gated = comptime std.mem.eql(u8, field.name, "target_dir");
            const toolchain_gated = comptime std.mem.eql(u8, field.name, "cache_dir") or std.mem.eql(u8, field.name, "env_file");
            const final_step_gated = comptime std.mem.eql(u8, field.name, "final_step");
            const write = if (optional)
                value != null
            else if (run_gated)
                carriesRunContext(self.contract_version)
            else if (toolchain_gated)
                carriesToolchainContext(self.contract_version)
            else if (final_step_gated)
                carriesFinalStep(self.contract_version)
            else
                true;
            if (write) {
                try jws.objectField(field.name);
                if (comptime std.mem.eql(u8, field.name, "run")) {
                    try value.?.write(jws, self.contract_version);
                } else try jws.write(value);
            }
        }
        try jws.endObject();
    }
};

/// Caller owns the returned JSON arena. Validation failures also free it.
pub fn parseContext(allocator: std.mem.Allocator, bytes: []const u8, needs_project: bool) !std.json.Parsed(Context) {
    const parsed = try std.json.parseFromSlice(Context, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(needs_project);
    try keyPresence(allocator, bytes, parsed.value.contract_version);
    return parsed;
}

/// What the typed decode cannot see, because a missing optional field and
/// an explicit null both decode to null: on a `1.2.0` wire `target_dir` is
/// a required key (null on a command, never absent), below it the key does
/// not exist (even as null); `cache_dir` and `env_file` follow the same rule
/// from `1.3.0`, and `final_step` from `1.4.0`; and an optional key is
/// absent rather than null.
fn keyPresence(allocator: std.mem.Allocator, bytes: []const u8, wire: []const u8) !void {
    const raw = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer raw.deinit();
    const object = switch (raw.value) {
        .object => |object| object,
        else => return error.UnexpectedToken,
    };
    const has_target_dir = object.contains("target_dir");
    if (carriesRunContext(wire)) {
        if (!has_target_dir) return error.MissingField;
    } else {
        if (has_target_dir or object.contains("run")) return error.UnknownField;
    }
    for ([_][]const u8{ "cache_dir", "env_file" }) |key| {
        if (carriesToolchainContext(wire)) {
            if (!object.contains(key)) return error.MissingField;
        } else if (object.contains(key)) return error.UnknownField;
    }
    if (carriesFinalStep(wire)) {
        if (!object.contains("final_step")) return error.MissingField;
    } else if (object.contains("final_step")) return error.UnknownField;
    for ([_][]const u8{ "build_number", "run" }) |key| {
        if (object.get(key)) |value| if (value == .null) return error.NullOptionalKey;
    }
    // `run.watch`: required (possibly null) from `1.3.0`, absent below.
    if (object.get("run")) |run| if (run == .object) {
        if (carriesWatchContext(wire)) {
            if (!run.object.contains("watch")) return error.MissingField;
        } else if (run.object.contains("watch")) return error.UnknownField;
    };
}

/// A named install-only build step produces this exact host executable.
/// `executable` is relative to an isolated Zig install prefix, using '/'.
pub const Tool = struct {
    build_step: []const u8,
    executable: []const u8,

    pub fn validate(self: Tool) !void {
        if (!identifier(self.build_step)) return error.InvalidBuildStep;
        const path = self.executable;
        if (!std.mem.startsWith(u8, path, "bin/") or path.len <= 4) return error.InvalidExecutable;
        if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return error.InvalidExecutable;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
                return error.InvalidExecutable;
        }
        // Native extension is selected by the host, not authored in the manifest.
        // Windows ignores suffix case, so `.EXE` is the same authored extension.
        if (std.ascii.endsWithIgnoreCase(path, ".exe")) return error.InvalidExecutable;
    }
};

pub const Ownership = struct {
    package: []const u8,
    namespaces: []const []const u8,
    targets: []const []const u8,
};

/// Same ownership data answers namespace and missing-target diagnostics.
pub fn validateOwnership(entries: []const Ownership, reserved_namespaces: []const []const u8) !void {
    for (entries, 0..) |entry, i| {
        if (!identifier(entry.package)) return error.InvalidIdentifier;
        for (entries[0..i]) |previous| {
            if (std.mem.eql(u8, entry.package, previous.package)) return error.DuplicatePackage;
        }
        try uniqueNames(entry.namespaces);
        try uniqueNames(entry.targets);
        for (entry.namespaces) |name| {
            for (reserved_namespaces) |reserved| {
                if (std.mem.eql(u8, name, reserved)) return error.ReservedNamespace;
            }
            for (entries[0..i]) |previous| {
                for (previous.namespaces) |claimed| {
                    if (std.mem.eql(u8, name, claimed)) return error.NamespaceConflict;
                }
            }
        }
        for (entry.targets) |target| {
            if (std.mem.eql(u8, target, "desktop")) return error.ReservedTarget;
            for (entries[0..i]) |previous| {
                for (previous.targets) |claimed| {
                    if (std.mem.eql(u8, target, claimed)) return error.TargetConflict;
                }
            }
        }
    }
}

pub fn providerForTarget(entries: []const Ownership, target: []const u8) ?[]const u8 {
    for (entries) |entry| {
        for (entry.targets) |declared| {
            if (std.mem.eql(u8, target, declared)) return entry.package;
        }
    }
    return null;
}

fn uniqueNames(names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (!identifier(name)) return error.InvalidIdentifier;
        for (names[0..i]) |previous| {
            if (std.mem.eql(u8, name, previous)) return error.DuplicateName;
        }
    }
}

pub fn identifier(value: []const u8) bool {
    if (value.len == 0 or value[0] < 'a' or value[0] > 'z') return false;
    for (value) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// Windows cannot create these names in any directory, case-insensitively
/// and regardless of extension (`nul.zig` is still the NUL device), so a
/// path component that is one extracts on Unix but fails on Windows.
pub fn windowsReservedDeviceName(part: []const u8) bool {
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    return stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) and stem[3] >= '1' and stem[3] <= '9';
}

/// A target name: an identifier that can also name a directory on every
/// host. The resolved target becomes a path component (`.labelle/<backend>_<t>/`,
/// `zig-out/bundle/<t>/`), so a Windows reserved device name — `con`, `nul`,
/// `com1`, … — is not a target, however well-formed as an identifier.
pub fn targetName(value: []const u8) bool {
    return identifier(value) and !windowsReservedDeviceName(value);
}

fn absolute(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null or !std.fs.path.isAbsolute(path))
        return error.InvalidPath;
    // A rooted /path still depends on the current drive on Windows.
    if (@import("builtin").os.tag == .windows and !windowsVolumeQualified(path)) return error.InvalidPath;
}

/// Windows paths must name their volume: `X:\...` or a UNC `\\server\share...`.
/// Host-independent so the rule is exercised by the tests on every platform.
pub fn windowsVolumeQualified(path: []const u8) bool {
    const seps = "/\\";
    const drive = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        std.mem.indexOfScalar(u8, seps, path[2]) != null;
    if (drive) return true;
    if (path.len < 2 or std.mem.indexOfScalar(u8, seps, path[0]) == null or std.mem.indexOfScalar(u8, seps, path[1]) == null)
        return false;
    // std classifies bare `//` and `//server` as absolute; a share needs both a
    // non-empty server and a non-empty share name to address anything.
    const server_end = std.mem.indexOfAnyPos(u8, path, 2, seps) orelse return false;
    if (server_end == 2) return false;
    var rest = std.mem.tokenizeAny(u8, path[server_end + 1 ..], seps);
    return rest.next() != null;
}

test {
    _ = @import("provider_contract_watch_test.zig");
    _ = @import("provider_contract_wire_test.zig");
    _ = @import("provider_contract_final_step_test.zig");
}

pub const fixture = if (@import("builtin").os.tag == .windows)
    @embedFile("provider_contract/projectless-windows.json")
else
    @embedFile("provider_contract/projectless.json");

test "wire context parses required explicit nulls and owns its strings" {
    const input = try std.testing.allocator.dupe(u8, fixture);
    defer std.testing.allocator.free(input);
    const parsed = try parseContext(std.testing.allocator, input, false);
    defer parsed.deinit();
    @memset(input, ' ');
    try std.testing.expectEqualStrings("doctor", parsed.value.invocation.id);
    try std.testing.expect(parsed.value.project_dir == null);
}

test "project-only command rejects a projectless context" {
    try std.testing.expectError(error.ProjectRequired, parseContext(std.testing.allocator, fixture, true));
}

test "wire parser rejects unknown fields, missing fields and duplicate fields" {
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"progress\": \"json\"", "\"progress\": \"json\", \"typo\": true");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.UnknownField, parseContext(std.testing.allocator, unknown, false));
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"target\": null,", "");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.MissingField, parseContext(std.testing.allocator, missing, false));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"target\": null,", "\"target\": null, \"target\": null,");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.DuplicateField, parseContext(std.testing.allocator, duplicate, false));
}

test "context rejects unsupported version and inconsistent project fields" {
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    var value = parsed.value;
    value.contract_version = "2.0.0";
    try std.testing.expectError(error.UnsupportedContract, value.validate(false));
    value = parsed.value;
    value.target = "sample-target";
    try std.testing.expectError(error.InvalidProjectlessContext, value.validate(false));
    value = parsed.value;
    value.project_dir = value.package_dir;
    try std.testing.expectError(error.MissingProjectLock, value.validate(true));
    value.lock_file = value.zig_executable;
    try std.testing.expectError(error.MissingTarget, value.validate(true));
    value.target = "desktop";
    try value.validate(true);
    value.invocation.kind = .hook;
    try std.testing.expectError(error.InvalidInvocation, value.validate(true));
    value.invocation.step = .bundle;
    value.invocation.phase = .after;
    try value.validate(true);
}

test "context rejects relative paths and command hook metadata" {
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    var value = parsed.value;
    value.output_dir = "relative/output";
    try std.testing.expectError(error.InvalidPath, value.validate(false));
    value = parsed.value;
    value.invocation.step = .run;
    try std.testing.expectError(error.InvalidInvocation, value.validate(false));
    value = parsed.value;
    value.optimize = .ReleaseFast;
    try std.testing.expectError(error.InvalidProjectlessContext, value.validate(false));
    if (@import("builtin").os.tag == .windows) {
        for ([_][]const u8{ "/current-drive-relative", "//", "//server", "//server/" }) |path| {
            value = parsed.value;
            value.output_dir = path;
            try std.testing.expectError(error.InvalidPath, value.validate(false));
        }
        value = parsed.value;
        value.output_dir = "//server/share";
        try value.validate(false);
    }
}

test "windows volume qualification requires a drive or a complete UNC share" {
    for ([_][]const u8{ "C:/provider", "c:\\provider", "//server/share", "\\\\server\\share\\dir", "//server//share" }) |path| {
        try std.testing.expect(windowsVolumeQualified(path));
    }
    for ([_][]const u8{ "", "/rooted", "C:relative", "//", "//server", "//server/", "///share", "\\\\.", "\\\\?\\" }) |path| {
        try std.testing.expect(!windowsVolumeQualified(path));
    }
    // The qualification check is what rejects incomplete UNC prefixes; std alone accepts them.
    for ([_][]const u8{ "//", "//server", "//server/" }) |path| {
        try std.testing.expect(std.fs.path.isAbsoluteWindows(path));
    }
}

test "tool must declare a contained deterministic installed executable" {
    try (Tool{ .build_step = "cmd-doctor", .executable = "bin/doctor" }).validate();
    for ([_][]const u8{ "", "/bin/tool", "bin/../escape", "bin//tool", "bin/./tool", "bin/tool.exe", "bin/C:tool", "bin/tool\\other", "bin/tool\x00" }) |path| {
        try std.testing.expectError(error.InvalidExecutable, (Tool{ .build_step = "cmd-test", .executable = path }).validate());
    }
    // Case variants of the native suffix would make the runner look for `tool.EXE.exe`.
    for ([_][]const u8{ "bin/tool.EXE", "bin/tool.Exe", "bin/nested/tool.eXe" }) |path| {
        try std.testing.expect(!std.mem.endsWith(u8, path, ".exe"));
        try std.testing.expectError(error.InvalidExecutable, (Tool{ .build_step = "cmd-test", .executable = path }).validate());
    }
    // An extension that merely contains the suffix letters is still a plain tool name.
    try (Tool{ .build_step = "cmd-test", .executable = "bin/tool.exec" }).validate();
    try std.testing.expectError(error.InvalidBuildStep, (Tool{ .build_step = "--help", .executable = "bin/tool" }).validate());
}

test "target ownership resolves independently of namespace spelling" {
    const entries = [_]Ownership{.{ .package = "browser-provider", .namespaces = &.{"browser"}, .targets = &.{"bytecode"} }};
    try validateOwnership(&entries, &.{"build"});
    try std.testing.expectEqualStrings("browser-provider", providerForTarget(&entries, "bytecode").?);
    try std.testing.expect(providerForTarget(&entries, "missing") == null);
}

test "ownership rejects conflicts and reserved identities before dispatch" {
    const first: Ownership = .{ .package = "provider-a", .namespaces = &.{"sample"}, .targets = &.{"sample-target"} };
    var second: Ownership = .{ .package = "provider-b", .namespaces = &.{"sample"}, .targets = &.{} };
    try std.testing.expectError(error.NamespaceConflict, validateOwnership(&.{ first, second }, &.{}));
    second.namespaces = &.{};
    second.targets = &.{"sample-target"};
    try std.testing.expectError(error.TargetConflict, validateOwnership(&.{ first, second }, &.{}));
    try std.testing.expectError(error.ReservedNamespace, validateOwnership(&.{first}, &.{"sample"}));
    second.targets = &.{"desktop"};
    try std.testing.expectError(error.ReservedTarget, validateOwnership(&.{second}, &.{}));
    second.targets = &.{ "a", "a" };
    try std.testing.expectError(error.DuplicateName, validateOwnership(&.{second}, &.{}));
}

test "a target name is an identifier that is not a Windows reserved device name" {
    for ([_][]const u8{ "desktop", "probe-target", "console", "nul0", "com10", "lpt", "auxiliary", "cons" }) |name| {
        try std.testing.expect(identifier(name));
        try std.testing.expect(targetName(name));
    }
    for ([_][]const u8{ "con", "prn", "aux", "nul", "com1", "com9", "lpt1", "lpt9" }) |name| {
        try std.testing.expect(identifier(name));
        try std.testing.expect(windowsReservedDeviceName(name));
        try std.testing.expect(!targetName(name));
    }
    // The device rule folds case and ignores an extension, like Windows does;
    // the identifier rule already excludes those spellings on its own.
    for ([_][]const u8{ "NUL", "Con.tar.gz", "aux.h", "COM1", "conin$", "conout$.zig" }) |name| {
        try std.testing.expect(windowsReservedDeviceName(name));
        try std.testing.expect(!targetName(name));
    }
    try std.testing.expect(!targetName("Probe"));
    try std.testing.expect(!targetName(""));
}

test "build_number is optional on the wire and only for bundle hooks" {
    // Absent: parses (the pre-field wire) and is not written back.
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.build_number == null);
    const plain = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "build_number") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"target\":null") != null);
    // Present on a command: refused.
    var value = parsed.value;
    value.contract_version = "1.2.0";
    value.build_number = "42";
    try std.testing.expectError(error.InvalidInvocation, value.validate(false));
    // Present on a bundle hook: accepted, written and read back.
    value.project_dir = value.package_dir;
    value.lock_file = value.zig_executable;
    value.target = "sample-target";
    value.invocation = .{ .kind = .hook, .id = "pack", .step = .bundle, .phase = .replace };
    value.target_dir = value.package_dir; // a 1.2.0 hook names its target dir
    try value.validate(true);
    const wire = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(wire);
    const back = try parseContext(std.testing.allocator, wire, true);
    defer back.deinit();
    try std.testing.expectEqualStrings("42", back.value.build_number.?);
    // On any other step's hook, or empty: refused.
    value.invocation.step = .build;
    try std.testing.expectError(error.InvalidInvocation, value.validate(true));
    value.invocation.step = .bundle;
    value.build_number = "";
    try std.testing.expectError(error.InvalidBuildNumber, value.validate(true));
}

test "a 1.0.0 context never carries build_number; every wire otherwise validates" {
    try std.testing.expectEqualStrings("1.4.0", version);
    try std.testing.expect(carriesBuildNumber("1.1.0"));
    try std.testing.expect(carriesBuildNumber("1.2.0"));
    try std.testing.expect(carriesBuildNumber("1.3.0"));
    try std.testing.expect(!carriesBuildNumber("1.0.0"));
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    var value = parsed.value;
    value.project_dir = value.package_dir;
    value.lock_file = value.zig_executable;
    value.target = "sample-target";
    value.invocation = .{ .kind = .hook, .id = "pack", .step = .bundle, .phase = .replace };
    // Every supported wire validates without the key (and with `target_dir`
    // exactly where the wire defines it)...
    for (supported_versions) |wire| {
        value.contract_version = wire;
        value.target_dir = if (carriesRunContext(wire)) value.package_dir else null;
        value.cache_dir = if (carriesToolchainContext(wire)) value.package_dir else null;
        value.final_step = if (carriesFinalStep(wire)) .bundle else null;
        try value.validate(true);
    }
    value.cache_dir = null;
    value.final_step = null;
    // ...and only a 1.1.0+ wire may carry it: a strict 1.0.0 decoder
    // rejects the key as unknown, so the CLI must never emit it there.
    value.build_number = "42";
    value.target_dir = null;
    value.contract_version = "1.0.0";
    try std.testing.expectError(error.UnsupportedContract, value.validate(true));
    value.contract_version = "1.1.0";
    try value.validate(true);
    value.contract_version = "1.2.0";
    value.target_dir = value.package_dir;
    try value.validate(true);
    value.contract_version = "1.3.0";
    value.cache_dir = value.package_dir;
    try value.validate(true);
    value.contract_version = "1.4.0";
    value.final_step = .bundle;
    try value.validate(true);
    value.contract_version = "1.5.0";
    try std.testing.expectError(error.UnsupportedContract, value.validate(true));
}

/// A project hook context on `wire` for `step`, from the projectless fixture.
pub fn hookContext(base: Context, wire: []const u8, step: Step) Context {
    var value = base;
    value.contract_version = wire;
    value.project_dir = value.package_dir;
    value.lock_file = value.zig_executable;
    value.target = "sample-target";
    value.invocation = .{ .kind = .hook, .id = "probe", .step = step, .phase = .replace };
    return value;
}
