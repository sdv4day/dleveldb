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
    Slice m_data;
    int m_numRestarts;
    uint m_restartInterval;

    // 重启点数组在m_data中的偏移
    size_t m_restartsOffset;

public:
    /**
     * 构造数据块
     * Params: data = 包含块数据的Slice，末尾4字节为重启点数量
     */
    this(Slice data)
    {
        m_data = data;
        if (m_data.size() < uint.sizeof)
        {
            m_numRestarts = 0;
            m_restartsOffset = 0;
            return;
        }

        // 最后4字节是重启点数量
        m_numRestarts = cast(int) decodeFixed32(m_data.data() + m_data.size() - uint.sizeof);
        m_restartsOffset = m_data.size() - uint.sizeof - cast(size_t) m_numRestarts * uint.sizeof;

        if (m_restartsOffset > m_data.size())
        {
            // 数据损坏
            m_numRestarts = 0;
            m_restartsOffset = 0;
        }
    }

    /// 获取块大小
    size_t size() const pure nothrow @safe @nogc { return m_data.size(); }

    /// 获取块数据
    Slice data() const nothrow @nogc { return m_data; }

    /// 获取重启点数量
    int numRestarts() const pure nothrow @safe @nogc { return m_numRestarts; }

    /// 获取第i个重启点的偏移
    uint restartPoint(int i) const nothrow @nogc
    {
        assert(i >= 0 && i < m_numRestarts);
        return decodeFixed32(m_data.data() + m_restartsOffset + i * uint.sizeof);
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
    Block m_block;
    Comparator m_cmp;
    uint m_restartIndex;  // 当前重启点索引
    uint m_currentOffset; // 当前条目在块数据中的偏移
    Slice m_key;          // 当前键
    Slice m_value;        // 当前值
    ubyte[] m_keyBuf;     // 键的GC管理缓冲区，防止Slice悬挂引用
    Status m_status;
    bool m_valid;
public:
    /**
     * 构造块内迭代器
     * Params:
     *     block = 要迭代的数据块
     *     cmp   = 键比较器，用于seek时的二分搜索
     */
    this(Block block, Comparator cmp) nothrow
    {
        m_block = block;
        m_cmp = cmp;
        m_restartIndex = 0;
        m_currentOffset = 0;
        m_valid = false;
    }

    /**
     * 检查迭代器是否指向有效条目
     * Returns: 若当前指向有效条目则返回true，否则返回false
     */
    bool valid() const nothrow @nogc { return m_valid; }

    /**
     * 获取当前条目的键
     * Returns: 当前键的Slice引用
     */
    Slice key() nothrow @nogc { return m_key; }
    /**
     * 获取当前条目的值
     * Returns: 当前值的Slice引用
     */
    Slice value() nothrow @nogc { return m_value; }
    /**
     * 获取迭代器的错误状态
     * Returns: 若解码过程中发生错误则返回对应的错误状态，否则返回OK状态
     */
    Status status() const nothrow @nogc { return m_status; }

    /// 定位到块内第一个条目
    void seekToFirst()
    {
        m_restartIndex = 0;
        seekToRestartPoint(0);
        while (m_valid && m_key.size() == 0)
        {
            next();
        }
    }

    /// 定位到块内最后一个条目
    void seekToLast()
    {
        if (m_block.numRestarts() == 0)
        {
            m_valid = false;
            return;
        }
        m_restartIndex = cast(uint) (m_block.numRestarts() - 1);
        seekToRestartPoint(cast(int) m_restartIndex);
        // 从最后一个重启点扫描前进，直到块末尾
        while (true)
        {
            Slice savedKey = m_key;
            Slice savedValue = m_value;
            uint savedOffset = m_currentOffset;
            uint savedRestartIndex = m_restartIndex;
            next();
            if (!m_valid)
            {
                // 到达块末尾，恢复最后一个有效条目
                m_key = savedKey;
                m_value = savedValue;
                m_currentOffset = savedOffset;
                m_restartIndex = savedRestartIndex;
                m_valid = true;
                return;
            }
        }
    }

    /**
     * 定位到键大于等于target的第一个条目
     * Params: target = 要查找的目标键
     */
    void seek(Slice target)
    {
        // 二分搜索找到target所在的重启点
        int left = 0;
        int right = m_block.numRestarts() - 1;

        while (left < right)
        {
            int mid = (left + right + 1) / 2;
            uint offset = m_block.restartPoint(mid);
            if (decodeEntryAt(offset) && m_cmp.compare(m_key, target) < 0)
            {
                left = mid;
            }
            else
            {
                right = mid - 1;
            }
        }

        m_restartIndex = cast(uint) left;
        seekToRestartPoint(left);

        // 线性搜索找到>=target的条目
        while (m_valid)
        {
            if (m_cmp.compare(m_key, target) >= 0)
                return;
            next();
        }
    }

    /**
     * 移动到下一个条目
     * 调用前必须保证valid()为true
     */
    void next()
    {
        assert(m_valid);
        uint offset = cast(uint) currentOffset();

        if (offset >= cast(uint) m_block.m_restartsOffset)
        {
            m_valid = false;
            return;
        }

        // 先从当前偏移处解码，计算当前条目大小以跳到下一个
        const(ubyte)* ptr = m_block.data().data() + offset;
        const(ubyte)* limit = m_block.data().data() + m_block.m_restartsOffset;

        uint sharedLen, nonShared, valueLength;
        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            m_valid = false;
            m_status = statusCorruption("bad entry in block");
            return;
        }

        // 跳到下一个条目
        uint nextOffset = cast(uint) (ptr + nonShared + valueLength - m_block.data().data());

        if (nextOffset >= cast(uint) m_block.m_restartsOffset)
        {
            m_valid = false;
            return;
        }

        // 在nextOffset处解码下一个条目
        ptr = m_block.data().data() + nextOffset;

        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            m_valid = false;
            m_status = statusCorruption("bad entry in block");
            return;
        }

        if (sharedLen > m_key.size())
        {
            m_valid = false;
            m_status = statusCorruption("bad shared length");
            return;
        }

        // 更新key：保留shared前缀，替换nonShared部分
        // 注意：必须先复制共享部分，因为改变 m_keyBuf.length 可能导致 GC 重新分配
        // 从而使 m_key 指向的内存失效
        ubyte[] sharedBuf;
        if (sharedLen > 0)
        {
            sharedBuf = m_key.asBytes()[0 .. sharedLen].dup;
        }
        
        m_keyBuf.length = sharedLen + nonShared;
        
        if (sharedLen > 0)
        {
            m_keyBuf[0 .. sharedLen] = sharedBuf[];
        }
        if (nonShared > 0)
        {
            m_keyBuf[sharedLen .. sharedLen + nonShared] = ptr[0 .. nonShared];
        }
        ptr += nonShared;

        m_key = Slice(m_keyBuf.ptr, m_keyBuf.length);
        m_value = Slice(ptr, valueLength);
        m_currentOffset = nextOffset;

        // 更新重启点索引
        while (m_restartIndex + 1 < cast(uint) m_block.numRestarts() &&
               m_block.restartPoint(cast(int) (m_restartIndex + 1)) <= nextOffset)
        {
            m_restartIndex++;
        }
    }

    /**
     * 移动到上一个条目
     * 调用前必须保证valid()为true
     */
    void prev()
    {
        assert(m_valid);

        uint offset = cast(uint) currentOffset();

        // 回退到当前偏移之前的重启点
        int ri = cast(int) m_restartIndex;
        while (ri > 0 && m_block.restartPoint(ri) >= offset)
        {
            ri--;
        }

        seekToRestartPoint(ri);

        // 如果seekToRestartPoint后无效，说明没有前一个条目
        if (!m_valid)
        {
            return;
        }

        // 从重启点扫描前进，记录前一个条目的完整状态
        // 注意：必须使用独立的缓冲区来保存 prevKey 和 prevValue，
        // 因为 next() 会修改 m_keyBuf 和 m_key
        uint prevOffset = currentOffset();
        ubyte[] prevKeyBuf = m_keyBuf.dup;  // 复制当前键
        ubyte[] prevValueBuf = m_value.data()[0 .. m_value.size()].dup;  // 复制当前值
        uint prevRestartIndex = m_restartIndex;

        while (m_valid && currentOffset() < offset)
        {
            prevOffset = currentOffset();
            prevKeyBuf = m_keyBuf.dup;
            prevValueBuf = m_value.data()[0 .. m_value.size()].dup;
            prevRestartIndex = m_restartIndex;
            next();
        }

        if (prevOffset < offset)
        {
            // 恢复到前一个条目的完整状态
            m_currentOffset = prevOffset;
            m_keyBuf = prevKeyBuf;
            m_key = Slice(m_keyBuf.ptr, m_keyBuf.length);
            m_value = Slice(prevValueBuf.ptr, prevValueBuf.length);
            m_restartIndex = prevRestartIndex;
            m_valid = true;
        }
        else
        {
            // 没有前一个条目（当前就是第一个条目）
            m_valid = false;
        }
    }

