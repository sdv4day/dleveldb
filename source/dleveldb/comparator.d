/**
 * 键比较器接口和实现
 *
 * 提供键比较功能，用于有序存储和查找。
 * 默认实现为字节序比较器。
 *
 * Copyright: BSL-1.0
 * Authors: sdv
 * Date: 2024
 */
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

    /**
     * 查找短分隔符（用于SSTable索引块优化）
     * 找到[start, limit]之间的短字符串separator
     */
    void findShortestSeparator(ref Slice start, Slice limit) const;

    /// 查找小于所有大于key的键的短键
    void findShortSuccessor(ref Slice key) const;
}

/**
 * 字节序比较器（默认实现）
 */
class BytewiseComparator : Comparator
{
private:
    ubyte[] separatorBuf_;  // GC管理的缓冲区，用于findShortestSeparator

public:
    /**
     * 获取比较器名称
     * Returns: 比较器名称字符串，用于MANIFEST持久化标识
     */
    string name() const
    {
        return "dleveldb.BytewiseComparator";
    }

    /**
     * 比较两个键的字节序大小
     *
     * Params:
     *     a = 第一个键
     *     b = 第二个键
     * Returns: 小于0表示a<b，等于0表示a==b，大于0表示a>b
     */
    int compare(Slice a, Slice b) const nothrow @nogc
    {
        return a.opCmp(b);
    }

    /**
     * 找最短分隔键，用于SSTable索引块优化
     *
     * 在[start, limit]之间找到一个尽可能短的字符串作为分隔键，
     * 使得所有小于分隔键的键都小于limit，所有大于等于分隔键的键都大于start
     *
     * Params:
     *     start = 起始键（引用传递，可能被修改为更短的分隔键）
     *     limit = 上限键
     */
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
            return;
        }

        ubyte startByte = start.data()[diffIndex];
        ubyte limitByte = limit.data()[diffIndex];

        if (startByte + 1 < limitByte)
        {
            // 可以缩短start：取前diffIndex+1个字节，最后一个字节加1
            size_t newLen = diffIndex + 1;
            // 使用cast移除const以修改成员缓冲区
            (cast(BytewiseComparator)this).separatorBuf_.length = newLen;
            (cast(BytewiseComparator)this).separatorBuf_[0 .. diffIndex] =
                start.data()[0 .. diffIndex];
            (cast(BytewiseComparator)this).separatorBuf_[diffIndex] = cast(ubyte)(startByte + 1);
            start = Slice((cast(BytewiseComparator)this).separatorBuf_.ptr, newLen);
        }
    }

    /**
     * 找短后继键，用于SSTable索引块优化
     *
     * 找到一个尽可能短的键，该键在字节序上大于所有以key为前缀的键
     *
     * Params:
     *     key = 输入键（引用传递，可能被修改为更短的后继键）
     */
    void findShortSuccessor(ref Slice key) const
    {
        // 找到第一个可以+1的字节
        for (size_t i = 0; i < key.size(); i++)
        {
            if (key.data()[i] != ubyte.max)
            {
                // 取前i+1个字节，最后一个字节加1
                size_t newLen = i + 1;
                (cast(BytewiseComparator)this).separatorBuf_.length = newLen;
                (cast(BytewiseComparator)this).separatorBuf_[0 .. i] =
                    key.data()[0 .. i];
                (cast(BytewiseComparator)this).separatorBuf_[i] = cast(ubyte)(key.data()[i] + 1);
                key = Slice((cast(BytewiseComparator)this).separatorBuf_.ptr, newLen);
                return;
            }
        }
        // 所有字节都是0xFF，不做修改
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
