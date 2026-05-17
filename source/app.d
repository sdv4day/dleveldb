import std.stdio;
import std.conv : text;
import core.time : MonoTime;
import dleveldb.slice : Slice;
import dleveldb.coding : encodeVarint32, encodeFixed32, encodeFixed64;
import dleveldb.crc32c : crc32cValue;
import dleveldb.hash : hash;

void main()
{
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
}

/// DB操作性能测试
void benchDbOperations()
{
    import std.file : exists, rmdirRecurse;
    import dleveldb;

    string dbPath = "/tmp/dleveldb_bench";
    if (exists(dbPath))
        rmdirRecurse(dbPath);

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
    if (exists(dbPath))
        rmdirRecurse(dbPath);
}
