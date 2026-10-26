/// `osh-install` command line (the `install` verb in the namespace). v0 is read-only: search only.
/// CLI Dispatch: bare = help (exit 0); unknown command/flag = exit 2 with did-you-mean; stray args = exit 2.
module install_tool.cli;

import std.algorithm : canFind, startsWith, map, sort, uniq, filter;
import std.algorithm.comparison : levenshteinDistance;
import std.array : array, join, split;
import std.format : format;
import std.json;
import std.stdio : File;
import install_tool.managers;

enum installVersion = "0.1.0";
immutable string[] commands = ["search", "managers", "help"];

private enum helpText = `osh-install - find a package across package managers (read-only)

Usage:
  osh-install <command> [options]

Commands:
  search <query>   Search winget, scoop and npm for <query>
  managers         Show which package managers were found
  help             Show this help

Options:
  --manager <m>    Only search these managers (winget, scoop, npm); repeat or comma-separate
  --json           Machine-readable output
  -h, --help       Show help
  --version        Show version

This version never installs anything. It only runs each manager's search.
In the command namespace this is the 'install' verb; 'osh-install' is the
name for shells that still use PATH (coreutils already has 'install').
Exit codes: 0 results found, 1 no results, 2 usage error.
`;

interface Sink { void put(string s); }
final class FileSink : Sink { File f; this(File f) { this.f = f; } void put(string s) { f.write(s); } }
final class BufSink : Sink { string data; void put(string s) { data ~= s; } }

private string[] didYouMean(string w, const(string)[] opts)
{
    string[] r;
    foreach (o; opts)
        if (levenshteinDistance(w, o) <= (w.length <= 4 ? 1 : 2) || (w.length >= 2 && o.startsWith(w))) r ~= o;
    return r;
}

private int usage(Sink err, string msg, string[] hints = null, string extra = null)
{
    err.put("osh-install: " ~ msg ~ "\n");
    if (hints.length) err.put("Did you mean: " ~ hints.join(", ") ~ "?\n");
    if (extra.length) err.put(extra ~ "\n");
    err.put("Run 'osh-install --help' for usage.\n");
    return 2;
}

int run(string[] args, Sink out_, Sink err, Runner runner)
{
    if (args.length == 0) { out_.put(helpText); return 0; }

    bool json;
    string[] managers;
    string[] rest;
    for (size_t i = 0; i < args.length; i++)
    {
        auto a = args[i];
        if (a == "--json") { json = true; continue; }
        if (a == "--manager" || a.startsWith("--manager="))
        {
            string v;
            if (a == "--manager")
            {
                if (i + 1 >= args.length) return usage(err, "'--manager' needs a value: winget, scoop or npm");
                v = args[++i];
            }
            else v = a["--manager=".length .. $];
            foreach (m; v.split(','))
            {
                if (!allManagers.canFind(m))
                    return usage(err, format("unknown manager '%s'", m), didYouMean(m, allManagers), "Managers: " ~ allManagers.join(", "));
                if (!managers.canFind(m)) managers ~= m;
            }
            continue;
        }
        if (a == "-h" || a == "--help") { out_.put(helpText); return 0; }
        rest ~= a;
    }
    if (rest.length == 0)
    {
        if (json || managers.length) return usage(err, "missing command");
        out_.put(helpText);
        return 0;
    }

    auto cmd = rest[0];
    auto params = rest[1 .. $];
    if (cmd == "--version")
    {
        if (params.length) return usage(err, "'--version' takes no arguments");
        out_.put("osh-install " ~ installVersion ~ "\n");
        return 0;
    }
    if (cmd.startsWith("-"))
        return usage(err, format("unknown option '%s'", cmd), didYouMean(cmd, ["--help", "--version", "--json", "--manager"]));
    foreach (p; params)
        if (p.startsWith("-") && p.length > 1)
            return usage(err, format("unknown option '%s' for '%s'", p, cmd), didYouMean(p, ["--json", "--manager", "--help"]));

    switch (cmd)
    {
        case "help":
            if (params.length) return usage(err, "'help' takes no arguments");
            out_.put(helpText);
            return 0;
        case "managers":
            if (params.length) return usage(err, format("'managers' takes no arguments, got: %s", params.join(" ")));
            return cmdManagers(runner, json, out_);
        case "search":
            if (params.length == 0) return usage(err, "'search' needs a query: osh-install search <query>");
            if (params.length > 1) return usage(err, format("'search' takes one query, got %s: %s", params.length, params.join(" ")));
            if (!isSafeQuery(params[0]))
                return usage(err, format("'%s' is not a package name (letters, digits and @/._+- only)", params[0]));
            return cmdSearch(runner, params[0], managers.length ? managers : allManagers.dup, json, out_, err);
        default:
            auto hints = didYouMean(cmd, commands);
            string extra;
            if (hints.length == 0 && isSafeQuery(cmd))
                extra = format("Installing is not available yet (read-only v0). To look it up: osh-install search %s", cmd);
            return usage(err, format("unknown command '%s'", cmd), hints, extra);
    }
}

