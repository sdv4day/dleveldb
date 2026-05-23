module dleveldb.write_batch;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.dbformat;
import dleveldb.coding;
import dleveldb.memtable;

/**
 * WriteBatch：原子写批次
 * 将多个Put/Delete操作打包为一次原子写入
 * 
 * 内部格式：
 *   sequence_number: uint64 (8 bytes)
 *   count: int32 (4 bytes)
 *   entries: repeated {
 *     type: uint8 (1 byte)
 *     if kTypeValue:
 *       key_length: varint32
 *       key: char[key_length]
 *       value_length: varint32
 *       value: char[value_length]
 *     if kTypeDeletion:
 *       key_length: varint32
 *       key: char[key_length]
 *   }
 */
class WriteBatch
{
private:
    ubyte[] rep_;

public:
    this()
    {
        // 初始化：8字节序列号 + 4字节计数
        rep_.length = ulong.sizeof + uint.sizeof;
        rep_[] = 0;
    }

    /// 获取内部表示
    ubyte[] rep()  @nogc { return rep_; }

    /// 获取/设置序列号
    ulong sequence() const 
    {
        return decodeFixed64(rep_.ptr);
    }

    void setSequence(ulong seq)  @nogc
    {
        encodeFixed64(rep_.ptr, seq);
    }

    /// 获取操作计数
    int count() const 
    {
        return cast(int) decodeFixed32(rep_.ptr + ulong.sizeof);
    }

    void setCount(int c)  @nogc
    {
        encodeFixed32(rep_.ptr + ulong.sizeof, cast(uint) c);
    }

    /// 添加Put操作
    void put(Slice key, Slice value) 
    {
        setCount(count() + 1);
        rep_ ~= cast(ubyte) ValueType.value;
        appendSlice(key);
        appendSlice(value);
    }

    /// 添加Delete操作
    void remove(Slice key) 
    {
        setCount(count() + 1);
        rep_ ~= cast(ubyte) ValueType.deletion;
        appendSlice(key);
    }

    /// 清空
    void clear() pure nothrow @safe
    {
        rep_.length = ulong.sizeof + uint.sizeof;
        rep_[] = 0;
    }

    /// 追加另一个WriteBatch
    void append(WriteBatch other) 
    {
        assert(other.sequence() == 0);
        setCount(count() + other.count());
        rep_ ~= other.rep_[ulong.sizeof + uint.sizeof .. $];
    }

    /// 迭代器接口：遍历WriteBatch中的所有操作
    /// handler: 接收每个操作的回调
    ///   void put(Slice key, Slice value)
    ///   void remove(Slice key)
    Status iterate(WriteBatchHandler handler) 
    {
        Slice input = Slice(rep_.ptr, rep_.length);
        const(ubyte)* ptr = input.data();
        const(ubyte)* limit = ptr + input.size();

        if (ptr + ulong.sizeof + uint.sizeof > limit)
            return statusCorruption("malformed WriteBatch (too small)");

        ptr += ulong.sizeof + uint.sizeof; // 跳过header

        while (ptr < limit)
        {
            ubyte tag = *ptr;
            ptr++;

            if (tag == cast(ubyte) ValueType.value)
            {
                Slice key, value;
                if (!getLengthPrefixedSlice(ptr, limit, key))
                    return statusCorruption("bad WriteBatch Put");
                if (!getLengthPrefixedSlice(ptr, limit, value))
                    return statusCorruption("bad WriteBatch Put");
                handler.put(key, value);
            }
            else if (tag == cast(ubyte) ValueType.deletion)
            {
                Slice key;
                if (!getLengthPrefixedSlice(ptr, limit, key))
                    return statusCorruption("bad WriteBatch Delete");
                handler.remove(key);
            }
            else
            {
                return statusCorruption("unknown WriteBatch tag");
            }
        }

        return Status();
    }

private:
    /// 追加Slice（varint32长度 + 数据）
    void appendSlice(Slice s) 
    {
        int varintLen = varintLength(cast(uint) s.size());
        size_t oldLen = rep_.length;
        rep_.length = oldLen + varintLen + s.size();
        encodeVarint32(rep_.ptr + oldLen, cast(uint) s.size());
        if (s.size() > 0)
        {
            // 使用D标准数组切片拷贝替代memcpy
            rep_[oldLen + varintLen .. oldLen + varintLen + s.size()] = s.asBytes();
        }
    }
}

/**
 * WriteBatch处理器接口
 */
interface WriteBatchHandler
{
    void put(Slice key, Slice value);
    void remove(Slice key);
}

/**
 * 将WriteBatch插入到MemTable
 */
class MemTableInserter : WriteBatchHandler
{
private:
    ulong sequence_;
    MemTable mem_;

public:
    this(ulong seq, MemTable mem)
    {
        sequence_ = seq;
        mem_ = mem;
    }

    void put(Slice key, Slice value)
    {
        mem_.add(sequence_, ValueType.value, key, value);
        sequence_++;
    }

    void remove(Slice key)
    {
        mem_.add(sequence_, ValueType.deletion, key, Slice());
        sequence_++;
    }
}

/// 将WriteBatch插入到MemTable
Status insertIntoMemTable(WriteBatch batch, MemTable mem) 
{
    auto inserter = new MemTableInserter(batch.sequence(), mem);
    return batch.iterate(inserter);
}

///
unittest
{
    // 空 WriteBatch
    auto batch = new WriteBatch();
    assert(batch.count() == 0);
    assert(batch.sequence() == 0);

    // 添加 Put 操作
    batch.put(Slice("key1"), Slice("value1"));
    assert(batch.count() == 1);
    batch.put(Slice("key2"), Slice("value2"));
    assert(batch.count() == 2);

    // 添加 Delete 操作
    batch.remove(Slice("key3"));
    assert(batch.count() == 3);

    // 设置序列号
    batch.setSequence(100);
    assert(batch.sequence() == 100);

    // iterate 回调验证
    class TestHandler : WriteBatchHandler
    {
        int putCount = 0;
        int delCount = 0;
        string lastPutKey;
        string lastPutValue;
        string lastDelKey;

        void put(Slice key, Slice value)
        {
            putCount++;
            lastPutKey = key.asString().idup;
            lastPutValue = value.asString().idup;
        }

        void remove(Slice key)
        {
            delCount++;
            lastDelKey = key.asString().idup;
        }
    }

    auto handler = new TestHandler();
    auto status = batch.iterate(handler);
    assert(status.ok());
    assert(handler.putCount == 2);
    assert(handler.delCount == 1);
    assert(handler.lastDelKey == "key3");

    // clear
    batch.clear();
    assert(batch.count() == 0);
    assert(batch.sequence() == 0);

    // append
    auto b1 = new WriteBatch();
    b1.put(Slice("a"), Slice("1"));
    auto b2 = new WriteBatch();
    b2.put(Slice("b"), Slice("2"));
    b2.remove(Slice("c"));
    b1.append(b2);
    assert(b1.count() == 3);
}
