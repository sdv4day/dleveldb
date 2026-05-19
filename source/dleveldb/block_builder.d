module dleveldb.block_builder;

import dleveldb.slice;
import dleveldb.coding;

/**
 * 数据块构建器
 * 使用键前缀压缩，每blockRestartInterval个键设置一个重启点
 * 
 * 条目格式：varint32(shared) + varint32(non_shared) + varint32(value_length) + key_delta + value
 * 尾部：uint32[num_restarts] + uint32(num_restarts)
 */
struct BlockBuilder
{
private:
    int[] restarts_;       // 重启点偏移列表
    int counter_;          // 当前块中条目计数
    bool finished_;        // 是否已调用finish()
    ubyte[] buffer_;       // 输出缓冲区
    Slice lastKey_;        // 上一个键
    int restartInterval_ = 16;

public:
    /// 构造函数，指定重启点间隔
    this(int restartInterval)
    {
        restartInterval_ = restartInterval;
        restarts_ = [];
        counter_ = 0;
        finished_ = false;
    }

    /// 是否为空
    bool empty() const pure nothrow @safe @nogc
    {
        return counter_ == 0;
    }

    /// 估算当前块大小
    size_t estimatedSize() const nothrow @nogc
    {
        return buffer_.length + restarts_.length * uint.sizeof + uint.sizeof;
    }

    /// 添加键值对
    void add(Slice key, Slice value) nothrow
    {
        assert(!finished_);
        size_t sharedLen = 0;

        if (counter_ < restartInterval_)
        {
            // 计算与前一个键的共享前缀长度
            size_t minLen = lastKey_.size() < key.size() ? lastKey_.size() : key.size();
            while (sharedLen < minLen && lastKey_.data()[sharedLen] == key.data()[sharedLen])
            {
                sharedLen++;
            }
        }
        else
        {
            // 重启点：不共享前缀
            restarts_ ~= cast(int) buffer_.length;
            counter_ = 0;
        }

        size_t nonShared = key.size() - sharedLen;

        // 编码：varint32(sharedLen) + varint32(non_shared) + varint32(value_length)
        size_t oldLen = buffer_.length;
        int varintShared = varintLength(cast(uint) sharedLen);
        int varintNonShared = varintLength(cast(uint) nonShared);
        int varintValLen = varintLength(cast(uint) value.size());
        size_t entrySize = varintShared + varintNonShared + varintValLen + nonShared + value.size();

        buffer_.length = oldLen + entrySize;
        ubyte* p = buffer_.ptr + oldLen;

        p += encodeVarint32(p, cast(uint) sharedLen);
        p += encodeVarint32(p, cast(uint) nonShared);
        p += encodeVarint32(p, cast(uint) value.size());

        // 拷贝non-shared key部分（使用D标准数组切片拷贝）
        if (nonShared > 0)
        {
            auto offset = p - buffer_.ptr;
            buffer_[offset .. offset + nonShared] = key.asBytes()[sharedLen .. sharedLen + nonShared];
            p = buffer_.ptr + offset + nonShared;
        }
        else
        {
            p += nonShared;
        }

        // 拷贝value（使用D标准数组切片拷贝）
        if (value.size() > 0)
        {
            auto offset = p - buffer_.ptr;
            buffer_[offset .. offset + value.size()] = value.asBytes();
        }

        counter_++;
        lastKey_ = key;
    }

    /// 完成块构建，返回块数据
    Slice finish() nothrow
    {
        assert(!finished_);
        finished_ = true;

        // 写入重启点数组
        size_t oldLen = buffer_.length;
        buffer_.length = oldLen + restarts_.length * uint.sizeof + uint.sizeof;

        ubyte* p = buffer_.ptr + oldLen;
        foreach (restart; restarts_)
        {
            encodeFixed32(p, cast(uint) restart);
            p += uint.sizeof;
        }
        encodeFixed32(p, cast(uint) restarts_.length);

        return Slice(buffer_.ptr, buffer_.length);
    }

    /// 重置构建器
    void reset() pure nothrow @safe
    {
        buffer_.length = 0;
        restarts_ = [0];
        counter_ = 0;
        finished_ = false;
        lastKey_ = Slice();
    }

    /// 获取当前缓冲区（用于计算大小）
    Slice currentContents() const nothrow @nogc
    {
        return Slice(buffer_.ptr, buffer_.length);
    }
}
