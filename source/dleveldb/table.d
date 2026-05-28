module dleveldb.table;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.format;
import dleveldb.block;
import dleveldb.filter_block;
import dleveldb.coding;
import dleveldb.comparator;
import dleveldb.env;

/**
 * SSTable读取器
 * 从文件打开SSTable，提供读取和迭代功能
 */
class Table
{
private:
    Options options_;
    RandomAccessFile file_;
    ulong fileSize_;
    BlockHandle indexHandle_;
    Block indexBlock_;
    FilterBlockReader filterBlock_;
    ulong tableNumber_;
    bool closed_;

public:
    /// 构造SSTable读取器
    ///
    /// Params:
    ///     options = 读取选项
    ///     file = 随机访问文件
    ///     fileSize = 文件大小
    ///     tableNumber = 表编号
    this(Options options, RandomAccessFile file, ulong fileSize, ulong tableNumber)
    {
        options_ = options;
        file_ = file;
        fileSize_ = fileSize;
        tableNumber_ = tableNumber;
        closed_ = false;
    }

    /// 析构函数，释放资源并关闭文件句柄
    ~this()
    {
        close();
    }

    /// 显式释放资源（关闭文件句柄）
    void close()
    {
        if (closed_) return;
        closed_ = true;

        if (file_ !is null)
        {
            auto fraf = cast(FileRandomAccessFile) file_;
            if (fraf !is null)
            {
                import dleveldb.env : FileRandomAccessFile;
                destroy(fraf);
            }
            file_ = null;
        }
        indexBlock_ = null;
        filterBlock_ = null;
    }

    /// 打开SSTable
    Status open() 
    {
        // 读取Footer
        if (fileSize_ < Footer.kEncodedLength)
            return statusCorruption("file too small to be an sstable");

        ubyte[Footer.kEncodedLength] footerBuf;
        Slice footerData;
        Status s = file_.read(fileSize_ - Footer.kEncodedLength,
            Footer.kEncodedLength, footerData, footerBuf);
        if (!s.ok())
            return s;

        Footer footer;
        s = footer.decodeFrom(footerData);
        if (!s.ok())
            return s;

        indexHandle_ = footer.indexHandle;

        // 读取索引块
        BlockContents indexContents;
        s = readBlock(file_, fileSize_, indexHandle_, indexContents);
        if (!s.ok())
            return s;

        indexBlock_ = new Block(indexContents.data);

        // 读取metaindex块以获取过滤器
        BlockContents metaindexContents;
        s = readBlock(file_, fileSize_, footer.metaindexHandle, metaindexContents);
        if (s.ok())
        {
            readFilterBlock(metaindexContents);
        }

        return Status();
    }

    /// 在表中查找键
    /// 使用布隆过滤器加速
    Status get(ReadOptions options, Slice key, ref ubyte[] value) 
    {
        // 使用索引块查找
        auto indexIter = indexBlock_.iterator(options_.comparator);
        indexIter.seek(key);

        if (indexIter.valid())
        {
            // 解码BlockHandle
            Slice handleData = indexIter.value();
            BlockHandle handle;
            Slice input = handleData;
            Status s = handle.decodeFrom(input);
            if (!s.ok())
                return s;

            // 检查过滤器
            if (filterBlock_ !is null)
            {
                if (!filterBlock_.keyMayMatch(cast(uint) handle.offset_, key))
                {
                    // 过滤器排除，键不存在
                    return statusNotFound("");
                }
            }

            // 读取数据块
            BlockContents blockContents;
            s = readBlock(file_, fileSize_, handle, blockContents);
            if (!s.ok())
                return s;

            Block dataBlock = new Block(blockContents.data);
            auto iter = dataBlock.iterator(options_.comparator);
            iter.seek(key);

            if (iter.valid() && options_.comparator.compare(iter.key(), key) == 0)
            {
                Slice val = iter.value();
                value.length = val.size();
                for (size_t i = 0; i < val.size(); i++)
                    value[i] = val.data()[i];
                return Status();
            }
        }

        return statusNotFound("");
    }

    /// 获取索引块迭代器
    BlockIter indexIterator() 
    {
        return indexBlock_.iterator(options_.comparator);
    }

    /// 获取文件
    RandomAccessFile file()  @nogc { return file_; }

    /// 获取文件大小
    ulong fileSize() const pure @safe @nogc { return fileSize_; }

    /// 获取表编号
    ulong tableNumber() const pure @safe @nogc { return tableNumber_; }

    /// 获取过滤器
    FilterBlockReader filterBlock()  @nogc { return filterBlock_; }

private:
    /// 从metaindex块读取过滤器
    void readFilterBlock(BlockContents metaindex) 
    {
        if (options_.filterPolicy is null)
            return;

        Block metaBlock = new Block(metaindex.data);
        auto iter = metaBlock.iterator(options_.comparator);

        Slice filterName = Slice("filter." ~ options_.filterPolicy.name());
        iter.seek(filterName);

        if (iter.valid() && iter.key() == filterName)
        {
            // 解码过滤器BlockHandle
            Slice handleData = iter.value();
            BlockHandle handle;
            Slice input = handleData;
            if (handle.decodeFrom(input).ok())
            {
                BlockContents filterContents;
                if (readBlock(file_, fileSize_, handle, filterContents).ok())
                {
                    filterBlock_ = new FilterBlockReader(options_.filterPolicy, filterContents.data);
                }
            }
        }
    }
}
