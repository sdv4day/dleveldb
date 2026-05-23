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
    this(Iterator indexIter, Iterator delegate(Slice) blockFunc)
    {
        indexIter_ = indexIter;
        blockFunc_ = blockFunc;
        dataIter_ = null;
    }

    ~this()
    {
        if (dataIter_ !is null)
        {
            // 数据块迭代器由blockFunc管理
        }
    }

    bool valid() const nothrow @nogc
    {
        return dataIter_ !is null && dataIter_.valid();
    }

    void seekToFirst()
    {
        indexIter_.seekToFirst();
        initDataBlock();
        if (dataIter_ !is null)
            dataIter_.seekToFirst();
        skipEmptyDataBlocksForward();
    }

    void seekToLast()
    {
        indexIter_.seekToLast();
        initDataBlock();
        if (dataIter_ !is null)
            dataIter_.seekToLast();
        skipEmptyDataBlocksBackward();
    }

    void seek(Slice target)
    {
        indexIter_.seek(target);
        initDataBlock();
        if (dataIter_ !is null)
            dataIter_.seek(target);
        skipEmptyDataBlocksForward();
    }

    void next()
    {
        assert(valid());
        dataIter_.next();
        skipEmptyDataBlocksForward();
    }

    void prev()
    {
        assert(valid());
        dataIter_.prev();
        skipEmptyDataBlocksBackward();
    }

    Slice key() nothrow @nogc
    {
        assert(valid());
        return dataIter_.key();
    }

    Slice value() nothrow @nogc
    {
        assert(valid());
        return dataIter_.value();
    }

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
    this(Slice[] keys, Slice[] values)
    {
        keys_ = keys;
        values_ = values;
        pos_ = -1;
    }

    bool valid() const nothrow @nogc { return pos_ >= 0 && pos_ < cast(int) keys_.length; }

    void seekToFirst() nothrow @nogc { pos_ = 0; }
    void seekToLast() nothrow @nogc { pos_ = cast(int) keys_.length - 1; }

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

    void next() nothrow @nogc { pos_++; }
    void prev() nothrow @nogc { pos_--; }

    Slice key() nothrow @nogc
    {
        assert(valid());
        return keys_[pos_];
    }

    Slice value() nothrow @nogc
    {
        assert(valid());
        return values_[pos_];
    }

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
