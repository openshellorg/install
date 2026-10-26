/// Parse fixed-width text tables (winget, scoop) by the header's column positions.
module install_tool.table;

import std.algorithm : all, canFind, countUntil, map;
import std.array : array, split;
import std.string : strip, splitLines, indexOf, lastIndexOf;
import std.uni : byGrapheme;
import std.range : walkLength;

/// One row, keyed by header name.
alias Row = string[string];

/// Find a header line whose next line is dashes, then cut each later line at the header's column starts.
/// `required` names must all be present in the header. Lines after a blank line end the table.
Row[] parseTable(string text, const string[] required)
{
    string[] lines;
    foreach (l; text.splitLines)
    {
        auto cr = l.lastIndexOf('\r'); // progress spinners rewrite the line with \r
        lines ~= cr >= 0 ? l[cr + 1 .. $] : l;
    }
    foreach (h; 0 .. lines.length)
    {
        if (h + 1 >= lines.length) break;
        auto header = lines[h];
        auto dashes = lines[h + 1].strip;
        if (dashes.length < 3 || !dashes.all!(c => c == '-' || c == ' ')) continue;
        auto names = header.split;
        if (!required.all!(r => names.canFind(r))) continue;

        // column starts measured in characters (code points), not bytes
        auto hd = header.toDchars;
        size_t[] starts;
        string[] cols;
        foreach (i; 0 .. hd.length)
            if (hd[i] != ' ' && (i == 0 || hd[i - 1] == ' '))
            {
                starts ~= i;
                size_t e = i;
                while (e < hd.length && hd[e] != ' ') e++;
                cols ~= header.fromDchars(hd[i .. e]);
            }

        Row[] rows;
        foreach (l; lines[h + 2 .. $])
        {
            if (l.strip.length == 0) break;
            auto d = l.toDchars;
            Row r;
            foreach (ci, st; starts)
            {
                size_t en = ci + 1 < starts.length ? starts[ci + 1] : d.length;
                if (st >= d.length) { r[cols[ci]] = ""; continue; }
                if (en > d.length) en = d.length;
                r[cols[ci]] = header.fromDchars(d[st .. en]).strip;
            }
            rows ~= r;
        }
        return rows;
    }
    return null;
}

private dchar[] toDchars(string s) { import std.conv : to; return s.to!(dchar[]); }
private string fromDchars(string, const dchar[] d) { import std.conv : to; return d.to!string; }

unittest
{
    auto winget = "   - \r   \\ \rName             Id                      Version Match        Source\n" ~
        "--------------------------------------------------------------------\n" ~
        "RipGrep GNU      BurntSushi.ripgrep.GNU  15.2.0  Tag: ripgrep winget\n" ~
        "ugrep            Genivia.ugrep           7.8.5   Tag: ripgrep winget\n";
    auto rows = parseTable(winget, ["Name", "Id", "Version"]);
    assert(rows.length == 2);
    assert(rows[0]["Name"] == "RipGrep GNU");
    assert(rows[0]["Id"] == "BurntSushi.ripgrep.GNU");
    assert(rows[0]["Version"] == "15.2.0");
    assert(rows[1]["Source"] == "winget");

    // non-ASCII names keep column alignment by character
    auto u = "Name    Id       Version\n-------------------------\nCaf\u00e9 X  a.b      1.0\n";
    auto ur = parseTable(u, ["Name", "Id"]);
    assert(ur[0]["Name"] == "Caf\u00e9 X" && ur[0]["Id"] == "a.b" && ur[0]["Version"] == "1.0");

    auto scoop = "Results from local buckets...\n\nName    Version Source Binaries\n----    ------- ------ --------\nripgrep 14.1.0  main\n\n";
    auto sr = parseTable(scoop, ["Name", "Version", "Source"]);
    assert(sr.length == 1 && sr[0]["Name"] == "ripgrep" && sr[0]["Source"] == "main" && sr[0]["Binaries"] == "");

    assert(parseTable("No package found matching input criteria.", ["Name"]) is null);
}
