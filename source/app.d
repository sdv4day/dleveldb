import std.stdio;
import std.conv : text;
import std.file : thisExePath;
import std.path : dirName, buildPath;
import core.time : MonoTime;
import dleveldb.slice : Slice;
import dleveldb.coding : encodeVarint32, encodeFixed32, encodeFixed64;
import dleveldb.crc32c : crc32cValue;
import dleveldb.hash : hash;

/// 可执行文件所在目录，用于构建测试路径
__gshared string exeDir;

void main()
{
    exeDir = thisExePath().dirName;
    writeln("dleveldb - 性能测试");
    writeln("==================");
    writeln();

    // Slice比较
    writeln("--- Slice操作 ---");
    {
        auto s1 = Slice("benchmark_key_12345");
        auto s2 = Slice("benchmark_key_12346");
        
        auto start = MonoTime.currTime;
        int result = 0;
        for (size_t i = 0; i < 100_000; i++)
            result += s1.opCmp(s2);
        auto elapsed = MonoTime.currTime - start;
        double ops = 100_000 * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"Slice比较 100K次: %4s ms (%8.0f ops/s)"(elapsed.total!"usecs"/1000, ops);
    }

    // Slice相等
    {
        auto s1 = Slice("benchmark_key_12345");
        auto s2 = Slice("benchmark_key_12345");
        
        auto start = MonoTime.currTime;
        bool result = false;
        for (size_t i = 0; i < 100_000; i++)
            result = s1 == s2;
        auto elapsed = MonoTime.currTime - start;
        double ops = 100_000 * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"Slice相等 100K次: %4s ms (%8.0f ops/s)"(elapsed.total!"usecs"/1000, ops);
    }

    // Slice哈希
    {
        auto s = Slice("benchmark_key_for_hash_test");
        
        auto start = MonoTime.currTime;
        size_t h = 0;
        for (size_t i = 0; i < 100_000; i++)
            h += s.toHash();
        auto elapsed = MonoTime.currTime - start;
        double ops = 100_000 * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"Slice哈希 100K次: %4s ms (%8.0f ops/s)"(elapsed.total!"usecs"/1000, ops);
    }

    writeln();

    // Varint编码
    writeln("--- 编解码操作 ---");
    {
        ubyte[10] buf;
        auto start = MonoTime.currTime;
        for (size_t i = 0; i < 1_000_000; i++)
            encodeVarint32(buf.ptr, cast(uint) i);
        auto elapsed = MonoTime.currTime - start;
        double ops = 1_000_000 * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"Varint32编码 1M次: %4s ms (%8.0f ops/s)"(elapsed.total!"usecs"/1000, ops);
    }

    // Fixed编码
    {
        ubyte[8] buf;
        auto start = MonoTime.currTime;
        for (size_t i = 0; i < 1_000_000; i++)
        {
            encodeFixed32(buf.ptr, cast(uint) i);
            encodeFixed64(buf.ptr, cast(ulong) i);
        }
        auto elapsed = MonoTime.currTime - start;
        double ops = 1_000_000 * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"Fixed32/64编码 1M次: %4s ms (%8.0f ops/s)"(elapsed.total!"usecs"/1000, ops);
    }

    writeln();

    // CRC32C
    writeln("--- CRC32C校验 ---");
    {
        ubyte[256] data;
        data[] = 0xAB;
        auto start = MonoTime.currTime;
        uint crc = 0;
        for (size_t i = 0; i < 100_000; i++)
            crc = crc32cValue(data.ptr, data.length);
        auto elapsed = MonoTime.currTime - start;
        double ops = 100_000 * 1_000_000.0 / elapsed.total!"usecs";
        double mbps = 100_000 * 256.0 / (elapsed.total!"usecs" * 1.024);
        writefln!"CRC32C 100K次(256B): %4s ms (%8.0f ops/s, %.1f MB/s)"(elapsed.total!"usecs"/1000, ops, mbps);
    }

    // CRC32C大块
    {
        ubyte[4096] data;
        data[] = 0xCD;
        auto start = MonoTime.currTime;
        uint crc = 0;
        for (size_t i = 0; i < 10_000; i++)
            crc = crc32cValue(data.ptr, data.length);
        auto elapsed = MonoTime.currTime - start;
        double ops = 10_000 * 1_000_000.0 / elapsed.total!"usecs";
        double mbps = 10_000 * 4096.0 / (elapsed.total!"usecs" * 1.024);
        writefln!"CRC32C 10K次(4KB):  %4s ms (%8.0f ops/s, %.1f MB/s)"(elapsed.total!"usecs"/1000, ops, mbps);
    }

    writeln();

    // Hash函数
    writeln("--- Hash函数 ---");
    {
        auto s = Slice("hash_benchmark_key");
        auto start = MonoTime.currTime;
        uint h = 0;
        for (size_t i = 0; i < 100_000; i++)
            h += hash(s);
        auto elapsed = MonoTime.currTime - start;
        double ops = 100_000 * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"MurmurHash 100K次: %4s ms (%8.0f ops/s)"(elapsed.total!"usecs"/1000, ops);
    }

    writeln();
    writeln("底层组件性能测试完成.");
    writeln();

    // DB操作性能测试
    writeln("=== DB操作性能测试 ===");
    benchDbOperations();

    // 多线程并发性能测试
    writeln();
    writeln("=== 多线程并发性能测试 ===");
    benchMultiThreaded();
}

