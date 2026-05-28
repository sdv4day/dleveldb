module dleveldb.table_builder;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.format;
import dleveldb.block_builder;
import dleveldb.filter_block;
import dleveldb.coding;
import dleveldb.crc32c;
import dleveldb.comparator;
import dleveldb.dbformat;
import dleveldb.compression;
import dleveldb.env;

/**
 * SSTable构建器
 * 
 * 文件格式：
 * [data block 1][data block 2]...[data block N]
 * [meta block 1]...[meta block K]
 * [metaindex block]
 * [index block]
 * [Footer]
 */
class TableBuilder
{
private:
    Options options_;
    WritableFile file_;
    ulong offset_;
    Status status_;
    BlockBuilder dataBlock_;
    BlockBuilder indexBlock_;
    FilterBlockBuilder filterBlock_;
    Slice lastKey_;
    ulong numEntries_;
    bool closed_;
    bool pendingIndexEntry_;  // 是否有待写入的索引条目
    BlockHandle pendingHandle_; // 上一个数据块的句柄

    InternalKeyComparator icmp_; // 内部键比较器（用于有序性校验）

    // 压缩输出缓冲区
    ubyte[] compressedOutput_;

public:
    /// 构造SSTable构建器
    ///
    /// Params:
    ///     options = 构建选项
    ///     file = 可写文件
    ///     icmp = 内部键比较器
    this(Options options, WritableFile file, InternalKeyComparator icmp)
    {
        options_ = options;
        file_ = file;
        icmp_ = icmp;
        offset_ = 0;
        numEntries_ = 0;
        closed_ = false;
        pendingIndexEntry_ = false;

        dataBlock_ = BlockBuilder(options_.blockRestartInterval);
        indexBlock_ = BlockBuilder(1); // 索引块重启点间隔为1

        if (options_.filterPolicy !is null)
            filterBlock_ = new FilterBlockBuilder(options_.filterPolicy);
    }

    /// 获取当前状态
    Status status() const  { return status_; }

    /// 获取已写入的条目数
    ulong numEntries() const pure @safe @nogc { return numEntries_; }

    /// 获取当前文件偏移
    ulong fileSize() const pure @safe @nogc { return offset_; }

    /// 添加键值对（键必须按升序添加）
    void add(Slice key, Slice value) 
    {
        assert(!closed_);
        if (!status_.ok())
            return;

        if (numEntries_ > 0)
        {
            assert(icmp_.compare(key, lastKey_) > 0);
        }

        if (pendingIndexEntry_)
        {
            // 写入索引条目
            writeIndexEntry(lastKey_, key);
        }

        // 通知过滤器
        if (filterBlock_ !is null)
        {
            filterBlock_.addKey(key);
        }

        lastKey_ = key;
        numEntries_++;
        dataBlock_.add(key, value);

        // 如果数据块超过block_size，刷出
        if (dataBlock_.estimatedSize() >= options_.blockSize)
        {
            flush();
        }
    }

    /// 刷出当前数据块
    void flush() 
    {
        if (!status_.ok())
            return;

        if (dataBlock_.empty())
            return;

        writeBlock(dataBlock_, pendingHandle_);
        pendingIndexEntry_ = true;

        if (filterBlock_ !is null)
        {
            filterBlock_.startBlock(cast(uint) offset_);
        }
    }

    /// 完成SSTable构建
    Status finish() 
    {
        assert(!closed_);
        closed_ = true;

        // 刷出最后一个数据块
        flush();
        if (!status_.ok())
            return status_;

        // 写入过滤器块
        BlockHandle filterBlockHandle;
        if (filterBlock_ !is null && !pendingIndexEntry_)
        {
            // 如果没有数据，不写过滤器
        }
        if (filterBlock_ !is null)
        {
            Slice filterData = filterBlock_.finish();
            writeRawBlock(filterData, BlockType.noCompression, filterBlockHandle);
        }

        // 写入metaindex块
        BlockBuilder metaIndexBlock = BlockBuilder(1);
        if (filterBlock_ !is null && filterBlockHandle.valid())
        {
            // 添加过滤器条目
            Slice filterName = Slice("filter." ~ options_.filterPolicy.name());
            ubyte[] handleEncoding;
            filterBlockHandle.encodeTo(handleEncoding);
            metaIndexBlock.add(filterName, Slice(handleEncoding.ptr, handleEncoding.length));
        }

        BlockHandle metaindexHandle;
        writeBlock(metaIndexBlock, metaindexHandle);

        // 写入索引块
        if (pendingIndexEntry_)
        {
            writeIndexEntry(lastKey_, Slice()); // 空key表示最后一个
        }

        BlockHandle indexHandle;
        writeBlock(indexBlock_, indexHandle);

        // 写入Footer
        Footer footer;
        footer.metaindexHandle = metaindexHandle;
        footer.indexHandle = indexHandle;

        ubyte[] footerEncoding;
        footer.encodeTo(footerEncoding);
        status_ = file_.append(Slice(footerEncoding.ptr, footerEncoding.length));
        if (status_.ok())
        {
            offset_ += footerEncoding.length;
        }

        return status_;
    }

    /// 放弃构建
    void abandon() 
    {
        closed_ = true;
    }

private:
    /// 写入一个块
    void writeBlock(ref BlockBuilder block, ref BlockHandle handle) 
    {
        Slice raw = block.finish();

        // 尝试压缩
        Slice blockContents;
        BlockType type = BlockType.noCompression;

        if (options_.compression != CompressionType.none)
        {
            // 简化实现：暂不压缩
            blockContents = raw;
            type = BlockType.noCompression;
        }
        else
        {
            blockContents = raw;
        }

        writeRawBlock(blockContents, type, handle);
        block.reset();
    }

    /// 写入原始块（带CRC校验）
    void writeRawBlock(Slice blockContents, BlockType type, ref BlockHandle handle) 
    {
        handle.offset_ = offset_;
        handle.size_ = blockContents.size();

        // 写入块数据
        status_ = file_.append(blockContents);
        if (!status_.ok())
            return;
        offset_ += blockContents.size();

        // 写入trailer：type(1) + crc(4)
        ubyte[5] trailer;
        trailer[0] = cast(ubyte) type;

        // CRC = crc32c(type + block_contents)
        uint crc = crc32cValue(trailer.ptr, 1);
        crc = crc32cExtend(crc, blockContents.data(), blockContents.size());
        encodeFixed32(trailer.ptr + 1, crc);

        status_ = file_.append(Slice(trailer.ptr, 5));
        if (status_.ok())
        {
            offset_ += 5;
        }
    }

    /// 写入索引条目
    void writeIndexEntry(Slice lastKey, Slice nextKey) 
    {
        // 索引键：在lastKey和nextKey之间的短分隔符
        Slice separator = lastKey;
        if (nextKey.size() > 0)
        {
            icmp_.findShortestSeparator(separator, nextKey);
        }
        else
        {
            icmp_.findShortSuccessor(separator);
        }

        // 编码BlockHandle
        ubyte[] handleEncoding;
        pendingHandle_.encodeTo(handleEncoding);

        indexBlock_.add(separator, Slice(handleEncoding.ptr, handleEncoding.length));
        pendingIndexEntry_ = false;
    }
}
