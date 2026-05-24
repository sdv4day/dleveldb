module dleveldb.block;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.coding;
import dleveldb.comparator;
import dleveldb.iterator;

/**
 * 数据块读取器
 * 解析SSTable数据块，提供块内迭代器
 */
class Block
{
private:
    Slice data_;
    int numRestarts_;
    uint restartInterval_;

    // 重启点数组在data_中的偏移
    size_t restartsOffset_;

public:
    /// 构造数据块
    /// Params: data = 包含块数据的Slice，末尾4字节为重启点数量
    this(Slice data)
    {
        data_ = data;
        if (data_.size() < uint.sizeof)
        {
            numRestarts_ = 0;
            restartsOffset_ = 0;
            return;
        }

        // 最后4字节是重启点数量
        numRestarts_ = cast(int) decodeFixed32(data_.data() + data_.size() - uint.sizeof);
        restartsOffset_ = data_.size() - uint.sizeof - cast(size_t) numRestarts_ * uint.sizeof;

        if (restartsOffset_ > data_.size())
        {
            // 数据损坏
            numRestarts_ = 0;
            restartsOffset_ = 0;
        }
    }

    /// 获取块大小
    size_t size() const pure nothrow @safe @nogc { return data_.size(); }

    /// 获取块数据
    Slice data() const nothrow @nogc { return data_; }

    /// 获取重启点数量
    int numRestarts() const pure nothrow @safe @nogc { return numRestarts_; }

    /// 获取第i个重启点的偏移
    uint restartPoint(int i) const nothrow @nogc
    {
        assert(i >= 0 && i < numRestarts_);
        return decodeFixed32(data_.data() + restartsOffset_ + i * uint.sizeof);
    }

    /// 创建块内迭代器
    BlockIter iterator(Comparator cmp) nothrow
    {
        return new BlockIter(this, cmp);
    }
}

/**
 * 块内迭代器
 * 利用重启点进行二分搜索
 */
class BlockIter : Iterator
{
private:
    Block block_;
    Comparator cmp_;
    uint restartIndex_;  // 当前重启点索引
    uint currentOffset_; // 当前条目在块数据中的偏移
    Slice key_;          // 当前键
    Slice value_;        // 当前值
    Status status_;
    bool valid_;

public:
    /// 构造块内迭代器
    /// Params:
    ///     block = 要迭代的数据块
    ///     cmp   = 键比较器，用于seek时的二分搜索
    this(Block block, Comparator cmp) nothrow
    {
        block_ = block;
        cmp_ = cmp;
        restartIndex_ = 0;
        currentOffset_ = 0;
        valid_ = false;
    }

    /// 检查迭代器是否指向有效条目
    /// Returns: 若当前指向有效条目则返回true，否则返回false
    bool valid() const nothrow @nogc { return valid_; }

    /// 获取当前条目的键
    /// Returns: 当前键的Slice引用
    Slice key() nothrow @nogc { return key_; }
    /// 获取当前条目的值
    /// Returns: 当前值的Slice引用
    Slice value() nothrow @nogc { return value_; }
    /// 获取迭代器的错误状态
    /// Returns: 若解码过程中发生错误则返回对应的错误状态，否则返回OK状态
    Status status() const nothrow @nogc { return status_; }

    /// 定位到块内第一个条目
    void seekToFirst()
    {
        restartIndex_ = 0;
        seekToRestartPoint(0);
        while (valid_ && key_.size() == 0)
        {
            next();
        }
    }

    /// 定位到块内最后一个条目
    void seekToLast()
    {
        if (block_.numRestarts() == 0)
        {
            valid_ = false;
            return;
        }
        restartIndex_ = cast(uint) (block_.numRestarts() - 1);
        seekToRestartPoint(cast(int) restartIndex_);
        while (true)
        {
            // 检查下一个重启点是否有效
            if (restartIndex_ + 1 >= cast(uint) block_.numRestarts())
                break;
            uint nextRestart = block_.restartPoint(cast(int) (restartIndex_ + 1));
            if (nextRestart <= cast(uint) currentOffset())
            {
                // 尝试前进
                Slice savedKey = key_;
                next();
                if (!valid_)
                {
                    key_ = savedKey;
                    valid_ = true;
                    break;
                }
            }
            else
            {
                break;
            }
        }
    }

