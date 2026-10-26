/// Package-manager providers for the read-only resolver. Search only: nothing here installs.
module install_tool.managers;

import std.algorithm : canFind, all, map;
import std.array : array, split;
import std.json;
import std.path : buildPath, pathSeparator;
import std.string : strip, indexOf, toLower;
import install_tool.table;

struct Hit
{
    string manager;  /// winget, scoop, npm
    string id;       /// what you would pass to that manager
    string name;
    string version_;
    string source;   /// manager source or bucket
    string summary;
}

struct Outcome
{
    string manager;
    bool available;  /// manager found on this machine
    bool ok;         /// search ran and was understood
    string note;     /// why not, when !ok or !available
    Hit[] hits;
}

/// Runs a program. Swappable for tests.
interface Runner
{
    /// Absolute path of a program, or null when it is not installed.
    string find(string program);
    /// Run argv (argv[0] is a path from find). Returns exit status and combined output.
    int run(string[] argv, out string output);
}

/// The only queries passed to managers: package-name characters. Keeps argv free of shell metacharacters
/// (scoop and npm run through .cmd shims on Windows).
bool isSafeQuery(string q) @safe pure
{
    import std.ascii : isAlphaNum;
    if (q.length == 0 || q.length > 100 || q[0] == '-') return false;
    return q.all!(c => c < 0x80 && (isAlphaNum(cast(char) c) || "@/._+-".canFind(c)));
}

immutable string[] allManagers = ["winget", "scoop", "npm"];

Outcome search(string manager, string query, Runner r)
{
    assert(isSafeQuery(query));
    switch (manager)
    {
        case "winget": return searchWinget(query, r);
        case "scoop": return searchScoop(query, r);
        case "npm": return searchNpm(query, r);
        default: assert(0, "unknown manager " ~ manager);
    }
}

Outcome searchWinget(string query, Runner r)
{
    auto o = Outcome("winget");
    auto exe = r.find("winget");
    if (exe is null) { o.note = "winget not found"; return o; }
    o.available = true;
    string text;
    auto code = r.run([exe, "search", query, "--accept-source-agreements", "--disable-interactivity"], text);
    o.ok = true;
    if (code != 0 && text.indexOf("No package found") >= 0) return o;
    auto rows = parseTable(text, ["Name", "Id", "Version"]);
    if (rows is null)
    {
        if (code != 0) { o.ok = false; o.note = firstLine(text, "winget search failed"); }
        return o;
    }
    foreach (row; rows)
        o.hits ~= Hit("winget", row.get("Id", ""), row.get("Name", ""), row.get("Version", ""), row.get("Source", ""), row.get("Match", ""));
    return o;
}

Outcome searchScoop(string query, Runner r)
{
    auto o = Outcome("scoop");
    auto exe = r.find("scoop");
    if (exe is null) { o.note = "scoop not found"; return o; }
    o.available = true;
    string text;
    auto code = r.run([exe, "search", query], text);
    o.ok = true;
    auto rows = parseTable(text, ["Name", "Version", "Source"]);
    if (rows is null)
    {
        if (code != 0 && text.indexOf("No matches") < 0) { o.ok = false; o.note = firstLine(text, "scoop search failed"); }
        return o;
    }
    foreach (row; rows)
    {
        auto bin = row.get("Binaries", "");
        o.hits ~= Hit("scoop", row["Name"], row["Name"], row.get("Version", ""), row.get("Source", ""), bin.length ? "binaries: " ~ bin : "");
    }
    return o;
}

Outcome searchNpm(string query, Runner r)
{
    auto o = Outcome("npm");
    auto exe = r.find("npm");
    if (exe is null) { o.note = "npm not found"; return o; }
    o.available = true;
    string text;
    auto code = r.run([exe, "search", "--json", "--searchlimit=20", query], text);
    auto start = text.indexOf('[');
    auto end = lastIndex(text, ']');
    if (start < 0 || end < start)
    {
        o.note = firstLine(text, "npm search returned no JSON");
        return o;
    }
    try
    {
        auto j = parseJSON(text[start .. end + 1]);
        foreach (p; j.array)
        {
            string get(string k) { auto v = k in p; return v && v.type == JSONType.string ? v.str : ""; }
            o.hits ~= Hit("npm", get("name"), get("name"), get("version"), "npmjs", get("description"));
        }
        o.ok = true;
    }
    catch (JSONException e) o.note = "npm search output was not JSON: " ~ e.msg;
    return o;
}

private ptrdiff_t lastIndex(string s, char c)
{
    foreach_reverse (i, ch; s) if (ch == c) return i;
    return -1;
}

private string firstLine(string text, string fallback)
{
    foreach (l; text.split('\n'))
    {
        auto t = l.strip;
        if (t.length && !t.startsWithAny(["npm warn", "npm WARN"])) return t;
    }
    return fallback;
}