private:
    /// 获取当前偏移
    uint currentOffset() const nothrow @nogc
    {
        return m_currentOffset;
    }

    /// 定位到重启点
    void seekToRestartPoint(int index) nothrow
    {
        if (index < 0 || index >= m_block.numRestarts())
        {
            m_valid = false;
            return;
        }

        uint offset = m_block.restartPoint(index);
        const(ubyte)* ptr = m_block.data().data() + offset;
        const(ubyte)* limit = m_block.data().data() + m_block.m_restartsOffset;

        uint sharedLen, nonShared, valueLength;
        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            m_valid = false;
            return;
        }

        // 重启点处sharedLen必须为0
        if (sharedLen != 0)
        {
            m_valid = false;
            return;
        }

        // 复制键数据到 GC 管理的缓冲区，避免 Slice 悬挂引用
        // 注意：即使 nonShared 为 0，也要确保 m_keyBuf 有有效内存
        if (nonShared > 0)
        {
            m_keyBuf.length = nonShared;
            m_keyBuf[0 .. nonShared] = ptr[0 .. nonShared];
            m_key = Slice(m_keyBuf.ptr, m_keyBuf.length);
        }
        else
        {
            // 空键：使用静态空缓冲区
            static ubyte[1] emptyBuf = 0;
            m_key = Slice(emptyBuf.ptr, 0);
        }
        ptr += nonShared;
        m_value = Slice(ptr, valueLength);
        m_valid = true;
        m_restartIndex = cast(uint) index;
        m_currentOffset = offset;
    }

    /// 在指定偏移处解码条目（仅用于重启点，sharedLen必须为0）
    bool decodeEntryAt(uint offset) nothrow
    {
        const(ubyte)* ptr = m_block.data().data() + offset;
        const(ubyte)* limit = m_block.data().data() + m_block.m_restartsOffset;

        uint sharedLen, nonShared, valueLength;
        if (!decodeVarint32(ptr, limit, sharedLen) ||
            !decodeVarint32(ptr, limit, nonShared) ||
            !decodeVarint32(ptr, limit, valueLength))
        {
            return false;
        }

        // 重启点处 sharedLen 必须为 0
        if (sharedLen != 0)
        {
            return false;
        }

        // 复制键数据到 GC 管理的缓冲区，避免 Slice 悬挂引用
        if (nonShared > 0)
        {
            m_keyBuf.length = nonShared;
            m_keyBuf[0 .. nonShared] = ptr[0 .. nonShared];
            m_key = Slice(m_keyBuf.ptr, m_keyBuf.length);
        }
        else
        {
            // 空键：使用静态空缓冲区
            static ubyte[1] emptyBuf = 0;
            m_key = Slice(emptyBuf.ptr, 0);
        }
        ptr += nonShared;
        m_value = Slice(ptr, valueLength);
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