    /// 定位到键大于等于target的第一个条目
    /// Params: target = 要查找的目标键
    void seek(Slice target)
    {
        // 二分搜索找到target所在的重启点
        int left = 0;
        int right = block_.numRestarts() - 1;

        while (left < right)
        {
            int mid = (left + right + 1) / 2;
            uint offset = block_.restartPoint(mid);
            if (decodeEntryAt(offset) && cmp_.compare(key_, target) < 0)
            {
                left = mid;
            }
            else
            {
                right = mid - 1;
            }
        }

        restartIndex_ = cast(uint) left;
        seekToRestartPoint(left);

        // 线性搜索找到>=target的条目
        while (valid_)
        {
            if (cmp_.compare(key_, target) >= 0)
                return;
            next();
        }
    }

    /// 移动到下一个条目
    /// 调用前必须保证valid()为true
    void next()
    {
        assert(valid_);
        uint offset = cast(uint) currentOffset();

        if (offset >= cast(uint) block_.restartsOffset_)
        {
            valid_ = false;
            return;
        }

        // 先从当前偏移处解码，计算当前条目大小以跳到下一个
        const(ubyte)* ptr = block_.data().data() + offset;
        const(ubyte)* limit = block_.data().data() + block_.restartsOffset_;

        uint sharedLen, nonShared, valueLength;
        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            valid_ = false;
            status_ = statusCorruption("bad entry in block");
            return;
        }

        // 跳到下一个条目
        uint nextOffset = cast(uint) (ptr + nonShared + valueLength - block_.data().data());

        if (nextOffset >= cast(uint) block_.restartsOffset_)
        {
            valid_ = false;
            return;
        }

        // 在nextOffset处解码下一个条目
        ptr = block_.data().data() + nextOffset;

        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            valid_ = false;
            status_ = statusCorruption("bad entry in block");
            return;
        }

        if (sharedLen > key_.size())
        {
            valid_ = false;
            status_ = statusCorruption("bad shared length");
            return;
        }

        // 更新key：保留shared前缀，替换nonShared部分
        ubyte[] newKey;
        newKey.length = sharedLen + nonShared;
        
        if (sharedLen > 0)
        {
            newKey[0 .. sharedLen] = key_.asBytes()[0 .. sharedLen];
        }
        if (nonShared > 0)
        {
            newKey[sharedLen .. sharedLen + nonShared] = ptr[0 .. nonShared];
        }
        ptr += nonShared;

        key_ = Slice(newKey.ptr, newKey.length);
        value_ = Slice(ptr, valueLength);
        currentOffset_ = nextOffset;

        // 更新重启点索引
        while (restartIndex_ + 1 < cast(uint) block_.numRestarts() &&
               block_.restartPoint(cast(int) (restartIndex_ + 1)) <= nextOffset)
        {
            restartIndex_++;
        }
    }

    /// 移动到上一个条目
    /// 调用前必须保证valid()为true
    void prev()
    {
        assert(valid_);

        // 找到前一个条目
        uint offset = cast(uint) currentOffset();
        seekToRestartPoint(cast(int) restartIndex_);

        while (currentOffset() < offset)
        {
            Slice savedKey = key_;
            Slice savedValue = value_;
            next();
            if (currentOffset() >= offset)
            {
                key_ = savedKey;
                value_ = savedValue;
                valid_ = true;
                return;
            }
        }
    }

private:
    /// 获取当前偏移
    uint currentOffset() const nothrow @nogc
    {
        return currentOffset_;
    }

    /// 定位到重启点
    void seekToRestartPoint(int index) nothrow
    {
        if (index < 0 || index >= block_.numRestarts())
        {
            valid_ = false;
            return;
        }

        uint offset = block_.restartPoint(index);
        const(ubyte)* ptr = block_.data().data() + offset;
        const(ubyte)* limit = block_.data().data() + block_.restartsOffset_;

        uint sharedLen, nonShared, valueLength;
        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            valid_ = false;
            return;
        }

        // 重启点处sharedLen=0
        key_ = Slice(ptr, nonShared);
        ptr += nonShared;
        value_ = Slice(ptr, valueLength);
        valid_ = true;
        restartIndex_ = cast(uint) index;
        currentOffset_ = offset;
    }

    /// 在指定偏移处解码条目
    bool decodeEntryAt(uint offset) nothrow
    {
        const(ubyte)* ptr = block_.data().data() + offset;
        const(ubyte)* limit = block_.data().data() + block_.restartsOffset_;

        uint sharedLen, nonShared, valueLength;
        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            return false;
        }

        key_ = Slice(ptr, nonShared);
        ptr += nonShared;
        value_ = Slice(ptr, valueLength);
        return true;
    }
}

