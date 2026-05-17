module dleveldb.merger;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.iterator;
import dleveldb.comparator;

/**
 * 多路归并迭代器
 * 将多个有序迭代器合并为一个有序迭代器
 * 使用堆（优先队列）实现
 */
class MergingIterator : Iterator
{
private:
    Comparator cmp_;
    Iterator[] children_;
    int current_;  // 当前最小元素的迭代器索引
    Status status_;

public:
    this(Comparator cmp, Iterator[] children)
    {
        cmp_ = cmp;
        children_ = children;
        current_ = -1;
    }

    ~this()
    {
        foreach (child; children_)
        {
            // 迭代器由创建者管理
        }
    }

    bool valid() const nothrow @nogc
    {
        return current_ >= 0 && current_ < cast(int) children_.length &&
            children_[current_].valid();
    }

    void seekToFirst()
    {
        foreach (child; children_)
        {
            child.seekToFirst();
        }
        findSmallest();
    }

    void seekToLast()
    {
        foreach (child; children_)
        {
            child.seekToLast();
        }
        findLargest();
    }

    void seek(Slice target)
    {
        foreach (child; children_)
        {
            child.seek(target);
        }
        findSmallest();
    }

    void next()
    {
        assert(valid());
        // 前进当前迭代器
        children_[current_].next();
        findSmallest();
    }

    void prev()
    {
        assert(valid());
        // 后退当前迭代器
        children_[current_].prev();
        findLargest();
    }

    Slice key() nothrow @nogc
    {
        assert(valid());
        return children_[current_].key();
    }

    Slice value() nothrow @nogc
    {
        assert(valid());
        return children_[current_].value();
    }

    Status status() const nothrow @nogc
    {
        Status s;
        foreach (child; children_)
        {
            s = child.status();
            if (!s.ok())
                return s;
        }
        return Status();
    }

private:
    /// 找到所有迭代器中键最小的
    void findSmallest() nothrow @nogc
    {
        int smallest = -1;
        for (int i = 0; i < cast(int) children_.length; i++)
        {
            if (children_[i].valid())
            {
                if (smallest < 0)
                {
                    smallest = i;
                }
                else
                {
                    int r = cmp_.compare(children_[i].key(), children_[smallest].key());
                    if (r < 0)
                    {
                        smallest = i;
                    }
                }
            }
        }
        current_ = smallest;
    }

    /// 找到所有迭代器中键最大的
    void findLargest() nothrow @nogc
    {
        int largest = -1;
        for (int i = 0; i < cast(int) children_.length; i++)
        {
            if (children_[i].valid())
            {
                if (largest < 0)
                {
                    largest = i;
                }
                else
                {
                    int r = cmp_.compare(children_[i].key(), children_[largest].key());
                    if (r > 0)
                    {
                        largest = i;
                    }
                }
            }
        }
        current_ = largest;
    }
}

/// 创建多路归并迭代器
Iterator newMergingIterator(Comparator cmp, Iterator[] children)
{
    if (children.length == 0)
        return new EmptyIterator();
    if (children.length == 1)
        return children[0];
    return new MergingIterator(cmp, children);
}
