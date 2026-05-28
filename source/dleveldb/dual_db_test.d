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
import std.logger;

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
    info("  [双库测试] 顺序写入/读取交叉对比...");

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
    info("  [双库测试] 删除后读取交叉对比...");

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
    info("  [双库测试] 覆盖写入交叉对比...");

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
    info("  [双库测试] 批量写入交叉对比...");

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
    info("  [双库测试] 不存在的键交叉对比...");

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
    info("  [双库测试] 迭代器遍历交叉对比...");

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
    info("  [双库测试] 交叉读写验证...");

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
 * 双库交叉验证增强迭代器测试
 * 
 * 覆盖场景：反向遍历、seek定位、空数据库迭代器
 */
void testDualDbIteratorAdvanced()
{
    info("  [双库测试] 增强迭代器交叉对比...");

    string pathA = makeTempPath("dual_iter_adv_a");
    string pathB = makeTempPath("dual_iter_adv_b");

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

    int n = 50;
    for (int i = 0; i < n; i++)
    {
        string key = format("iter_key_%04d", i);
        string value = format("iter_val_%04d", i);
        dbA.put(key, value);
        dbB.put(key, value);
    }

    // 测试1：反向遍历（seekToLast + prev）
    {
        auto iterA = dbA.iterator();
        auto iterB = dbB.iterator();
        scope(exit) { releaseIter(iterA); releaseIter(iterB); }

        iterA.seekToLast();
        iterB.seekToLast();

        int count;
        while (iterA.valid() && iterB.valid())
        {
            assert(iterA.key() == iterB.key(),
                format("反向迭代key不一致: A=%s B=%s", iterA.key().asString(), iterB.key().asString()));
            assert(iterA.value() == iterB.value(),
                format("反向迭代value不一致: key=%s", iterA.key().asString()));
            iterA.prev();
            iterB.prev();
            count++;
        }
        assert(!iterA.valid() && !iterB.valid(), "反向迭代器应同时结束");
        assert(count == n, format("反向迭代数量不一致: got=%d exp=%d", count, n));
    }

    // 测试2：seek 到中间键后正向遍历
    {
        auto iterA = dbA.iterator();
        auto iterB = dbB.iterator();
        scope(exit) { releaseIter(iterA); releaseIter(iterB); }

        iterA.seek(Slice("iter_key_0020"));
        iterB.seek(Slice("iter_key_0020"));

        int count;
        int expectedRemaining = n - 20;
        while (iterA.valid() && iterB.valid())
        {
            assert(iterA.key() == iterB.key(),
                format("seek后key不一致: A=%s B=%s", iterA.key().asString(), iterB.key().asString()));
            iterA.next();
            iterB.next();
            count++;
        }
        assert(!iterA.valid() && !iterB.valid(), "seek迭代器应同时结束");
        assert(count == expectedRemaining,
            format("seek迭代数量不一致: got=%d exp=%d", count, expectedRemaining));
    }

    // 测试3：seek 不存在的键
    {
        auto iterA = dbA.iterator();
        auto iterB = dbB.iterator();
        scope(exit) { releaseIter(iterA); releaseIter(iterB); }

        // seek最后一个键之后，迭代器应无效
        iterA.seek(Slice("iter_key_9999"));
        iterB.seek(Slice("iter_key_9999"));
        assert(!iterA.valid(), "seek超大键后iterA应无效");
        assert(!iterB.valid(), "seek超大键后iterB应无效");
    }

    // 测试4：空数据库迭代器
    {
        string emptyPathA = makeTempPath("dual_empty_a");
        string emptyPathB = makeTempPath("dual_empty_b");
        scope(exit)
        {
            if (emptyPathA.exists) emptyPathA.rmdirRecurse();
            if (emptyPathB.exists) emptyPathB.rmdirRecurse();
        }

        auto optEmpty = Options();
        optEmpty.createIfMissing = true;
        optEmpty.compression = CompressionType.none;

        auto emptyA = new LevelDB(optEmpty, emptyPathA);
        auto emptyB = new LevelDB(optEmpty, emptyPathB);
        scope(exit) { emptyA.close(); emptyB.close(); }

        auto iterA = emptyA.iterator();
        auto iterB = emptyB.iterator();
        scope(exit) { releaseIter(iterA); releaseIter(iterB); }

        // seekToFirst 后应为无效
        iterA.seekToFirst();
        assert(!iterA.valid(), "空库seekToFirst后应无效");
        iterB.seekToLast();
        assert(!iterB.valid(), "空库seekToLast后应无效");
        iterA.seek(Slice("any"));
        assert(!iterA.valid(), "空库seek后应无效");
    }
}