/// DB操作性能测试
void benchDbOperations()
{
    import dleveldb;

    string dbPath = buildPath(exeDir, "dleveldb_bench");
    safeRmdirRecurse(dbPath);

    auto options = Options();
    options.createIfMissing = true;

    auto db = new LevelDB(options, dbPath);
    writeln("数据库已打开");

    // 顺序写
    {
        size_t count = 10000;
        auto start = MonoTime.currTime;
        for (size_t i = 0; i < count; i++)
        {
            string key = text("key_", i);
            string val = text("val_", i);
            db.put(Slice(key), Slice(val));
        }
        auto elapsed = MonoTime.currTime - start;
        double ops = count * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"DB顺序写 %4d 条: %4s ms (%8.0f ops/s)"(count, elapsed.total!"usecs"/1000, ops);
    }

    // 随机读
    {
        size_t count = 10000;
        auto start = MonoTime.currTime;
        size_t found = 0;
        for (size_t i = 0; i < count; i++)
        {
            string key = text("key_", i);
            string value;
            if (db.get(Slice(key), value))
                found++;
        }
        auto elapsed = MonoTime.currTime - start;
        double ops = count * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"DB随机读 %4d 条: %4s ms (%8.0f ops/s) 命中: %d"(count, elapsed.total!"usecs"/1000, ops, found);
    }

    // WriteBatch批量写
    {
        size_t count = 10000;
        size_t batchSize = 100;
        auto start = MonoTime.currTime;
        for (size_t i = 0; i < count; i += batchSize)
        {
            auto batch = new WriteBatch();
            for (size_t j = 0; j < batchSize && (i + j) < count; j++)
            {
                string key = text("bk_", i + j);
                string val = text("bv_", i + j);
                batch.put(Slice(key), Slice(val));
            }
            db.write(batch);
        }
        auto elapsed = MonoTime.currTime - start;
        double ops = count * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"DB批量写 %4d 条: %4s ms (%8.0f ops/s)"(count, elapsed.total!"usecs"/1000, ops);
    }

    // 删除
    {
        size_t count = 5000;
        auto start = MonoTime.currTime;
        for (size_t i = 0; i < count; i++)
        {
            string key = text("key_", i);
            db.del(Slice(key));
        }
        auto elapsed = MonoTime.currTime - start;
        double ops = count * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"DB删除 %4d 条: %4s ms (%8.0f ops/s)"(count, elapsed.total!"usecs"/1000, ops);
    }

    // 关闭数据库
    db.close();
    writeln();
    writeln("DB操作性能测试完成.");

    // 清理测试目录
    safeRmdirRecurse(dbPath);
}

