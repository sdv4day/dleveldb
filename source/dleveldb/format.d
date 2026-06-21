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
    enum int kEncodedLength = 2 * BlockHandle.kMaxEncodedLength + ulong.sizeof;

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
        size_t paddingLen = start + kEncodedLength - ulong.sizeof - dst.length;
        dst.length = dst.length + paddingLen;
        // padding已经是0

        // 写入魔数
        dst.length = start + kEncodedLength;
        encodeFixed64(dst.ptr + dst.length - ulong.sizeof, kTableMagicNumber);
    }

    /// 从Slice解码
    Status decodeFrom(Slice input)
    {
        if (input.size() < kEncodedLength)
            return statusCorruption("footer too small");

        // 检查魔数
        ulong magic = decodeFixed64(input.data() + input.size() - ulong.sizeof);
        if (magic != kTableMagicNumber)
            return statusCorruption("footer magic mismatch");

        // 解码metaindex_handle和index_handle
        Slice buf = Slice(input.data() + input.size() - kEncodedLength, kEncodedLength - ulong.sizeof);

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
/// 结果数据通过 .dup 复制到 GC 管理的堆内存，确保 Slice 生命周期安全
Status readBlock(RandomAccessFile file, ulong fileSize, BlockHandle handle, ref BlockContents result)
{
    import dleveldb.env : RandomAccessFile;

    if (handle.offset_ > fileSize)
        return statusCorruption("block offset past end of file");
    if (handle.offset_ + handle.size_ > fileSize)
        return statusCorruption("block extends past end of file");

    // 读取块数据 + trailer(5字节)
    size_t n = cast(size_t) handle.size_ + 1 + uint.sizeof; // type(1) + crc(4)
    ubyte[] buf;
    buf.length = n;

    Slice data;
    Status s = file.read(handle.offset_, n, data, buf);
    if (!s.ok())
        return s;

    if (data.size() != n)
        return statusCorruption("truncated block read");

    // 检查CRC（注意：写入端 CRC = crc32c(type || block_contents)，type 在 block_contents 之后，
    // 在内存中是 [block_contents][type]，因此需要先计算 type 的 CRC，再 extend block_contents）
    ubyte type = data.data()[n - 1 - uint.sizeof];
    uint expectedCrc = decodeFixed32(data.data() + n - uint.sizeof);
    uint actualCrc = crc32cValue(&type, 1);
    actualCrc = crc32cExtend(actualCrc, data.data(), n - 1 - uint.sizeof);
    if (actualCrc != expectedCrc)
        return statusCorruption("block checksum mismatch");

    // 将块数据 .dup 到 GC 管理的堆内存，确保 Slice 引用安全
    // buf 是函数局部变量，函数返回后 GC 可能回收，必须复制
    ubyte[] blockBuf = new ubyte[cast(size_t) handle.size_];
    blockBuf[] = data.data()[0 .. cast(size_t) handle.size_];

    if (type == cast(ubyte) BlockType.noCompression)
    {
        result.data = Slice(blockBuf.ptr, blockBuf.length);
        result.cachable = true;
        result.heapAllocated = true;
    }
    else
    {
        // 解压（简化实现：暂不支持压缩块）
        result.data = Slice(blockBuf.ptr, blockBuf.length);
        result.cachable = true;
        result.heapAllocated = true;
    }

    return Status();
}
