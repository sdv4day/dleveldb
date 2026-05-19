module dleveldb.filter_block;

import dleveldb.slice;
import dleveldb.filter_policy;
import dleveldb.coding;

/**
 * 过滤器块构建器
 * 每2KB数据块生成一个过滤器
 */
class FilterBlockBuilder
{
private:
    FilterPolicy policy_;
    ubyte[] result_;          // 输出缓冲区
    uint[] filterOffsets_;    // 每个过滤器的偏移
    Slice[] keys_;           // 当前块的键集合
    size_t start_;           // 当前数据块在result_中的起始偏移

    enum uint kFilterBaseLg = 11; // 2^11 = 2048
    enum uint kFilterBase = 1 << kFilterBaseLg; // 2KB

public:
    this(FilterPolicy policy)
    {
        policy_ = policy;
        start_ = 0;
    }

    /// 开始一个新数据块
    void startBlock(uint blockOffset)
    {
        uint filterIndex = blockOffset >> kFilterBaseLg;
        assert(filterIndex >= filterOffsets_.length);

        // 为之前的数据块生成过滤器
        while (filterOffsets_.length < filterIndex)
        {
            generateFilter();
        }
    }

    /// 添加键到当前过滤器
    void addKey(Slice key) nothrow
    {
        keys_ ~= key;
    }

    /// 完成过滤器块构建
    Slice finish()
    {
        // 生成最后一个过滤器
        if (keys_.length == 0)
        {
            generateFilter();
        }

        // 追加所有过滤器的偏移
        if (filterOffsets_.length == 0)
            filterOffsets_ ~= 0;

        size_t oldLen = result_.length;
        result_.length = oldLen + filterOffsets_.length * uint.sizeof + uint.sizeof + 1;

        ubyte* p = result_.ptr + oldLen;
        foreach (offset; filterOffsets_)
        {
            encodeFixed32(p, offset);
            p += uint.sizeof;
        }
        encodeFixed32(p, cast(uint) filterOffsets_.length);
        p += uint.sizeof;
        *p = cast(ubyte) kFilterBaseLg;

        return Slice(result_.ptr, result_.length);
    }

private:
    /// 为当前键集合生成过滤器
    void generateFilter()
    {
        if (keys_.length == 0)
        {
            // 无键需要生成过滤器，记录空偏移
            filterOffsets_ ~= cast(uint) result_.length;
            return;
        }

        // 调用FilterPolicy创建过滤器
        size_t oldLen = result_.length;
        policy_.createFilter(keys_, cast(int) keys_.length, result_);
        filterOffsets_ ~= cast(uint) oldLen;

        keys_ = null;
    }
}

/**
 * 过滤器块读取器
 */
class FilterBlockReader
{
private:
    FilterPolicy policy_;
    Slice data_;             // 过滤器数据
    uint num_;               // 过滤器数量
    uint baseLg_;            // log2(块大小)
    const(uint)* offsets_;   // 偏移数组

public:
    this(FilterPolicy policy, Slice data)
    {
        policy_ = policy;
        data_ = data;

        if (data_.size() < uint.sizeof + 1)
        {
            num_ = 0;
            baseLg_ = 0;
            offsets_ = null;
            return;
        }

        // 最后一个字节是baseLg
        baseLg_ = data_.data()[data_.size() - 1];

        // 倒数第5个字节开始是num
        num_ = decodeFixed32(data_.data() + data_.size() - uint.sizeof - 1);

        if (data_.size() < uint.sizeof + 1 + num_ * uint.sizeof)
        {
            num_ = 0;
            offsets_ = null;
            return;
        }

        offsets_ = cast(const(uint)*) (data_.data() + data_.size() - uint.sizeof - 1 - num_ * uint.sizeof);
    }

    /// 检查指定数据块中是否可能包含key
    bool keyMayMatch(uint blockOffset, Slice key)
    {
        uint filterIndex = blockOffset >> baseLg_;
        if (filterIndex < num_)
        {
            uint start = offsets_[filterIndex];
            uint end = (filterIndex + 1 < num_) ? offsets_[filterIndex + 1] :
                cast(uint) (data_.size() - uint.sizeof - 1 - num_ * uint.sizeof);

            Slice filter = Slice(data_.data() + start, end - start);
            return policy_.keyMayMatch(key, filter);
        }
        return true; // 超出范围，保守返回true
    }
}