int cmdManagers(Runner r, bool json, Sink out_)
{
    JSONValue[] arr;
    foreach (m; allManagers)
    {
        auto p = r.find(m);
        if (json) { JSONValue j = ["manager": m]; j["path"] = p is null ? JSONValue(null) : JSONValue(p); arr ~= j; }
        else out_.put(format("%-7s %s\n", m, p is null ? "not found" : p));
    }
    if (json) out_.put(JSONValue(arr).toString() ~ "\n");
    return 0;
}

int cmdSearch(Runner r, string query, string[] managers, bool json, Sink out_, Sink err)
{
    Outcome[] outs;
    foreach (m; managers) outs ~= search(m, query, r);
    size_t total;
    foreach (o; outs) total += o.hits.length;

    if (json)
    {
        JSONValue[] res;
        foreach (o; outs)
        {
            JSONValue j = ["manager": o.manager];
            j["available"] = o.available;
            j["ok"] = o.ok;
            if (o.note.length) j["note"] = o.note;
            j["hits"] = JSONValue(o.hits.map!(h => JSONValue([
                "id": h.id, "name": h.name, "version": h.version_, "source": h.source, "summary": h.summary])).array);
            res ~= j;
        }
        JSONValue top = ["query": query];
        top["results"] = res;
        out_.put(top.toString() ~ "\n");
        return total ? 0 : 1;
    }

    foreach (o; outs)
    {
        if (!o.available) { out_.put(format("%s: skipped (%s)\n", o.manager, o.note)); continue; }
        if (!o.ok) { out_.put(format("%s: search failed: %s\n", o.manager, o.note)); continue; }
        out_.put(format("%s: %s result(s)\n", o.manager, o.hits.length));
        foreach (h; o.hits)
            out_.put(format("  %-40s %-12s %s\n", h.id, h.version_, h.name != h.id ? h.name : h.summary.length > 60 ? h.summary[0 .. 57] ~ "..." : h.summary));
    }
    if (total == 0) err.put(format("osh-install: no package matching '%s' in %s\n", query, managers.join(", ")));
    else out_.put(format("%s result(s) for '%s'. Nothing was installed.\n", total, query));
    return total ? 0 : 1;
}

version (unittest)
{
    import install_tool.managers : FakeRunner;
    private FakeRunner fake()
    {
        auto f = new FakeRunner;
        f.paths = ["winget": "W", "npm": "N"];
        f.outputs["winget"] = "Name  Id          Version Source\n------------------------------\nRg    Burnt.rg    15.2.0  winget\n";
        f.outputs["npm"] = "[{\"name\":\"ripgrep\",\"version\":\"0.3.1\",\"description\":\"d\"}]";
        return f;
    }
    private int t(string[] a, out string o, out string e, FakeRunner f = null)
    {
        auto so = new BufSink, se = new BufSink;
        auto c = run(a, so, se, f is null ? fake() : f);
        o = so.data; e = se.data;
        return c;
    }
}

unittest
{
    string o, e;
    // CD: bare = help
    assert(t([], o, e) == 0 && o.canFind("Usage:"));
    assert(t(["--help"], o, e) == 0 && t(["help"], o, e) == 0);
    assert(t(["--version"], o, e) == 0 && o.canFind(installVersion));
    // unknown command / flag -> 2 with did-you-mean
    assert(t(["serch", "x"], o, e) == 2 && e.canFind("Did you mean: search?"));
    assert(t(["ripgrep"], o, e) == 2 && e.canFind("read-only v0") && e.canFind("osh-install search ripgrep"));
    assert(t(["--jsno"], o, e) == 2 && e.canFind("--json"));
    assert(t(["search", "x", "--force"], o, e) == 2);
    assert(t(["search", "x", "--manager", "wingit"], o, e) == 2 && e.canFind("winget"));
    assert(t(["search", "--manager"], o, e) == 2);
    // stray args
    assert(t(["search"], o, e) == 2);
    assert(t(["search", "a", "b"], o, e) == 2);
    assert(t(["managers", "x"], o, e) == 2);
    assert(t(["search", "a&calc"], o, e) == 2);
}

unittest
{
    string o, e;
    auto f = fake();
    assert(t(["search", "rg"], o, e, f) == 0);
    assert(o.canFind("winget: 1 result(s)") && o.canFind("Burnt.rg") && o.canFind("scoop: skipped (scoop not found)"));
    assert(o.canFind("Nothing was installed."));
    foreach (c; f.calls) assert(c[1] == "search"); // never install

    assert(t(["--json", "search", "rg", "--manager=npm"], o, e) == 0);
    auto j = parseJSON(o);
    assert(j["results"].array.length == 1 && j["results"][0]["hits"][0]["id"].str == "ripgrep");

    auto f2 = fake();
    f2.outputs["winget"] = "No package found matching input criteria.";
    f2.outputs["npm"] = "[]";
    assert(t(["search", "zzz"], o, e, f2) == 1 && e.canFind("no package matching"));

    assert(t(["managers"], o, e) == 0 && o.canFind("scoop   not found"));
}
