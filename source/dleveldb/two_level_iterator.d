module dleveldb.two_level_iterator;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.iterator;

/**
 * 两级迭代器
 * 第一级：索引迭代器（指向数据块）
 * 第二级：数据块迭代器（块内数据）
 * 
 * 用于SSTable的读取：index block -> data block
 */
class TwoLevelIterator : Iterator
{
private:
    Iterator indexIter_;           // 索引迭代器
    Iterator delegate(Slice) blockFunc_;  // 从索引值创建数据块迭代器的函数
    Iterator dataIter_;            // 当前数据块迭代器
    Status status_;
    string key_;                   // 缓存的key

public:
    /// 构造两级迭代器
    /// Params: indexIter = 索引迭代器，用于遍历数据块索引
    ///         blockFunc = 根据索引值创建对应数据块迭代器的函数
    this(Iterator indexIter, Iterator delegate(Slice) blockFunc)
    {
        indexIter_ = indexIter;
        blockFunc_ = blockFunc;
        dataIter_ = null;
    }

    /// 析构函数，数据块迭代器由blockFunc管理生命周期
    ~this()
    {
        if (dataIter_ !is null)
        {
            // 数据块迭代器由blockFunc管理
        }
    }

    /// 检查迭代器是否指向有效位置
    /// Returns: 若当前数据块迭代器存在且有效则返回true，否则返回false
    bool valid() const nothrow @nogc
    {
        return dataIter_ !is null && dataIter_.valid();
    }

    /// 定位到第一个键值对
    void seekToFirst()
    {
        indexIter_.seekToFirst();
        initDataBlock();
        if (dataIter_ !is null)
        {
            dataIter_.seekToFirst();
        }
        skipEmptyDataBlocksForward();
    }

    /// 定位到最后一个键值对
    void seekToLast()
    {
        indexIter_.seekToLast();
        initDataBlock();
        if (dataIter_ !is null)
            dataIter_.seekToLast();
        skipEmptyDataBlocksBackward();
    }

    /// 定位到大于等于target的第一个键值对
    /// Params: target = 查找目标键
    void seek(Slice target)
    {
        indexIter_.seek(target);
        initDataBlock();
        if (dataIter_ !is null)
            dataIter_.seek(target);
        skipEmptyDataBlocksForward();
    }

    /// 移动到下一个键值对，调用前必须保证valid()为true
    void next()
    {
        assert(valid());
        dataIter_.next();
        skipEmptyDataBlocksForward();
    }

    /// 移动到上一个键值对，调用前必须保证valid()为true
    void prev()
    {
        assert(valid());
        dataIter_.prev();
        skipEmptyDataBlocksBackward();
    }

    /// 获取当前键
    /// Returns: 当前位置的键，调用前必须保证valid()为true
    Slice key() nothrow @nogc
    {
        assert(valid());
        return dataIter_.key();
    }

    /// 获取当前值
    /// Returns: 当前位置的值，调用前必须保证valid()为true
    Slice value() nothrow @nogc
    {
        assert(valid());
        return dataIter_.value();
    }

    /// 获取迭代器的状态
    /// Returns: 若索引迭代器或数据块迭代器存在错误则返回错误状态，否则返回OK状态
    Status status() const nothrow @nogc
    {
        if (!indexIter_.status().ok())
            return indexIter_.status();
        if (dataIter_ !is null && !dataIter_.status().ok())
            return dataIter_.status();
        return Status();
    }

private:
    /// 初始化数据块迭代器
    void initDataBlock()
    {
        if (dataIter_ !is null)
        {
            dataIter_ = null;
        }

        if (indexIter_.valid())
        {
            Slice handle = indexIter_.value();
            dataIter_ = blockFunc_(handle);
        }
    }

    /// 跳过空数据块（向前）
    void skipEmptyDataBlocksForward()
    {
        while (dataIter_ is null || !dataIter_.valid())
        {
            // 前进到下一个索引条目
            if (!indexIter_.valid())
            {
                dataIter_ = null;
                return;
            }
            indexIter_.next();
            initDataBlock();
            if (dataIter_ !is null)
                dataIter_.seekToFirst();
        }
    }

    /// 跳过空数据块（向后）
    void skipEmptyDataBlocksBackward()
    {
        while (dataIter_ is null || !dataIter_.valid())
        {
            if (!indexIter_.valid())
            {
                dataIter_ = null;
                return;
            }
            indexIter_.prev();
            initDataBlock();
            if (dataIter_ !is null)
                dataIter_.seekToLast();
        }
    }
}

/// 创建两级迭代器
Iterator newTwoLevelIterator(Iterator indexIter, Iterator delegate(Slice) blockFunc)
{
    return new TwoLevelIterator(indexIter, blockFunc);
}

/// 简单向量迭代器，用于测试
class VectorIter : Iterator
{
private:
    Slice[] keys_;
    Slice[] values_;
    int pos_;
    Status status_;

public:
    /// 构造向量迭代器
    /// Params: keys   = 键数组
    ///         values = 值数组，与keys一一对应
    this(Slice[] keys, Slice[] values)
    {
        keys_ = keys;
        values_ = values;
        pos_ = -1;
    }

