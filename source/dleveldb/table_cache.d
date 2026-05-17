module dleveldb.table_cache;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.table;
import dleveldb.env;
import dleveldb.filename;
import dleveldb.format;
import dleveldb.comparator;
import dleveldb.iterator;
import dleveldb.two_level_iterator;
import dleveldb.block;

import core.sync.mutex;

/**
 * SSTable文件缓存
 * 缓存已打开的Table对象，避免重复打开文件
 */
class TableCache
{
private:
    string dbname_;
    Options options_;
    Env env_;
    int maxOpenFiles_;

    // 简化实现：使用数组存储已打开的表
    // 生产实现应使用LRU缓存
    Table[] tables_;
    ulong[] tableNumbers_;
    Mutex mutex_;

public:
    this(string dbname, Options options, int maxOpenFiles)
    {
        dbname_ = dbname;
        options_ = options;
        env_ = options.env;
        maxOpenFiles_ = maxOpenFiles;
        mutex_ = new Mutex;
    }

    ~this()
    {
        foreach (t; tables_)
        {
            // Table对象由GC回收
        }
    }

    /// 在指定表中查找
    Status get(ReadOptions options, ulong fileNumber, ulong fileSize,
        Slice key, ref ubyte[] value) 
    {
        Table table = findTable(fileNumber, fileSize);
        if (table is null)
            return statusIoError("table not found");

        return table.get(options, key, value);
    }

    /// 驱逐指定表的缓存（Table对象由GC回收，文件句柄在析构中关闭）
    void evict(ulong fileNumber) 
    {
        synchronized (mutex_)
        {
            for (size_t i = 0; i < tableNumbers_.length; i++)
            {
                if (tableNumbers_[i] == fileNumber)
                {
                    // 移除
                    tables_[i] = tables_[$ - 1];
                    tableNumbers_[i] = tableNumbers_[$ - 1];
                    tables_.length = tables_.length - 1;
                    tableNumbers_.length = tableNumbers_.length - 1;
                    return;
                }
            }
        }
    }

    /// 创建指定表的迭代器
    Iterator newIterator(ReadOptions options, ulong fileNumber, ulong fileSize)
    {
        Table table = findTable(fileNumber, fileSize);
        if (table is null)
        {
            return new EmptyIterator(statusIoError("table not found"));
        }

        // 创建两级迭代器：索引块 -> 数据块
        Iterator indexIter = table.indexIterator();

        // blockFunc: 从索引值（BlockHandle）创建数据块迭代器
        Iterator blockFunc(Slice handleSlice)
        {
            BlockHandle handle;
            Slice input = handleSlice;
            Status s = handle.decodeFrom(input);
            if (!s.ok())
            {
                return new EmptyIterator(s);
            }

            BlockContents blockContents;
            s = readBlock(table.file(), table.fileSize(), handle, blockContents);
            if (!s.ok())
            {
                return new EmptyIterator(s);
            }

            Block dataBlock = new Block(blockContents.data);
            return dataBlock.iterator(options_.comparator);
        }

        return newTwoLevelIterator(indexIter, &blockFunc);
    }

private:
    /// 查找或打开表
    Table findTable(ulong fileNumber, ulong fileSize) 
    {
        synchronized (mutex_)
        {
            // 先在缓存中查找
            for (size_t i = 0; i < tableNumbers_.length; i++)
            {
                if (tableNumbers_[i] == fileNumber)
                {
                    return tables_[i];
                }
            }

            // 打开新表
            string fname = tableFileName(dbname_, fileNumber);
            RandomAccessFile file;
            Status s = env_.newRandomAccessFile(fname, file);
            if (!s.ok())
            {
                // 尝试.sst后缀
                fname = sstTableFileName(dbname_, fileNumber);
                s = env_.newRandomAccessFile(fname, file);
                if (!s.ok())
                    return null;
            }

            Table table = new Table(options_, file, fileSize, fileNumber);
            s = table.open();
            if (!s.ok())
                return null;

            // 添加到缓存
            tables_ ~= table;
            tableNumbers_ ~= fileNumber;

            // 简单的缓存淘汰
            if (cast(int) tables_.length > maxOpenFiles_ - 10)
            {
                // 移除最旧的，Table对象由GC回收（文件句柄在析构中关闭）
                tables_ = tables_[1 .. $];
                tableNumbers_ = tableNumbers_[1 .. $];
            }

            return table;
        }
    }
}
