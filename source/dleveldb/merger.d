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
    /// 构造多路归并迭代器
    /// Params: cmp = 键比较器，用于确定迭代器间的排序顺序
    ///         children = 待归并的子迭代器数组
    this(Comparator cmp, Iterator[] children)
    {
        cmp_ = cmp;
        children_ = children;
        current_ = -1;
    }

    /// 析构多路归并迭代器
    /// 子迭代器的生命周期由创建者管理，此处不释放
    ~this()
    {
        foreach (child; children_)
        {
            // 迭代器由创建者管理
        }
    }

    /// 检查迭代器是否指向有效位置
    /// Returns: 若当前指向有效条目则返回 true，否则返回 false
    bool valid() const nothrow @nogc
    {
        return current_ >= 0 && current_ < cast(int) children_.length &&
            children_[current_].valid();
    }

    /// 将所有子迭代器定位到各自的第一个条目，然后归并定位到全局最小键
    void seekToFirst()
    {
        foreach (child; children_)
        {
            child.seekToFirst();
        }
        findSmallest();
    }

    /// 将所有子迭代器定位到各自的最后一个条目，然后归并定位到全局最大键
    void seekToLast()
    {
        foreach (child; children_)
        {
            child.seekToLast();
        }
        findLargest();
    }

    /// 将所有子迭代器定位到大于等于 target 的首条条目，然后归并定位到全局最小键
    /// Params: target = 查找目标键
    void seek(Slice target)
    {
        foreach (child; children_)
        {
            child.seek(target);
        }
        findSmallest();
    }

    /// 前进到下一个条目（当前迭代器前进后重新归并定位全局最小键）
    void next()
    {
        assert(valid());
        // 前进当前迭代器
        children_[current_].next();
        findSmallest();
    }

    /// 后退到上一个条目（当前迭代器后退后重新归并定位全局最大键）
    void prev()
    {
        assert(valid());
        // 后退当前迭代器
        children_[current_].prev();
        findLargest();
    }

    /// 获取当前条目的键
    /// Returns: 当前位置的键切片
    Slice key() nothrow @nogc
    {
        assert(valid());
        return children_[current_].key();
    }

    /// 获取当前条目的值
    /// Returns: 当前位置的值切片
    Slice value() nothrow @nogc
    {
        assert(valid());
        return children_[current_].value();
    }

    /// 获取迭代器的整体状态
    /// Returns: 若所有子迭代器状态正常则返回 OK 状态，否则返回第一个错误状态
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