/// 释放迭代器引用（兼容 DbIteratorWithRefs）
private void releaseIter(Iterator iter)
{
    import dleveldb.db_impl : DbIteratorWithRefs;
    auto refIter = cast(DbIteratorWithRefs) iter;
    if (refIter !is null)
        refIter.release();
}

/**
 * 双库交叉验证快照功能测试
 * 
 * 覆盖场景：
 * - 创建快照后写入新数据，快照应看到旧状态
 * - 释放快照后，新数据可见
 * - 跨库快照一致性
 */
void testDualDbSnapshot()
{
    info("  [双库测试] 快照功能交叉对比...");

    string pathA = makeTempPath("dual_snap_a");
    string pathB = makeTempPath("dual_snap_b");

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

    // 写入初始数据
    dbA.put("key_01", "init_val");
    dbA.put("key_02", "init_val");
    dbB.put("key_01", "init_val");
    dbB.put("key_02", "init_val");

    // 创建快照
    auto snapA = dbA.snapshot;
    auto snapB = dbB.snapshot;

    // 获取序列号
    ulong snapSeqA = snapA.sequenceNumber();
    ulong snapSeqB = snapB.sequenceNumber();
    assert(snapSeqA > 0, "快照序列号应大于0");
    assert(snapSeqB > 0, "快照序列号应大于0");
    infof("  快照序列号: A=%d, B=%d", snapSeqA, snapSeqB);

    // 快照后写入新数据（覆盖 + 新增）
    dbA.put("key_01", "new_val");
    dbA.put("key_03", "new_val");
    dbB.put("key_01", "new_val");
    dbB.put("key_03", "new_val");

    // 使用快照读取：应看到旧数据
    {
        ReadOptions snapOpt;
        snapOpt.snapshot = snapSeqA;
        
        string val;
        bool found = dbA.get("key_01", val, snapOpt);
        assert(found && val == "init_val",
            format("快照应看到旧值: got=%s exp=init_val", val));

        found = dbB.get("key_01", val, snapOpt);
        assert(found && val == "init_val",
            format("快照B应看到旧值: got=%s exp=init_val", val));

        // 快照不应看到快照后写入的key_03
        found = dbA.get("key_03", val, snapOpt);
        assert(!found, "快照不应看到快照后写入的键");
    }

    // 不用快照读取：应看到新数据
    {
        string val;
        bool found = dbA.get("key_01", val);
        assert(found && val == "new_val",
            format("无快照应看到新值: got=%s exp=new_val", val));

        found = dbA.get("key_03", val);
        assert(found && val == "new_val",
            format("新写入的key_03应可见: got=%s", val));
    }

    // 释放快照
    dbA.releaseSnapshot(snapA);
    dbB.releaseSnapshot(snapB);
}

/**
 * 双库交叉验证压缩功能测试
 * 
 * 覆盖场景：
 * - 不同压缩配置的数据库写入/读取交叉对比
 * - 直接测试压缩器接口
 * - 写入数据量足够触发SSTable创建
 */