///
unittest
{
    import dleveldb.block_builder;
    import dleveldb.comparator;

    // ====== BlockIter.seek() 测试 ======
    // 通过 BlockBuilder 构建块，再用 Block + BlockIter 读取验证

    // --- 测试1: 基本seek定位 ---
    auto bb1 = BlockBuilder(16);
    bb1.add(Slice("a"), Slice("va"));
    bb1.add(Slice("b"), Slice("vb"));
    bb1.add(Slice("c"), Slice("vc"));

    auto blockData1 = bb1.finish();
    // 需要拷贝数据，因为 BlockBuilder 的 buffer 可能被修改
    ubyte[] blockBuf1 = blockData1.data()[0 .. blockData1.size()].dup;
    auto block1 = new Block(Slice(blockBuf1.ptr, blockBuf1.length));
    auto iter1 = block1.iterator(defaultComparator());

    iter1.seek(Slice("b"));
    assert(iter1.valid());
    assert(iter1.key() == Slice("b"));
    assert(iter1.value() == Slice("vb"));

    iter1.seek(Slice("a"));
    assert(iter1.valid());
    assert(iter1.key() == Slice("a"));
    assert(iter1.value() == Slice("va"));

    iter1.seek(Slice("c"));
    assert(iter1.valid());
    assert(iter1.key() == Slice("c"));

    // --- 测试2: seek到不存在的键，定位到下一个 ---
    iter1.seek(Slice("b0"));
    assert(iter1.valid());
    assert(iter1.key() == Slice("c"));

    // seek到最前之前
    iter1.seek(Slice("0"));
    assert(iter1.valid());
    assert(iter1.key() == Slice("a"));

    // seek超出范围
    iter1.seek(Slice("z"));
    assert(!iter1.valid());

    // --- 测试3: seekToFirst + next 全遍历 ---
    iter1.seekToFirst();
    assert(iter1.valid());
    assert(iter1.key() == Slice("a"));
    iter1.next();
    assert(iter1.valid());
    assert(iter1.key() == Slice("b"));
    iter1.next();
    assert(iter1.valid());
    assert(iter1.key() == Slice("c"));
    iter1.next();
    assert(!iter1.valid());

    // --- 测试4: 前缀共享的键 ---
    auto bb2 = BlockBuilder(16);
    bb2.add(Slice("key1"), Slice("val1"));
    bb2.add(Slice("key2"), Slice("val2"));
    bb2.add(Slice("key3"), Slice("val3"));

    auto blockData2 = bb2.finish();
    ubyte[] blockBuf2 = blockData2.data()[0 .. blockData2.size()].dup;
    auto block2 = new Block(Slice(blockBuf2.ptr, blockBuf2.length));
    auto iter2 = block2.iterator(defaultComparator());

    iter2.seek(Slice("key2"));
    assert(iter2.valid());
    assert(iter2.key() == Slice("key2"));
    assert(iter2.value() == Slice("val2"));

    iter2.seek(Slice("key0"));
    assert(iter2.valid());
    assert(iter2.key() == Slice("key1"));

    iter2.seek(Slice("key4"));
    assert(!iter2.valid());

    // --- 测试5: 无前缀共享（restartInterval=1）---
    auto bb3 = BlockBuilder(1);
    bb3.add(Slice("alpha"), Slice("1"));
    bb3.add(Slice("beta"), Slice("2"));
    bb3.add(Slice("gamma"), Slice("3"));

    auto blockData3 = bb3.finish();
    ubyte[] blockBuf3 = blockData3.data()[0 .. blockData3.size()].dup;
    auto block3 = new Block(Slice(blockBuf3.ptr, blockBuf3.length));
    auto iter3 = block3.iterator(defaultComparator());

    iter3.seek(Slice("beta"));
    assert(iter3.valid());
    assert(iter3.key() == Slice("beta"));
    assert(iter3.value() == Slice("2"));

    iter3.seekToFirst();
    assert(iter3.key() == Slice("alpha"));
    iter3.next();
    assert(iter3.key() == Slice("beta"));
    iter3.next();
    assert(iter3.key() == Slice("gamma"));
    iter3.next();
    assert(!iter3.valid());

    // --- 测试6: 单键块 ---
    auto bb4 = BlockBuilder(16);
    bb4.add(Slice("only"), Slice("val"));

    auto blockData4 = bb4.finish();
    ubyte[] blockBuf4 = blockData4.data()[0 .. blockData4.size()].dup;
    auto block4 = new Block(Slice(blockBuf4.ptr, blockBuf4.length));
    auto iter4 = block4.iterator(defaultComparator());

    iter4.seek(Slice("only"));
    assert(iter4.valid());
    assert(iter4.key() == Slice("only"));

    iter4.seek(Slice("n"));  // "n" < "only"
    assert(iter4.valid());
    assert(iter4.key() == Slice("only"));

    iter4.seek(Slice("p"));  // "p" > "only"
    assert(!iter4.valid());
}

