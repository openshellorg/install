/// PROVISIONAL: hand install(1)-style arguments (coreutils/BSD file copy) through to legacy/install,
/// so `make install` style build scripts keep working when `install` resolves to the resolver.
module install_tool.passthrough;

import std.algorithm : canFind, startsWith, any;

/// What the CLI needs from the system for passthrough. Null in tests that don't use it.
interface Passthrough
{
    bool isFile(string path);
    /// Path of the real install(1), or null. Never the resolver itself.
    string legacyInstall();
    /// Run legacy install with args, inheriting stdio. Returns its exit status.
    int exec(string path, string[] args);
}

private immutable string[] longOpts = [
    "--mode", "--owner", "--group", "--directory", "--target-directory", "--no-target-directory",
    "--strip", "--strip-program", "--preserve-timestamps", "--compare", "--backup", "--suffix",
    "--verbose", "--preserve-context", "--context", "--debug"];

/// install(1) short options (GNU and BSD): b c C d D g m o p s S t T v Z (and BSD M, U, B, f, l, N).
private enum shortOpts = "bcCdDgmopsStTvZMUBflN";

bool isInstall1Option(string a) @safe pure
{
    if (a.startsWith("--"))
        return longOpts.any!(o => a == o || a.startsWith(o ~ "="));
    return a.length >= 2 && a[0] == '-' && shortOpts.canFind(a[1]);
}

/// True when args look like install(1): any install(1) option, or a first operand that is an
/// existing file followed by a destination.
bool looksLikeInstall1(const string[] args, scope bool delegate(string) isFile)
{
    if (args.any!(a => isInstall1Option(a))) return true;
    return args.length >= 2 && !args[0].startsWith("-") && isFile(args[0]);
}

final class SystemPassthrough : Passthrough
{
    bool isFile(string p)
    {
        import std.file : exists, fileIsFile = isFile;
        try return exists(p) && fileIsFile(p); catch (Exception) return false;
    }

    string legacyInstall()
    {
        import std.file : exists, thisExePath;
        string self;
        try self = thisExePath(); catch (Exception) {}
        // Fixed system locations only: never search PATH, which may contain the resolver itself.
        foreach (c; ["/usr/bin/install", "/bin/install", "/usr/local/bin/ginstall", "/opt/homebrew/bin/ginstall"])
            if (exists(c) && c != self) return c;
        return null;
    }

    int exec(string path, string[] args)
    {
        import std.process : spawnProcess, wait;
        return wait(spawnProcess([path] ~ args));
    }
}

unittest
{
    bool delegate(string) files = (string p) => p == "build/app" || p == "README";
    assert(looksLikeInstall1(["-m", "755", "build/app", "/usr/local/bin"], files));
    assert(looksLikeInstall1(["-Dm644", "README", "/usr/share/doc/x/README"], files));
    assert(looksLikeInstall1(["-d", "/usr/local/share/x"], files));
    assert(looksLikeInstall1(["-o", "root", "-g", "wheel", "a", "b"], files));
    assert(looksLikeInstall1(["--mode=644", "a", "b"], files));
    assert(looksLikeInstall1(["build/app", "/usr/local/bin/app"], files));
    // resolver usage is not install(1)
    assert(!looksLikeInstall1(["ripgrep"], files));
    assert(!looksLikeInstall1(["ripgrep", "fd"], files));
    assert(!looksLikeInstall1(["--json"], files));
    assert(!looksLikeInstall1(["-h"], files));
    assert(!looksLikeInstall1(["--modes"], files));
}
