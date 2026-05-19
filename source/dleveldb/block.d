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
    Slice key_;          // 当前键
    Slice value_;        // 当前值
    Status status_;
    bool valid_;

public:
    this(Block block, Comparator cmp) nothrow
    {
        block_ = block;
        cmp_ = cmp;
        restartIndex_ = 0;
        valid_ = false;
    }

    bool valid() const nothrow @nogc { return valid_; }

    Slice key() nothrow @nogc { return key_; }
    Slice value() nothrow @nogc { return value_; }
    Status status() const nothrow @nogc { return status_; }

    void seekToFirst()
    {
        restartIndex_ = 0;
        seekToRestartPoint(0);
        while (valid_ && key_.size() == 0)
        {
            next();
        }
    }

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

    void next()
    {
        assert(valid_);
        uint offset = cast(uint) currentOffset();

        if (offset >= cast(uint) block_.restartsOffset_)
        {
            valid_ = false;
            return;
        }

        // 解码下一个条目
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

        if (sharedLen > key_.size())
        {
            valid_ = false;
            status_ = statusCorruption("bad shared length");
            return;
        }

        // 更新key：保留shared前缀，替换nonShared部分
        // 使用D标准数组切片拷贝替代memcpy
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

        // 更新重启点索引
        while (restartIndex_ + 1 < cast(uint) block_.numRestarts() &&
               block_.restartPoint(cast(int) (restartIndex_ + 1)) < offset)
        {
            restartIndex_++;
        }
    }

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
    uint currentOffset() nothrow @nogc
    {
        // 基于key/value在data_中的位置计算
        // 简化实现
        return 0;
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
