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
    void delete_(Slice key) 
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
    ///   void delete_(Slice key)
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
                handler.delete_(key);
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
    void delete_(Slice key);
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

    void delete_(Slice key)
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