private bool startsWithAny(string s, string[] ps)
{
    import std.algorithm : startsWith;
    foreach (p; ps) if (s.startsWith(p)) return true;
    return false;
}

/// Real runner: PATH + PATHEXT lookup, plus well-known install folders that agent or service shells
/// often lack on PATH (WindowsApps for winget, ~/scoop/shims for scoop).
final class SystemRunner : Runner
{
    string[string] env;
    this(string[string] env) { this.env = env; }

    private string var(string k)
    {
        foreach (key, v; env) { version (Windows) { if (toLower(key) == toLower(k)) return v; } else if (key == k) return v; }
        return null;
    }

    string find(string program)
    {
        import std.file : exists, isFile;
        string[] dirs = var("PATH").split(pathSeparator);
        string[] exts = [""];
        version (Windows)
        {
            auto pe = var("PATHEXT");
            exts = (pe.length ? pe : ".COM;.EXE;.BAT;.CMD").split(';');
            if (auto la = var("LOCALAPPDATA")) dirs ~= buildPath(la, "Microsoft", "WindowsApps");
            auto scoopRoot = var("SCOOP");
            if (scoopRoot is null) if (auto up = var("USERPROFILE")) scoopRoot = buildPath(up, "scoop");
            if (scoopRoot) dirs ~= buildPath(scoopRoot, "shims");
        }
        else
        {
            if (auto h = var("HOME")) dirs ~= buildPath(h, "scoop", "shims");
        }
        foreach (d; dirs)
        {
            if (d.strip.length == 0) continue;
            foreach (e; exts)
            {
                auto p = buildPath(d.strip, program ~ e);
                try { if (exists(p) && isFile(p)) return p; } catch (Exception) {}
            }
        }
        return null;
    }

    int run(string[] argv, out string output)
    {
        import std.process : execute, Config;
        string[] cmd = argv;
        version (Windows)
        {
            auto lower = toLower(argv[0]);
            import std.algorithm : endsWith;
            // .cmd/.bat shims need cmd.exe; isSafeQuery keeps metacharacters out of argv
            if (lower.endsWith(".cmd") || lower.endsWith(".bat")) cmd = ["cmd.exe", "/d", "/c"] ~ argv;
            if (lower.endsWith(".ps1")) cmd = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"] ~ argv;
        }
        try
        {
            auto r = execute(cmd, null, Config.suppressConsole);
            output = r.output;
            return r.status;
        }
        catch (Exception e) { output = e.msg; return 127; }
    }
}

version (unittest)
{
    final class FakeRunner : Runner
    {
        string[string] paths;
        string[string] outputs;
        int[string] codes;
        string[][] calls;
        string find(string p) { auto v = p in paths; return v ? *v : null; }
        int run(string[] argv, out string output)
        {
            calls ~= argv;
            foreach (k, v; paths) if (v == argv[0]) { output = outputs.get(k, ""); return codes.get(k, 0); }
            return 127;
        }
    }
}

unittest
{
    assert(isSafeQuery("ripgrep") && isSafeQuery("@vscode/ripgrep") && isSafeQuery("python3.12"));
    assert(!isSafeQuery("a&b") && !isSafeQuery("") && !isSafeQuery("--force") && !isSafeQuery("a b") && !isSafeQuery("x|y"));

    auto f = new FakeRunner;
    f.paths = ["winget": "W", "npm": "N"];
    f.outputs["winget"] = "Name  Id          Version Source\n------------------------------\nRg    Burnt.rg    15.2.0  winget\n";
    f.outputs["npm"] = "npm warn x\n[\n{\"name\":\"ripgrep\",\"version\":\"0.3.1\",\"description\":\"d\"}\n]\n";
    auto w = search("winget", "rg", f);
    assert(w.ok && w.hits.length == 1 && w.hits[0].id == "Burnt.rg" && w.hits[0].version_ == "15.2.0");
    auto n = search("npm", "ripgrep", f);
    assert(n.ok && n.hits[0].id == "ripgrep" && n.hits[0].summary == "d");
    auto s = search("scoop", "rg", f);
    assert(!s.available && s.note == "scoop not found");

    // read-only: only search subcommands are ever run
    foreach (c; f.calls) assert(c[1] == "search");

    f.outputs["winget"] = "No package found matching input criteria.";
    f.codes["winget"] = -1978335212;
    w = search("winget", "zzz", f);
    assert(w.ok && w.hits.length == 0);
    f.outputs["npm"] = "npm error code E500";
    f.codes["npm"] = 1;
    n = search("npm", "zzz", f);
    assert(!n.ok && n.note == "npm error code E500");
}
