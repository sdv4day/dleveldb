module dleveldb.comparator;

import dleveldb.slice;

/**
 * 键比较器接口
 */
interface Comparator
{
    /// 比较器名称（用于MANIFEST持久化）
    string name() const;

    /// 比较两个Slice，返回-1/0/1
    int compare(Slice a, Slice b) const nothrow @nogc;

    /// 查找短分隔符（用于SSTable索引块优化）
    /// 找到[start, limit]之间的短字符串separator
    void findShortestSeparator(ref Slice start, Slice limit) const;

    /// 查找小于所有大于key的键的短键
    void findShortSuccessor(ref Slice key) const;
}

/**
 * 字节序比较器（默认实现）
 */
class BytewiseComparator : Comparator
{
    string name() const
    {
        return "dleveldb.BytewiseComparator";
    }

    int compare(Slice a, Slice b) const nothrow @nogc
    {
        return a.opCmp(b);
    }

    void findShortestSeparator(ref Slice start, Slice limit) const nothrow
    {
        // 找到start和limit第一个不同的位置
        size_t minLen = start.size() < limit.size() ? start.size() : limit.size();
        size_t diffIndex = 0;
        while (diffIndex < minLen)
        {
            if (start.data()[diffIndex] != limit.data()[diffIndex])
                break;
            diffIndex++;
        }

        if (diffIndex >= minLen)
        {
            // 一个是另一个的前缀，不做优化
        }
        else
        {
            ubyte startByte = start.data()[diffIndex];
            ubyte limitByte = limit.data()[diffIndex];

            if (startByte + 1 < limitByte)
            {
                // 可以缩短start
                // 注意：这里需要创建新的缓冲区
                // 简化实现：不做修改
            }
        }
    }

    void findShortSuccessor(ref Slice key) const
    {
        // 简化实现：不做修改
    }
}

/// 获取默认比较器（TLS惰性初始化，线程安全）
Comparator defaultComparator()
{
    static BytewiseComparator inst;
    if (inst is null)
        inst = new BytewiseComparator();
    return inst;
}

///
unittest
{
    auto cmp = defaultComparator();

    // 名称
    assert(cmp.name() == "dleveldb.BytewiseComparator");

    // 基本比较
    assert(cmp.compare(Slice("a"), Slice("b")) < 0);
    assert(cmp.compare(Slice("b"), Slice("a")) > 0);
    assert(cmp.compare(Slice("abc"), Slice("abc")) == 0);

    // 前缀比较
    assert(cmp.compare(Slice("a"), Slice("ab")) < 0);
    assert(cmp.compare(Slice("ab"), Slice("abc")) < 0);

    // 空Slice比较
    assert(cmp.compare(Slice(""), Slice("")) == 0);
    assert(cmp.compare(Slice(""), Slice("a")) < 0);

    // 字节序比较
    assert(cmp.compare(Slice("\x00"), Slice("\x01")) < 0);
    assert(cmp.compare(Slice("\xFF"), Slice("\x00")) > 0);

    // findShortestSeparator / findShortSuccessor 不崩溃
    Slice start = Slice("abc");
    Slice limit = Slice("abd");
    cmp.findShortestSeparator(start, limit);
    Slice key = Slice("abc");
    cmp.findShortSuccessor(key);
}
