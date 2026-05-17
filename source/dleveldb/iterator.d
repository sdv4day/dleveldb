module dleveldb.iterator;

import dleveldb.slice;
import dleveldb.status;

/**
 * 迭代器抽象接口
 */
interface Iterator
{
    bool valid() const nothrow @nogc;
    void seekToFirst();
    void seekToLast();
    void seek(Slice target);
    void next();
    void prev();
    Slice key() nothrow @nogc;
    Slice value() nothrow @nogc;
    Status status() const nothrow @nogc;
}

/**
 * 空迭代器
 */
class EmptyIterator : Iterator
{
private:
    Status status_;

public:
    this() {}
    this(Status s) { status_ = s; }

    bool valid() const pure nothrow @safe @nogc { return false; }
    void seekToFirst() nothrow @nogc {}
    void seekToLast() nothrow @nogc {}
    void seek(Slice target) nothrow @nogc {}
    void next() nothrow @nogc { assert(false, "EmptyIterator::next"); }
    void prev() nothrow @nogc { assert(false, "EmptyIterator::prev"); }
    Slice key() nothrow @nogc { assert(false, "EmptyIterator::key"); return Slice(); }
    Slice value() nothrow @nogc { assert(false, "EmptyIterator::value"); return Slice(); }
    Status status() const nothrow @nogc { return status_; }
}
