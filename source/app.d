import std.stdio : stdout, stderr;
import std.process : environment;
import install_tool.cli : run, FileSink;
import install_tool.managers : SystemRunner;
import install_tool.passthrough : SystemPassthrough;

int main(string[] args)
{
    auto env = environment.toAA();
    return run(args[1 .. $], new FileSink(stdout), new FileSink(stderr), new SystemRunner(env), new SystemPassthrough);
}
