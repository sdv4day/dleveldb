module dleveldb.filter_policy;

import dleveldb.slice;

/**
 * 过滤器策略接口（用于SSTable布隆过滤器等）
 */
interface FilterPolicy
{
    /// 过滤器名称（用于MANIFEST持久化）
    string name() const;

    /// 创建过滤器：为n个键创建过滤器，追加到dst
    void createFilter(Slice[] keys, int n, ref ubyte[] dst) const;

    /// 查询键是否可能匹配：返回false表示一定不匹配，true表示可能匹配
    bool keyMayMatch(Slice key, Slice filter) const;
}

/**
 * 布隆过滤器实现
 */
class BloomFilterPolicy : FilterPolicy
{
private:
    int bitsPerKey_;
    int k_; // 哈希函数数量

public:
    this(int bitsPerKey = 10)
    {
        bitsPerKey_ = bitsPerKey;
        // k = bitsPerKey * ln(2)，向上取整
        k_ = cast(int) (bitsPerKey_ * 0.693147180559945); // ln(2)
        if (k_ < 1)
            k_ = 1;
        if (k_ > 30)
            k_ = 30;
    }

    string name() const
    {
        return "dleveldb.BloomFilterPolicy";
    }

    void createFilter(Slice[] keys, int n, ref ubyte[] dst) const nothrow
    {
        import dleveldb.hash : hash;

        // 计算过滤器位数
        int bits = n * bitsPerKey_;
        if (bits < 64)
            bits = 64; // 最小64位

        int bytes = (bits + 7) / 8;
        bits = bytes * 8; // 对齐到8

        size_t oldLen = dst.length;
        dst.length = oldLen + cast(size_t) bytes;
        // 初始化为0
        for (size_t i = oldLen; i < dst.length; i++)
            dst[i] = 0;

        for (int i = 0; i < n; i++)
        {
            // Double hashing: h1 + i*h2
            uint h = hash(keys[i]);
            uint delta = (h >> 17) | (h << 15); // 旋转17位
            for (int j = 0; j < k_; j++)
            {
                int bitpos = cast(int) (h % cast(uint) bits);
                dst[oldLen + bitpos / 8] |= cast(ubyte) (1 << (bitpos % 8));
                h += delta;
            }
        }

        // 追加k_值（1字节）
        dst.length = dst.length + 1;
        dst[$ - 1] = cast(ubyte) k_;
    }

    bool keyMayMatch(Slice key, Slice filter) const nothrow @nogc
    {
        import dleveldb.hash : hash;

        if (filter.size() < 2)
            return false;

        int k = filter.data()[filter.size() - 1]; // 最后一个字节是k_
        if (k > 30)
            return true; // 保留为匹配，避免误判

        int bits = cast(int) ((filter.size() - 1) * 8);
        if (bits < 64)
            bits = 64;

        uint h = hash(key);
        uint delta = (h >> 17) | (h << 15);
        for (int j = 0; j < k; j++)
        {
            int bitpos = cast(int) (h % cast(uint) bits);
            if ((filter.data()[bitpos / 8] & (1 << (bitpos % 8))) == 0)
                return false;
            h += delta;
        }
        return true;
    }
}

/// 创建布隆过滤器
FilterPolicy newBloomFilterPolicy(int bitsPerKey = 10)
{
    return new BloomFilterPolicy(bitsPerKey);
}