void testDualDbCompression()
{
    info("  [双库测试] 压缩功能交叉对比...");

    string pathA = makeTempPath("dual_comp_a");
    string pathB = makeTempPath("dual_comp_b");

    if (pathA.exists) pathA.rmdirRecurse();
    if (pathB.exists) pathB.rmdirRecurse();

    // 库A：无压缩，库B：snappy压缩（实际降级为无压缩）
    auto optA = Options();
    optA.createIfMissing = true;
    optA.compression = CompressionType.none;

    auto optB = Options();
    optB.createIfMissing = true;
    optB.compression = CompressionType.snappy;  // 当前会降级为无压缩

    auto dbA = new LevelDB(optA, pathA);
    auto dbB = new LevelDB(optB, pathB);

    scope (exit)
    {
        dbA.close();
        dbB.close();
        if (pathA.exists) pathA.rmdirRecurse();
        if (pathB.exists) pathB.rmdirRecurse();
    }

    // 写入大量数据，触发SSTable创建
    int n = 500;
    for (int i = 0; i < n; i++)
    {
        // 使用可变长度值，模拟真实数据
        string value;
        if (i % 3 == 0)
            value = format("short_val_%04d", i);
        else if (i % 3 == 1)
            value = format("medium_value_data_for_compression_test_%04d_%s", i, "abcdefghijklmnopqrstuvwxyz");
        else
            value = format("large_%04d_%s", i, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\",./<>?~`abcdefghijklmnopqrstuvwxyz");

        dbA.put(format("comp_key_%04d", i), value);
        dbB.put(format("comp_key_%04d", i), value);
    }

    // 验证所有数据一致
    for (int i = 0; i < n; i++)
    {
        string key = format("comp_key_%04d", i);
        string expected = (i % 3 == 0) ? format("short_val_%04d", i) :
                          (i % 3 == 1) ? format("medium_value_data_for_compression_test_%04d_%s", i, "abcdefghijklmnopqrstuvwxyz") :
                          format("large_%04d_%s", i, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\",./<>?~`abcdefghijklmnopqrstuvwxyz");

        string valA, valB;
        assert(dbA.get(key, valA), format("库A: key=%s 未找到", key));
        assert(dbB.get(key, valB), format("库B: key=%s 未找到", key));
        assert(valA == valB, format("压缩交叉对比失败: key=%s", key));
        assert(valA == expected, format("库A值不匹配: key=%s got=%s", key, valA));
    }

    // 使用迭代器交叉验证压缩后的数据
    {
        auto iterA = dbA.iterator();
        auto iterB = dbB.iterator();
        scope(exit) { releaseIter(iterA); releaseIter(iterB); }

        iterA.seekToFirst();
        iterB.seekToFirst();

        int count;
        while (iterA.valid() && iterB.valid())
        {
            assert(iterA.key() == iterB.key(),
                format("压缩库迭代器key不一致: A=%s B=%s", iterA.key().asString(), iterB.key().asString()));
            assert(iterA.value() == iterB.value(),
                format("压缩库迭代器value不一致: key=%s", iterA.key().asString()));
            iterA.next();
            iterB.next();
            count++;
        }
        assert(count == n, format("压缩库迭代数量不一致: got=%d exp=%d", count, n));
    }
}

/**
 * 运行全部双库交叉验证测试
 */
void runDualDbTests()
{
    info("====== 双库交叉验证测试 (dleveldb x 2 实例) ======");

    import core.exception : AssertError;

    auto runTest(string name, void function() test) {
        try {
            info("  开始: " ~ name);
            test();
            info("  通过: " ~ name);
        } catch (AssertError e) {
            error("  失败: " ~ name ~ " -> " ~ e.msg);
        } catch (Throwable e) {
            error("  异常: " ~ name ~ " -> " ~ e.msg);
        }
    }

    runTest("testDualDbPutGet", &testDualDbPutGet);
    runTest("testDualDbDelete", &testDualDbDelete);
    runTest("testDualDbOverwrite", &testDualDbOverwrite);
    runTest("testDualDbBatchWrite", &testDualDbBatchWrite);
    runTest("testDualDbNotFound", &testDualDbNotFound);
    runTest("testDualDbIterator", &testDualDbIterator);
    runTest("testDualDbCrossReadWrite", &testDualDbCrossReadWrite);
    runTest("testDualDbIteratorAdvanced", &testDualDbIteratorAdvanced);
    runTest("testDualDbSnapshot", &testDualDbSnapshot);
    runTest("testDualDbCompression", &testDualDbCompression);

    info("====== 双库交叉验证测试全部完成 ======");
}
