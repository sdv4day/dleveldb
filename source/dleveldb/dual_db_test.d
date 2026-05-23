/**
 * 双库交叉验证测试单元
 * 
 * 使用两个独立的 dleveldb 实例进行交叉对比验证：
 * - 库A：默认 BytewiseComparator，无压缩
 * - 库B：不同 writeBufferSize / blockSize 参数
 * - 向两个库写入相同的键值对
 * - 从两个库分别读取，对比结果一致性
 * - 测试覆盖：顺序写入/读取、删除后读取、批量写入、覆盖写入、迭代器遍历
 */
module dleveldb.dual_db_test;

import dleveldb;
import dleveldb.db_impl : DbIteratorWithRefs;

import std.file : exists, rmdirRecurse;
import std.format : format;
import std.path : buildPath;

private string makeTempPath(string sub)
{
    import std.file : tempDir;
    return buildPath(tempDir().idup, "dleveldb_test", sub);
}

/**
 * 双库交叉验证：写入后读取对比
 */
void testDualDbPutGet()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 顺序写入/读取交叉对比...");

    string pathA = makeTempPath("dual_a");
    string pathB = makeTempPath("dual_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto optA = Options();
    optA.createIfMissing = true;
    optA.compression = CompressionType.none;

    auto optB = Options();
    optB.createIfMissing = true;
    optB.compression = CompressionType.none;
    optB.writeBufferSize = 2 * 1024 * 1024;
    optB.blockSize = 8 * 1024;
    optB.maxFileSize = 4 * 1024 * 1024;

    auto dbA = new LevelDB(optA, pathA);
    auto dbB = new LevelDB(optB, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    int n = 100;
    for (int i = 0; i < n; i++)
    {
        string key = format("key_%04d", i);
        string value = format("value_%04d", i);
        dbA.put(key, value);
        dbB.put(key, value);
    }

    int matchCount = 0;
    for (int i = 0; i < n; i++)
    {
        string key = format("key_%04d", i);
        string expected = format("value_%04d", i);

        string valA, valB;
        bool foundA = dbA.get(key, valA);
        bool foundB = dbB.get(key, valB);

        assert(foundA, format("库A: key=%s 未找到", key));
        assert(foundB, format("库B: key=%s 未找到", key));
        assert(valA == expected, format("库A: key=%s got=%s exp=%s", key, valA, expected));
        assert(valB == expected, format("库B: key=%s got=%s exp=%s", key, valB, expected));
        assert(valA == valB, format("交叉对比失败: key=%s A=%s B=%s", key, valA, valB));
        matchCount++;
    }
    assert(matchCount == n);
}

/**
 * 双库交叉验证：删除后读取对比
 */
void testDualDbDelete()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 删除后读取交叉对比...");

    string pathA = makeTempPath("dual_del_a");
    string pathB = makeTempPath("dual_del_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto opt = Options();
    opt.createIfMissing = true;
    opt.compression = CompressionType.none;

    auto dbA = new LevelDB(opt, pathA);
    auto dbB = new LevelDB(opt, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    for (int i = 0; i < 50; i++)
    {
        string key = format("del_key_%04d", i);
        string value = format("del_val_%04d", i);
        dbA.put(key, value);
        dbB.put(key, value);
    }

    for (int i = 0; i < 50; i += 2)
    {
        string key = format("del_key_%04d", i);
        dbA.del(key);
        dbB.del(key);
    }

    for (int i = 0; i < 50; i++)
    {
        string key = format("del_key_%04d", i);
        string valA, valB;
        bool foundA = dbA.get(key, valA);
        bool foundB = dbB.get(key, valB);

        if (i % 2 == 0)
        {
            assert(!foundA, format("库A: 偶数键%s应已删除", key));
            assert(!foundB, format("库B: 偶数键%s应已删除", key));
        }
        else
        {
            assert(foundA && foundB);
            assert(valA == valB, format("删除后交叉对比失败: key=%s A=%s B=%s", key, valA, valB));
        }
    }
}

/**
 * 双库交叉验证：覆盖写入
 */
void testDualDbOverwrite()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 覆盖写入交叉对比...");

    string pathA = makeTempPath("dual_ow_a");
    string pathB = makeTempPath("dual_ow_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto opt = Options();
    opt.createIfMissing = true;
    opt.compression = CompressionType.none;

    auto dbA = new LevelDB(opt, pathA);
    auto dbB = new LevelDB(opt, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    for (int i = 0; i < 30; i++)
    {
        string key = format("ow_key_%04d", i);
        dbA.put(key, format("v1_%04d", i));
        dbB.put(key, format("v1_%04d", i));
    }

    for (int i = 0; i < 30; i++)
    {
        string key = format("ow_key_%04d", i);
        dbA.put(key, format("v2_%04d", i));
        dbB.put(key, format("v2_%04d", i));
    }

    for (int i = 0; i < 30; i++)
    {
        string key = format("ow_key_%04d", i);
        string expected = format("v2_%04d", i);

        string valA, valB;
        assert(dbA.get(key, valA));
        assert(dbB.get(key, valB));
        assert(valA == expected, format("库A覆盖失败: got=%s exp=%s", valA, expected));
        assert(valB == expected, format("库B覆盖失败: got=%s exp=%s", valB, expected));
        assert(valA == valB);
    }
}

/**
 * 双库交叉验证：WriteBatch 批量写入
 */
void testDualDbBatchWrite()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 批量写入交叉对比...");

    string pathA = makeTempPath("dual_batch_a");
    string pathB = makeTempPath("dual_batch_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto opt = Options();
    opt.createIfMissing = true;
    opt.compression = CompressionType.none;

    auto dbA = new LevelDB(opt, pathA);
    auto dbB = new LevelDB(opt, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    // 库A使用WriteBatch批量写入
    auto batchA = new WriteBatch();
    for (int i = 0; i < 50; i++)
    {
        batchA.put(Slice(format("batch_key_%04d", i)), Slice(format("batch_val_%04d", i)));
    }
    dbA.write(batchA);

    // 库B逐条写入
    for (int i = 0; i < 50; i++)
    {
        dbB.put(format("batch_key_%04d", i), format("batch_val_%04d", i));
    }

    for (int i = 0; i < 50; i++)
    {
        string key = format("batch_key_%04d", i);
        string expected = format("batch_val_%04d", i);

        string valA, valB;
        assert(dbA.get(key, valA));
        assert(dbB.get(key, valB));
        assert(valA == expected);
        assert(valB == expected);
        assert(valA == valB);
    }
}

/**
 * 双库交叉验证：不存在的键读取
 */
void testDualDbNotFound()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 不存在的键交叉对比...");

    string pathA = makeTempPath("dual_nf_a");
    string pathB = makeTempPath("dual_nf_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto opt = Options();
    opt.createIfMissing = true;
    opt.compression = CompressionType.none;

    auto dbA = new LevelDB(opt, pathA);
    auto dbB = new LevelDB(opt, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    dbA.put("exist_key", "exist_val");
    dbB.put("exist_key", "exist_val");

    string valA, valB;
    assert(!dbA.get("no_such_key", valA));
    assert(!dbB.get("no_such_key", valB));

    assert(dbA.get("exist_key", valA));
    assert(dbB.get("exist_key", valB));
    assert(valA == valB);
}

/**
 * 双库交叉验证：迭代器遍历对比
 */
void testDualDbIterator()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 迭代器遍历交叉对比...");

    string pathA = makeTempPath("dual_iter_a");
    string pathB = makeTempPath("dual_iter_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto opt = Options();
    opt.createIfMissing = true;
    opt.compression = CompressionType.none;

    auto dbA = new LevelDB(opt, pathA);
    auto dbB = new LevelDB(opt, pathB);

    int n = 50;
    for (int i = 0; i < n; i++)
    {
        string key = format("iter_key_%04d", i);
        string value = format("iter_val_%04d", i);
        dbA.put(key, value);
        dbB.put(key, value);
    }

    auto iterA = dbA.iterator();
    auto iterB = dbB.iterator();

    iterA.seekToFirst();
    iterB.seekToFirst();

    int countA, countB;
    while (iterA.valid() && iterB.valid())
    {
        assert(iterA.key() == iterB.key(), format("迭代器key不一致: A=%s B=%s", iterA.key().asString(), iterB.key().asString()));
        assert(iterA.value() == iterB.value(), format("迭代器value不一致: key=%s", iterA.key().asString()));
        iterA.next();
        iterB.next();
        countA++;
    }

    assert(!iterA.valid() && !iterB.valid(), "两个迭代器应同时结束");
    assert(countA == n, format("迭代器遍历数量不一致: got=%d exp=%d", countA, n));

    // 先显式释放迭代器引用，再关闭数据库
    auto refIterA = cast(DbIteratorWithRefs) iterA;
    auto refIterB = cast(DbIteratorWithRefs) iterB;
    if (refIterA !is null) refIterA.release();
    if (refIterB !is null) refIterB.release();

    dbA.close();
    dbB.close();
    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();
}

/**
 * 双库交叉验证：先写A后读B，再写B后读A（交叉读写）
 */
void testDualDbCrossReadWrite()
{
    import std.stdio : writeln;
    writeln("  [双库测试] 交叉读写验证...");

    string pathA = makeTempPath("dual_crw_a");
    string pathB = makeTempPath("dual_crw_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    auto opt = Options();
    opt.createIfMissing = true;
    opt.compression = CompressionType.none;

    auto dbA = new LevelDB(opt, pathA);
    auto dbB = new LevelDB(opt, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    // 向A写入，从B验证不存在，然后向B写入同样数据
    for (int i = 0; i < 30; i++)
    {
        string key = format("cross_key_%04d", i);
        string value = format("cross_val_%04d", i);

        dbA.put(key, value);

        string valB;
        assert(!dbB.get(key, valB), format("库B不应有key=%s", key));

        dbB.put(key, value);

        // 写入B后两个库应都能读到
        string valA2, valB2;
        assert(dbA.get(key, valA2));
        assert(dbB.get(key, valB2));
        assert(valA2 == valB2);
    }
}

/**
 * 运行全部双库交叉验证测试
 */
void runDualDbTests()
{
    import std.stdio : writeln;
    writeln("====== 双库交叉验证测试 (dleveldb x 2 实例) ======");

    import core.exception : AssertError;

    auto runTest(string name, void function() test) {
        try {
            writeln("  开始: " ~ name);
            test();
            writeln("  通过: " ~ name);
        } catch (AssertError e) {
            writeln("  失败: " ~ name ~ " -> " ~ e.msg);
        } catch (Throwable e) {
            writeln("  异常: " ~ name ~ " -> " ~ e.msg);
        }
    }

    runTest("testDualDbPutGet", &testDualDbPutGet);
    runTest("testDualDbDelete", &testDualDbDelete);
    runTest("testDualDbOverwrite", &testDualDbOverwrite);
    runTest("testDualDbBatchWrite", &testDualDbBatchWrite);
    runTest("testDualDbNotFound", &testDualDbNotFound);
    runTest("testDualDbIterator", &testDualDbIterator);
    runTest("testDualDbCrossReadWrite", &testDualDbCrossReadWrite);

    writeln("====== 双库交叉验证测试全部完成 ======");
}