    /// 检查迭代器是否指向有效位置
    /// Returns: 若当前位置在有效范围内则返回true，否则返回false
    bool valid() const nothrow @nogc { return pos_ >= 0 && pos_ < cast(int) keys_.length; }

    /// 定位到第一个键值对
    void seekToFirst() nothrow @nogc { pos_ = 0; }

    /// 定位到最后一个键值对
    void seekToLast() nothrow @nogc { pos_ = cast(int) keys_.length - 1; }

    /// 定位到大于等于target的第一个键值对
    /// Params: target = 查找目标键
    void seek(Slice target)
    {
        // 线性搜索找到 >= target 的第一个键
        for (size_t i = 0; i < keys_.length; i++)
        {
            if (keys_[i].opCmp(target) >= 0)
            {
                pos_ = cast(int) i;
                return;
            }
        }
        pos_ = cast(int) keys_.length;
    }

    /// 移动到下一个键值对
    void next() nothrow @nogc { pos_++; }

    /// 移动到上一个键值对
    void prev() nothrow @nogc { pos_--; }

    /// 获取当前键
    /// Returns: 当前位置的键，调用前必须保证valid()为true
    Slice key() nothrow @nogc
    {
        assert(valid());
        return keys_[pos_];
    }

    /// 获取当前值
    /// Returns: 当前位置的值，调用前必须保证valid()为true
    Slice value() nothrow @nogc
    {
        assert(valid());
        return values_[pos_];
    }

    /// 获取迭代器的状态
    /// Returns: 当前迭代器的状态
    Status status() const nothrow @nogc { return status_; }
}

///
unittest
{
    import dleveldb.block_builder;
    import dleveldb.block;
    import dleveldb.comparator;

    // ====== TwoLevelIterator.seek() 测试 ======
    // 模拟 SSTable 结构：索引块 -> 数据块

    // 构建两个数据块
    auto bb1 = BlockBuilder(16);
    bb1.add(Slice("a"), Slice("va"));
    bb1.add(Slice("b"), Slice("vb"));
    auto blockData1 = bb1.finish();
    ubyte[] blockBuf1 = blockData1.data()[0 .. blockData1.size()].dup;

    auto bb2 = BlockBuilder(16);
    bb2.add(Slice("c"), Slice("vc"));
    bb2.add(Slice("d"), Slice("vd"));
    auto blockData2 = bb2.finish();
    ubyte[] blockBuf2 = blockData2.data()[0 .. blockData2.size()].dup;

    // 构建索引块：索引键是数据块的最后一个键，值是块句柄（这里用简单标识）
    // 索引键 "b" -> 块1, 索引键 "d" -> 块2
    auto bbIdx = BlockBuilder(16);
    // 用 "b" 和 "d" 作为索引分隔键，值为块编号
    ubyte[1] handle1 = [0];
    ubyte[1] handle2 = [1];
    bbIdx.add(Slice("b"), Slice(handle1.ptr, 1));
    bbIdx.add(Slice("d"), Slice(handle2.ptr, 1));
    auto idxData = bbIdx.finish();
    ubyte[] idxBuf = idxData.data()[0 .. idxData.size()].dup;

    auto idxBlock = new Block(Slice(idxBuf.ptr, idxBuf.length));
    Iterator idxIter = idxBlock.iterator(defaultComparator());

    // 块数据数组
    Slice[] blockSlices = [
        Slice(blockBuf1.ptr, blockBuf1.length),
        Slice(blockBuf2.ptr, blockBuf2.length),
    ];

    // blockFunc: 根据索引值创建数据块迭代器
    Iterator delegate(Slice) blockFunc = (Slice handle) {
        uint blockIdx = handle.data()[0];
        auto blk = new Block(blockSlices[blockIdx]);
        return blk.iterator(defaultComparator());
    };

    auto twoLevelIter = new TwoLevelIterator(idxIter, blockFunc);

    // --- 测试1: seek到第一个块 ---
    twoLevelIter.seek(Slice("a"));
    assert(twoLevelIter.valid());
    assert(twoLevelIter.key() == Slice("a"));
    assert(twoLevelIter.value() == Slice("va"));

    twoLevelIter.seek(Slice("b"));
    assert(twoLevelIter.valid());
    assert(twoLevelIter.key() == Slice("b"));

    // --- 测试2: seek到第二个块 ---
    twoLevelIter.seek(Slice("c"));
    assert(twoLevelIter.valid());
    assert(twoLevelIter.key() == Slice("c"));
    assert(twoLevelIter.value() == Slice("vc"));

    twoLevelIter.seek(Slice("d"));
    assert(twoLevelIter.valid());
    assert(twoLevelIter.key() == Slice("d"));

    // --- 测试3: seek到不存在的键 ---
    twoLevelIter.seek(Slice("b0"));
    assert(twoLevelIter.valid());
    assert(twoLevelIter.key() == Slice("c"));  // "b0" 在 b 和 c 之间

    // --- 测试4: seek超出范围 ---
    twoLevelIter.seek(Slice("z"));
    assert(!twoLevelIter.valid());

    // --- 测试5: seekToFirst + next 全遍历 ---
    twoLevelIter.seekToFirst();
    assert(twoLevelIter.key() == Slice("a"));
    twoLevelIter.next();
    assert(twoLevelIter.key() == Slice("b"));
    twoLevelIter.next();
    assert(twoLevelIter.key() == Slice("c"));
    twoLevelIter.next();
    assert(twoLevelIter.key() == Slice("d"));
    twoLevelIter.next();
    assert(!twoLevelIter.valid());
}

