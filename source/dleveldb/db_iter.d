module dleveldb.db_iter;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.iterator;
import dleveldb.dbformat;
import dleveldb.comparator;
import dleveldb.coding;

/**
 * 数据库级迭代器
 * 将内部键迭代器转换为用户键迭代器
 * 处理删除标记和序列号覆盖
 */
class DBIter : Iterator
{
private:
    Comparator userComparator_;
    Iterator internalIter_;
    ulong sequence_;
    Slice savedKey_;     // 保存的内部键
    ubyte[] savedValue_; // 保存的值
    Status status_;
    bool valid_;
    Direction direction_;

    enum Direction : ubyte
    {
        forward = 0,
        reverse = 1,
    }

public:
    this(Comparator userCmp, Iterator internalIter, ulong sequence)
    {
        userComparator_ = userCmp;
        internalIter_ = internalIter;
        sequence_ = sequence;
        valid_ = false;
        direction_ = Direction.forward;
    }

    bool valid() const nothrow @nogc { return valid_; }

    void seekToFirst()
    {
        internalIter_.seekToFirst();
        direction_ = Direction.forward;
        findNextUserEntry(false, Slice());
    }

    void seekToLast()
    {
        internalIter_.seekToLast();
        direction_ = Direction.reverse;
        findPrevUserEntry();
    }

    void seek(Slice target)
    {
        InternalKey ikey = InternalKey(target, sequence_, ValueType.value);
        internalIter_.seek(ikey.encode());
        direction_ = Direction.forward;
        findNextUserEntry(false, Slice());
    }

    void next()
    {
        assert(valid());
        if (direction_ != Direction.forward)
        {
            // 切换方向
            InternalKey ikey = InternalKey(savedKey_, sequence_, ValueType.value);
            internalIter_.seek(ikey.encode());
            direction_ = Direction.forward;
            if (!internalIter_.valid())
            {
                internalIter_.seekToFirst();
            }
            else
            {
                internalIter_.next();
            }
        }
        findNextUserEntry(true, savedKey_);
    }

    void prev()
    {
        assert(valid());
        if (direction_ != Direction.reverse)
        {
            // 切换方向
            InternalKey ikey = InternalKey(savedKey_, sequence_, ValueType.value);
            internalIter_.seek(ikey.encode());
            direction_ = Direction.reverse;
        }
        findPrevUserEntry();
    }

    Slice key()
    {
        assert(valid());
        return savedKey_;
    }

    Slice value()
    {
        assert(valid());
        return Slice(savedValue_.ptr, savedValue_.length);
    }

    Status status() const nothrow @nogc { return status_; }

private:
    /// 向前查找下一个用户键
    /// skip: 是否跳过当前键
    /// savedKey: 当前用户键（用于跳过同键的其他版本）
    void findNextUserEntry(bool skip, Slice savedKey)
    {
        // 重新实现简化版本
        while (internalIter_.valid())
        {
            Slice ikey = internalIter_.key();
            ParsedInternalKey parsed;
            if (!parseInternalKey(ikey, parsed))
            {
                status_ = statusCorruption("bad internal key");
                valid_ = false;
                return;
            }

            if (parsed.sequence <= sequence_)
            {
                if (parsed.type == ValueType.deletion)
                {
                    // 删除标记，跳过所有同键条目
                    Slice userKey = extractUserKey(ikey);
                    skip = true;
                    savedKey_ = userKey;
                }
                else if (parsed.type == ValueType.value)
                {
                    if (skip && userComparator_.compare(extractUserKey(ikey), savedKey_) <= 0)
                    {
                        // 跳过同键的旧版本
                    }
                    else
                    {
                        // 找到有效值
                        valid_ = true;
                        savedKey_ = extractUserKey(ikey);
                        Slice val = internalIter_.value();
                        savedValue_.length = val.size();
                        for (size_t i = 0; i < val.size(); i++)
                            savedValue_[i] = val.data()[i];
                        return;
                    }
                }
            }
            internalIter_.next();
        }
        valid_ = false;
    }

    /// 向后查找前一个用户键
    void findPrevUserEntry()
    {
        ValueType lastType = ValueType.value;
        Slice lastKey;

        while (internalIter_.valid())
        {
            Slice ikey = internalIter_.key();
            ParsedInternalKey parsed;
            if (!parseInternalKey(ikey, parsed))
            {
                status_ = statusCorruption("bad internal key");
                valid_ = false;
                return;
            }

            if (parsed.sequence <= sequence_)
            {
                Slice userKey = extractUserKey(ikey);
                if (userComparator_.compare(userKey, lastKey) != 0)
                {
                    // 新的用户键
                    if (lastType == ValueType.value)
                    {
                        valid_ = true;
                        savedKey_ = lastKey;
                        return;
                    }
                    lastType = ValueType.deletion;
                }
                lastKey = userKey;
                lastType = parsed.type;
            }
            internalIter_.prev();
        }

        // 检查最后一个键
        if (lastType == ValueType.value)
        {
            valid_ = true;
            savedKey_ = lastKey;
        }
        else
        {
            valid_ = false;
        }
    }

    /// 解析内部键
    bool parseInternalKey(Slice ikey, ref ParsedInternalKey parsed) nothrow @nogc
    {
        if (ikey.size() < ulong.sizeof)
            return false;
        parsed.userKey = Slice(ikey.data(), ikey.size() - ulong.sizeof);
        ulong tag = decodeFixed64(ikey.data() + ikey.size() - ulong.sizeof);
        parsed.sequence = unpackSequence(tag);
        parsed.type = unpackValueType(tag);
        return true;
    }
}

/// 创建数据库级迭代器
Iterator newDBIterator(Comparator userCmp, Iterator internalIter, ulong sequence)
{
    return new DBIter(userCmp, internalIter, sequence);
}
