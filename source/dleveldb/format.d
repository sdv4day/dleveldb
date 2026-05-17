module dleveldb.format;

import dleveldb.slice;
import dleveldb.coding;
import dleveldb.status;
import dleveldb.crc32c;
import dleveldb.env;

/**
 * 块句柄：指向SSTable中一个数据块的位置
 * 格式：varint64(offset) + varint64(size)
 */
struct BlockHandle
{
    enum ulong kInvalidOffset = ~0UL;

    ulong offset_ = kInvalidOffset;
    ulong size_ = 0;

    bool valid() const pure nothrow @safe @nogc
    {
        return offset_ != kInvalidOffset;
    }

    /// 编码到缓冲区
    void encodeTo(ref ubyte[] dst) const
    {
        size_t oldLen = dst.length;
        dst.length = oldLen + varintLength64(offset_) + varintLength64(size_);
        int n = encodeVarint64(dst.ptr + oldLen, offset_);
        n += encodeVarint64(dst.ptr + oldLen + n, size_);
        dst.length = oldLen + n;
    }

    /// 从Slice解码
    Status decodeFrom(ref Slice input)
    {
        const(ubyte)* ptr = input.data();
        const(ubyte)* limit = ptr + input.size();

        if (!decodeVarint64(ptr, limit, offset_))
            return statusCorruption("bad block handle offset");
        if (!decodeVarint64(ptr, limit, size_))
            return statusCorruption("bad block handle size");

        input = Slice(ptr, limit - ptr);
        return Status();
    }

    /// 编码后的最大长度
    enum int kMaxEncodedLength = 10 + 10; // varint64最大10字节
}

/**
 * SSTable尾部
 * 格式：metaindex_handle + index_handle + padding + magic(8字节)
 */
struct Footer
{
    // 魔数：0xdb4775248b80fb57
    enum ulong kTableMagicNumber = 0xdb4775248b80fb57UL;
    enum int kEncodedLength = 2 * BlockHandle.kMaxEncodedLength + 8;

    BlockHandle metaindexHandle;
    BlockHandle indexHandle;

    /// 编码到缓冲区
    void encodeTo(ref ubyte[] dst) const
    {
        size_t start = dst.length;

        // 编码metaindex_handle和index_handle
        metaindexHandle.encodeTo(dst);
        indexHandle.encodeTo(dst);

        // 填充到kEncodedLength - 8
        size_t paddingLen = start + kEncodedLength - 8 - dst.length;
        dst.length = dst.length + paddingLen;
        // padding已经是0

        // 写入魔数
        dst.length = start + kEncodedLength;
        encodeFixed64(dst.ptr + dst.length - 8, kTableMagicNumber);
    }

    /// 从Slice解码
    Status decodeFrom(Slice input)
    {
        if (input.size() < kEncodedLength)
            return statusCorruption("footer too small");

        // 检查魔数
        ulong magic = decodeFixed64(input.data() + input.size() - 8);
        if (magic != kTableMagicNumber)
            return statusCorruption("footer magic mismatch");

        // 解码metaindex_handle和index_handle
        Slice buf = Slice(input.data() + input.size() - kEncodedLength, kEncodedLength - 8);

        Status s = metaindexHandle.decodeFrom(buf);
        if (!s.ok())
            return s;

        s = indexHandle.decodeFrom(buf);
        if (!s.ok())
            return s;

        return Status();
    }
}

/**
 * 块内容
 */
struct BlockContents
{
    Slice data;           // 块数据
    bool cachable;        // 是否可缓存
    bool heapAllocated;   // 是否在堆上分配（需要释放）
}

/**
 * 块类型
 */
enum BlockType : ubyte
{
    noCompression = 0,
    compressed = 1,
}

/// 读取并解压一个块
Status readBlock(RandomAccessFile file, ulong fileSize, BlockHandle handle, ref BlockContents result)
{
    import dleveldb.env : RandomAccessFile;

    if (handle.offset_ > fileSize)
        return statusCorruption("block offset past end of file");
    if (handle.offset_ + handle.size_ > fileSize)
        return statusCorruption("block extends past end of file");

    // 读取块数据 + trailer(5字节)
    size_t n = cast(size_t) handle.size_ + 5; // type(1) + crc(4)
    ubyte[] buf;
    buf.length = n;

    Slice data;
    Status s = file.read(handle.offset_, n, data, buf);
    if (!s.ok())
        return s;

    if (data.size() != n)
        return statusCorruption("truncated block read");

    // 检查CRC
    ubyte type = data.data()[n - 5];
    uint expectedCrc = decodeFixed32(data.data() + n - 4);
    uint actualCrc = crc32cValue(data.data(), n - 5);
    if (actualCrc != expectedCrc)
        return statusCorruption("block checksum mismatch");

    // 根据类型处理
    Slice blockData = Slice(data.data(), cast(size_t) handle.size_);
    if (type == cast(ubyte) BlockType.noCompression)
    {
        result.data = blockData;
        result.cachable = false;
        result.heapAllocated = false;
    }
    else
    {
        // 解压（简化实现：暂不支持压缩块）
        result.data = blockData;
        result.cachable = false;
        result.heapAllocated = false;
    }

    return Status();
}
