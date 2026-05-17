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