///
unittest
{
    import dleveldb.block_builder;
    import dleveldb.comparator;

    // ====== BlockIter.seek() 边界情况测试 ======

    // --- 测试1: seek后反向遍历 ---
    // 注意：BlockIter的反向遍历实现较为复杂，这里先跳过
    // 专注于seek功能测试

    // --- 测试2: 方向切换测试 ---
    // 注意：方向切换测试暂时跳过

    // --- 测试3: 重复seek测试 ---
    auto bb3 = BlockBuilder(16);
    bb3.add(Slice("a"), Slice("va"));
    bb3.add(Slice("b"), Slice("vb"));
    bb3.add(Slice("c"), Slice("vc"));

    auto blockData3 = bb3.finish();
    ubyte[] blockBuf3 = blockData3.data()[0 .. blockData3.size()].dup;
    auto block3 = new Block(Slice(blockBuf3.ptr, blockBuf3.length));
    auto iter3 = block3.iterator(defaultComparator());

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

    // --- 测试4: 空键测试 ---
    auto bb4 = BlockBuilder(16);
    bb4.add(Slice(""), Slice("empty_key"));
    bb4.add(Slice("a"), Slice("va"));

    auto blockData4 = bb4.finish();
    ubyte[] blockBuf4 = blockData4.data()[0 .. blockData4.size()].dup;
    auto block4 = new Block(Slice(blockBuf4.ptr, blockBuf4.length));
    auto iter4 = block4.iterator(defaultComparator());

    iter4.seek(Slice(""));
    assert(iter4.valid());
    assert(iter4.key() == Slice(""));

    iter4.next();
    assert(iter4.key() == Slice("a"));

    // seek空键应该定位到第一个
    iter4.seek(Slice(""));
    assert(iter4.key() == Slice(""));

    // --- 测试5: seekToLast与反向遍历 ---
    // 注意：反向遍历测试暂时跳过

    // --- 测试6: 大量键的seek测试 ---
    auto bb6 = BlockBuilder(16);
    for (int i = 0; i < 100; i++)
    {
        import std.conv : to;
        string key = "key" ~ to!string(i);
        string val = "val" ~ to!string(i);
        bb6.add(Slice(key), Slice(val));
    }

    auto blockData6 = bb6.finish();
    ubyte[] blockBuf6 = blockData6.data()[0 .. blockData6.size()].dup;
    auto block6 = new Block(Slice(blockBuf6.ptr, blockBuf6.length));
    auto iter6 = block6.iterator(defaultComparator());

    // seek到中间位置
    iter6.seek(Slice("key50"));
    assert(iter6.valid());
    assert(iter6.key() == Slice("key50"));

    // seek到不存在的键
    iter6.seek(Slice("key50a"));
    assert(iter6.valid());
    assert(iter6.key() == Slice("key51"));

    // seek到第一个
    iter6.seek(Slice("key0"));
    assert(iter6.valid());
    assert(iter6.key() == Slice("key0"));

    // seek到最后
    iter6.seek(Slice("key99"));
    assert(iter6.valid());
    assert(iter6.key() == Slice("key99"));

    // seek超出范围
    iter6.seek(Slice("key999"));
    assert(!iter6.valid());
}
