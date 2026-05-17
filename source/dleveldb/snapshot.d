module dleveldb.snapshot;

/**
 * 快照实现
 * 关联序列号，通过双向链表管理
 */
class Snapshot
{
private:
    ulong sequenceNumber_;
    Snapshot next_;
    Snapshot prev_;
    bool linked_;

public:
    this(ulong seq)
    {
        sequenceNumber_ = seq;
        next_ = null;
        prev_ = null;
        linked_ = false;
    }

    ulong sequenceNumber() const pure @safe @nogc
    {
        return sequenceNumber_;
    }

    Snapshot next()  @nogc { return next_; }
    Snapshot prev()  @nogc { return prev_; }
}

/**
 * 快照链表
 */
class SnapshotList
{
private:
    Snapshot head_;  // 哨兵头
    Snapshot tail_;  // 哨兵尾

public:
    this()
    {
        head_ = new Snapshot(0);
        tail_ = new Snapshot(0);
        head_.next_ = tail_;
        head_.prev_ = null;
        tail_.prev_ = head_;
        tail_.next_ = null;
    }

    /// 是否为空
    bool empty() const 
    {
        return head_.next_ is tail_;
    }

    /// 获取最旧的快照序列号
    ulong oldest() const 
    {
        assert(!empty());
        return head_.next_.sequenceNumber_;
    }

    /// 获取最新的快照序列号
    ulong newest() const 
    {
        assert(!empty());
        return tail_.prev_.sequenceNumber_;
    }

    /// 创建新快照
    Snapshot newSnapshot(ulong seq) 
    {
        Snapshot s = new Snapshot(seq);
        // 添加到链表尾部
        s.prev_ = tail_.prev_;
        s.next_ = tail_;
        tail_.prev_.next_ = s;
        tail_.prev_ = s;
        s.linked_ = true;
        return s;
    }

    /// 删除快照
    void deleteSnapshot(Snapshot s) 
    {
        if (s.linked_)
        {
            s.prev_.next_ = s.next_;
            s.next_.prev_ = s.prev_;
            s.linked_ = false;
        }
    }
}