///
unittest
{
    import dleveldb.block_builder;
    import dleveldb.block;
    import dleveldb.comparator;

    // ====== TwoLevelIterator.seek() 边界情况测试 ======

    // --- 测试1: seek后反向遍历 ---
    // 注意：TwoLevelIterator的反向遍历依赖于BlockIter的反向遍历
    // 这里先跳过，专注于seek功能测试

    // --- 测试2: 方向切换测试 ---
    // 注意：方向切换测试暂时跳过

    // --- 测试3: 重复seek测试 ---
    auto bb3a = BlockBuilder(16);
    bb3a.add(Slice("a"), Slice("va"));
    bb3a.add(Slice("b"), Slice("vb"));
    auto blockData3a = bb3a.finish();
    ubyte[] blockBuf3a = blockData3a.data()[0 .. blockData3a.size()].dup;

    auto bb3b = BlockBuilder(16);
    bb3b.add(Slice("c"), Slice("vc"));
    bb3b.add(Slice("d"), Slice("vd"));
    auto blockData3b = bb3b.finish();
    ubyte[] blockBuf3b = blockData3b.data()[0 .. blockData3b.size()].dup;

    auto bbIdx3 = BlockBuilder(16);
    ubyte[1] handle3a = [0];
    ubyte[1] handle3b = [1];
    bbIdx3.add(Slice("b"), Slice(handle3a.ptr, 1));
    bbIdx3.add(Slice("d"), Slice(handle3b.ptr, 1));
    auto idxData3 = bbIdx3.finish();
    ubyte[] idxBuf3 = idxData3.data()[0 .. idxData3.size()].dup;

    auto idxBlock3 = new Block(Slice(idxBuf3.ptr, idxBuf3.length));
    Iterator idxIter3 = idxBlock3.iterator(defaultComparator());

    Slice[] blockSlices3 = [
        Slice(blockBuf3a.ptr, blockBuf3a.length),
        Slice(blockBuf3b.ptr, blockBuf3b.length),
    ];

    Iterator delegate(Slice) blockFunc3 = (Slice handle) {
        uint blockIdx = handle.data()[0];
        auto blk = new Block(blockSlices3[blockIdx]);
        return blk.iterator(defaultComparator());
    };

    auto iter3 = new TwoLevelIterator(idxIter3, blockFunc3);

    // 多次seek不同位置
    iter3.seek(Slice("b"));
    assert(iter3.key() == Slice("b"));

    iter3.seek(Slice("a"));
    assert(iter3.key() == Slice("a"));

    iter3.seek(Slice("c"));
    assert(iter3.key() == Slice("c"));

    iter3.seek(Slice("z"));
    assert(!iter3.valid());

    // 重新seek到有效位置
    iter3.seek(Slice("b"));
    assert(iter3.valid());
    assert(iter3.key() == Slice("b"));

    // --- 测试4: seekToLast与反向遍历 ---
    // 注意：反向遍历测试暂时跳过

    // --- 测试5: 单块测试 ---
    auto bb5 = BlockBuilder(16);
    bb5.add(Slice("a"), Slice("va"));
    bb5.add(Slice("b"), Slice("vb"));
    auto blockData5 = bb5.finish();
    ubyte[] blockBuf5 = blockData5.data()[0 .. blockData5.size()].dup;

    auto bbIdx5 = BlockBuilder(16);
    ubyte[1] handle5 = [0];
    bbIdx5.add(Slice("b"), Slice(handle5.ptr, 1));
    auto idxData5 = bbIdx5.finish();
    ubyte[] idxBuf5 = idxData5.data()[0 .. idxData5.size()].dup;

    auto idxBlock5 = new Block(Slice(idxBuf5.ptr, idxBuf5.length));
    Iterator idxIter5 = idxBlock5.iterator(defaultComparator());

    Slice[] blockSlices5 = [
        Slice(blockBuf5.ptr, blockBuf5.length),
    ];

    Iterator delegate(Slice) blockFunc5 = (Slice handle) {
        uint blockIdx = handle.data()[0];
        auto blk = new Block(blockSlices5[blockIdx]);
        return blk.iterator(defaultComparator());
    };

    auto iter5 = new TwoLevelIterator(idxIter5, blockFunc5);

    iter5.seek(Slice("a"));
    assert(iter5.key() == Slice("a"));

    iter5.seek(Slice("b"));
    assert(iter5.key() == Slice("b"));

    iter5.seek(Slice("c"));
    assert(!iter5.valid());
}
