/+ dub.sdl:
name "benchmark_demo"
dependency "dleveldb" path="../"
+/

module examples.benchmark_demo;

/**
 * 性能测试 Demo
 * 
 * 测试 LevelDB 的 put/get 性能，并进行双向校验
 * 使用 dub --single 运行
 * 
 * 使用方法:
 *   dub --single examples/benchmark_demo.d
 */

import std.stdio;
import std.datetime.stopwatch;
import std.random;
import std.format;
import std.file;
import std.path;
import std.algorithm : min;
import dleveldb.db;
import dleveldb.options;
import dleveldb.slice;

/// 生成重复字符的字符串
/// Params: c = 要重复的字符
/// Params: n = 重复次数
/// Returns: 由 n 个字符 c 组成的字符串
private string repeatChar(char c, size_t n) pure
{
    auto result = new char[n];
    result[] = c;
    return result.idup;
}

/// 性能测试结果结构体
struct BenchmarkResult
{
    string operation;    /// 操作名称
    size_t count;        /// 操作次数
    Duration duration;   /// 总耗时
    double opsPerSec;    /// 每秒操作数
    double avgLatencyUs; /// 平均延迟（微秒）
}

void main()
{
    version (Windows)
    {
        import core.sys.windows.windows;
        SetConsoleOutputCP(65001);
        SetConsoleCP(65001);
    }

    writeln("╔══════════════════════════════════════════╗");
    writeln("║     LevelDB 性能测试与双向校验 Demo      ║");
    writeln("╚══════════════════════════════════════════╝");
    writeln();

    auto dbPath = buildPath("temp", "benchmark_db");
    if (exists(dbPath))
        rmdirRecurse(dbPath);

    auto opt = Options();
    opt.createIfMissing = true;

    auto db = new LevelDB(opt, dbPath);
    scope (exit)
    {
        db.close();
        if (exists(dbPath))
            rmdirRecurse(dbPath);
    }

    writeln("数据库路径: ", dbPath);
    writeln();

    auto writeResult = benchmarkWrite(db, 10_000);
    printResult(writeResult);

    auto readResult = benchmarkRead(db, 10_000);
    printResult(readResult);

    auto verifyResult = verifyData(db, 10_000);
    writeln();
    writeln(verifyResult ? "✓ 双向校验通过：所有数据一致" : "✗ 双向校验失败：数据不一致");
    writeln();

    auto mixedResult = benchmarkMixed(db, 5_000);
    printResult(mixedResult);

    writeln();
    writeln("性能测试完成！");
}

/// 测试写入性能
/// Params: db = 数据库实例
/// Params: count = 写入记录数
/// Returns: 性能测试结果
BenchmarkResult benchmarkWrite(LevelDB db, size_t count)
{
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("测试 1: 写入性能 (PUT)");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    auto sw = StopWatch(AutoStart.no);
    sw.start();

    foreach (i; 0 .. count)
    {
        string key = format("key_%08d", i);
        string value = format("value_%d_%s", i, repeatChar('x', 50));
        db.put(key, value);

        if ((i + 1) % 1000 == 0)
        {
            writefln("  已写入 %d/%d 条记录...", i + 1, count);
        }
    }

    sw.stop();

    return BenchmarkResult(
        "写入 (PUT)",
        count,
        sw.peek(),
        count / cast(double) sw.peek().total!"seconds",
        cast(double) sw.peek().total!"usecs" / count
    );
}

/// 测试读取性能
/// Params: db = 数据库实例
/// Params: count = 读取记录数
/// Returns: 性能测试结果
BenchmarkResult benchmarkRead(LevelDB db, size_t count)
{
    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("测试 2: 读取性能 (GET)");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    auto sw = StopWatch(AutoStart.no);
    sw.start();

    size_t found = 0;
    foreach (i; 0 .. count)
    {
        string key = format("key_%08d", i);
        string value;
        if (db.get(key, value))
            found++;

        if ((i + 1) % 1000 == 0)
        {
            writefln("  已读取 %d/%d 条记录...", i + 1, count);
        }
    }

    sw.stop();

    writeln("  找到记录数: ", found, "/", count);

    return BenchmarkResult(
        "读取 (GET)",
        count,
        sw.peek(),
        count / cast(double) sw.peek().total!"seconds",
        cast(double) sw.peek().total!"usecs" / count
    );
}

/// 双向校验数据一致性
/// Params: db = 数据库实例
/// Params: count = 校验记录数
/// Returns: true 表示所有数据一致，false 表示存在不一致
bool verifyData(LevelDB db, size_t count)
{
    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("测试 3: 双向校验 (写入值 == 读取值)");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    size_t verified = 0;
    size_t failed = 0;

    foreach (i; 0 .. count)
    {
        string key = format("key_%08d", i);
        string expectedValue = format("value_%d_%s", i, repeatChar('x', 50));
        string actualValue;

        if (db.get(key, actualValue))
        {
            if (actualValue == expectedValue)
            {
                verified++;
            }
            else
            {
                failed++;
                if (failed <= 5)
                {
                    writeln("  ✗ 键 '", key, "' 数据不一致");
                    writeln("    期望: ", expectedValue[0 .. min(30, expectedValue.length)], "...");
                    writeln("    实际: ", actualValue[0 .. min(30, actualValue.length)], "...");
                }
            }
        }
        else
        {
            failed++;
            if (failed <= 5)
            {
                writeln("  ✗ 键 '", key, "' 未找到");
            }
        }

        if ((i + 1) % 1000 == 0)
        {
            writefln("  已校验 %d/%d 条记录...", i + 1, count);
        }
    }

    writeln();
    writeln("  校验成功: ", verified);
    writeln("  校验失败: ", failed);

    return failed == 0;
}

/// 测试混合读写性能
/// Params: db = 数据库实例
/// Params: count = 操作次数
/// Returns: 性能测试结果
BenchmarkResult benchmarkMixed(LevelDB db, size_t count)
{
    writeln();
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    writeln("测试 4: 混合读写性能 (50% PUT + 50% GET)");
    writeln("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    auto rnd = Random(42);

    auto sw = StopWatch(AutoStart.no);
    sw.start();

    foreach (i; 0 .. count)
    {
        size_t keyIdx = uniform(0, count, rnd);
        string key = format("key_%08d", keyIdx);

        if (uniform(0, 2, rnd) == 0)
        {
            string value = format("updated_%d_%s", i, repeatChar('y', 40));
            db.put(key, value);
        }
        else
        {
            string value;
            db.get(key, value);
        }

        if ((i + 1) % 1000 == 0)
        {
            writefln("  已执行 %d/%d 次操作...", i + 1, count);
        }
    }

    sw.stop();

    return BenchmarkResult(
        "混合读写 (PUT+GET)",
        count,
        sw.peek(),
        count / cast(double) sw.peek().total!"seconds",
        cast(double) sw.peek().total!"usecs" / count
    );
}

/// 打印性能测试结果
/// Params: result = 性能测试结果
void printResult(BenchmarkResult result)
{
    writeln();
    writeln("┌─────────────────────────────────────────┐");
    writefln("│ %-39s │", result.operation ~ " 性能统计");
    writeln("├─────────────────────────────────────────┤");
    writefln("│ 操作次数: %-29d │", result.count);
    writefln("│ 总耗时: %-31s │", result.duration);
    writefln("│ 吞吐量: %-29.2f ops/s │", result.opsPerSec);
    writefln("│ 平均延迟: %-27.2f μs │", result.avgLatencyUs);
    writeln("└─────────────────────────────────────────┘");
}