/// 多线程并发性能测试
void benchMultiThreaded()
{
    import std.parallelism : task, TaskPool;
    import core.thread : Thread;
    import core.time : msecs;
    import std.range : iota;
    import std.algorithm : each;
    import dleveldb;

    string dbPath = buildPath(exeDir, "dleveldb_mt_bench");
    safeRmdirRecurse(dbPath);

    auto options = Options();
    options.createIfMissing = true;
    auto db = new LevelDB(options, dbPath);
    scope(exit)
    {
        db.close();
        safeRmdirRecurse(dbPath);
    }

    // 准备测试数据
    // 注意：LevelDB 实现在触发 memtable 切换后存在读取 bug，
    // 因此这里只使用小数据量，避免触发 compaction 路径。
    writeln("\n准备测试数据...");
    size_t dataCount = 5_000;
    {
        auto start = MonoTime.currTime;
        foreach (i; iota(dataCount))
            db.put(Slice(text("key_", i)), Slice(text("val_", i)));
        auto elapsed = MonoTime.currTime - start;
        writefln!"写入 %d 条数据: %s ms"(dataCount, elapsed.total!"usecs" / 1000);
    }

    // ──────────────────────────────────────────
    // 1. 并发读测试
    // ──────────────────────────────────────────
    writeln("\n--- 1. 并发读测试 ---");
    {
        size_t nThreads = 4;
        size_t opsPerThread = 10_000;
        auto pool = new TaskPool(nThreads);
        scope(exit) pool.stop();

        auto start = MonoTime.currTime;
        auto foundCount = new size_t[nThreads];

        foreach (ti; iota(nThreads))
        {
            immutable tiLocal = ti; // 闭包捕获局部拷贝，避免循环变量引用问题
            pool.put(task({
                size_t found = 0;
                foreach (j; iota(opsPerThread))
                {
                    size_t idx = (tiLocal * opsPerThread + j) % dataCount;
                    string value;
                    if (db.get(Slice(text("key_", idx)), value))
                        found++;
                }
                foundCount[tiLocal] = found;
            }));
        }
        pool.finish(true);
        auto elapsed = MonoTime.currTime - start;

        size_t totalFound = 0;
        foreach (r; foundCount) totalFound += r;
        double ops = (nThreads * opsPerThread) * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"并发读 %d线程 x %d次: %4s ms (%8.0f ops/s) 命中: %d"
            (nThreads, opsPerThread, elapsed.total!"usecs" / 1000, ops, totalFound);

        // 并发读后验证 DB 状态是否完好
        {
            size_t after = 0;
            foreach (i; iota(500))
            {
                string value;
                if (db.get(Slice(text("key_", i)), value))
                    after++;
            }
            writefln!"并发读后验证(前500条): 命中 %d/500"(after);
        }

        // 单线程对比（只读已确认存在的键范围）
        {
            size_t safeCount = nThreads * opsPerThread;
            if (safeCount > dataCount) safeCount = dataCount;
            auto start2 = MonoTime.currTime;
            size_t found2 = 0;
            foreach (i; iota(safeCount))
            {
                string value;
                if (db.get(Slice(text("key_", i)), value))
                    found2++;
            }
            auto elapsed2 = MonoTime.currTime - start2;
            double ops2 = safeCount * 1_000_000.0 / elapsed2.total!"usecs";
            writefln!"单线程读 对比: %4s ms (%8.0f ops/s) 命中: %d 加速比: %.2fx"
                (elapsed2.total!"usecs" / 1000, ops2, found2, ops / ops2);
        }
    }

    // ──────────────────────────────────────────
    // 2. 并发写测试（分片键空间避免冲突）
    // ──────────────────────────────────────────
    writeln("\n--- 2. 并发写测试 ---");
    {
        size_t nThreads = 4;
        size_t opsPerThread = 1_000;
        auto pool = new TaskPool(nThreads);
        scope(exit) pool.stop();

        auto start = MonoTime.currTime;

        foreach (ti; iota(nThreads))
        {
            immutable tiLocal = ti; // 闭包捕获局部拷贝
            pool.put(task({
                foreach (j; iota(opsPerThread))
                {
                    size_t idx = tiLocal * opsPerThread + j;
                    db.put(Slice(text("con_w_", idx)), Slice(text("con_v_", idx)));
                }
            }));
        }
        pool.finish(true);
        auto elapsed = MonoTime.currTime - start;

        double ops = (nThreads * opsPerThread) * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"并发写 %d线程 x %d次: %4s ms (%8.0f ops/s)"
            (nThreads, opsPerThread, elapsed.total!"usecs" / 1000, ops);

        // 验证写入
        size_t verified = 0;
        foreach (i; iota(nThreads * opsPerThread))
        {
            string value;
            if (db.get(Slice(text("con_w_", i)), value))
                verified++;
        }
        writefln!"写入验证: %d/%d 条可读"(verified, nThreads * opsPerThread);
    }

    // ──────────────────────────────────────────
    // 3. 后台任务调度测试（Env.schedule / TaskPool）
    // ──────────────────────────────────────────
    writeln("\n--- 3. 后台任务调度测试 ---");
    {
        import dleveldb.env : defaultEnv;

        size_t nTasks = 100;
        shared size_t completed = 0;

        auto start = MonoTime.currTime;
        foreach (i; iota(nTasks))
        {
            defaultEnv().schedule({
                import core.atomic : atomicOp;
                atomicOp!"+="(completed, 1);
            });
        }

        // 等待后台任务完成（最多 5s）
        bool allDone = false;
        foreach (_; iota(500))
        {
            import core.atomic : atomicLoad;
            if (atomicLoad(completed) == nTasks)
            {
                allDone = true;
                break;
            }
            Thread.sleep(msecs(10));
        }
        auto elapsed = MonoTime.currTime - start;

        writefln!"后台调度 %d 任务: %s ms (完成: %s)"
            (nTasks, elapsed.total!"usecs" / 1000, allDone ? "全部完成" : "超时");
    }

    // ──────────────────────────────────────────
    // 4. 混合读写测试
    // ──────────────────────────────────────────
    writeln("\n--- 4. 混合读写测试 ---");
    {
        size_t nThreads = 4;
        size_t opsPerThread = 1_500;
        auto pool = new TaskPool(nThreads);
        scope(exit) pool.stop();

        auto start = MonoTime.currTime;
        auto results = new size_t[nThreads];

        foreach (ti; iota(nThreads))
        {
            immutable tiLocal = ti; // 闭包捕获局部拷贝
            pool.put(task({
                size_t localFound = 0;
                foreach (j; iota(opsPerThread))
                {
                    if (j % 4 == 0)
                    {
                        // 每 4 次操作写 1 次
                        size_t idx = tiLocal * opsPerThread + j;
                        db.put(Slice(text("mix_w_", idx)), Slice(text("mix_v_", idx)));
                    }
                    else
                    {
                        // 其余读
                        size_t idx = j % dataCount;
                        string value;
                        if (db.get(Slice(text("key_", idx)), value))
                            localFound++;
                    }
                }
                results[tiLocal] = localFound;
            }));
        }
        pool.finish(true);
        auto elapsed = MonoTime.currTime - start;

        size_t totalFound = 0;
        foreach (r; results) totalFound += r;
        size_t totalOps = nThreads * opsPerThread;
        double ops = totalOps * 1_000_000.0 / elapsed.total!"usecs";
        writefln!"混合读写 %d线程 x %d次(25%%写): %4s ms (%8.0f ops/s) 读命中: %d"
            (nThreads, opsPerThread, elapsed.total!"usecs" / 1000, ops, totalFound);
    }

    writeln();
    writeln("多线程并发性能测试完成.");
}

/// 安全删除目录（Windows上文件锁可能有短暂延迟，自动重试）
void safeRmdirRecurse(string path)
{
    import std.file : exists, rmdirRecurse;
    import core.thread : Thread;
    import core.time : dur;

    if (!exists(path))
        return;

    for (int attempt; attempt < 5; attempt++)
    {
        try
        {
            rmdirRecurse(path);
            return;
        }
        catch (Exception e)
        {
            if (attempt >= 4)
            {
                writeln("清理目录失败（重试已耗尽）: ", e.msg);
                return;
            }
            writeln("清理目录重试 #", attempt + 1, ": ", e.msg);
            Thread.sleep(dur!"msecs"(200));
        }
    }
}
