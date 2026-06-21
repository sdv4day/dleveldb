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
 * 使用简单的哈希表实现，淘汰时自动关闭文件句柄
 */
class TableCache
{
private:
    string dbname_;
    Options options_;
    Env env_;
    int maxOpenFiles_;

    Table[ulong] cache_;       // 文件编号 -> Table
    ulong[] lruOrder_;         // LRU顺序，用于淘汰
    Mutex mutex_;
    bool closed_;

public:
    this(string dbname, Options options, int maxOpenFiles)
    {
        dbname_ = dbname;
        options_ = options;
        env_ = options.env;
        maxOpenFiles_ = maxOpenFiles;
        mutex_ = new Mutex;
        closed_ = false;
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    /// 显式关闭所有缓存的Table，释放文件句柄
    void close()
    {
        if (closed_) return;
        closed_ = true;

        synchronized (mutex_)
        {
            // 关闭所有Table
            foreach (fileNumber, table; cache_)
            {
                if (table !is null)
                    table.close();
            }
            cache_.destroy();
            cache_ = null;
            lruOrder_ = null;
        }
    }

    /// 在指定表中查找
    Status get(ReadOptions options, ulong fileNumber, ulong fileSize,
        Slice key, ref ubyte[] value)
    {
        Table table;
        Status s = findTable(fileNumber, fileSize, table);
        if (!s.ok())
            return s;

        return table.get(options, key, value);
    }

    /// 驱逐指定表的缓存
    void evict(ulong fileNumber)
    {
        synchronized (mutex_)
        {
            auto pfileNumber = fileNumber in cache_;
            if (pfileNumber !is null)
            {
                Table table = *pfileNumber;
                cache_.remove(fileNumber);

                // 从LRU顺序中移除
                for (size_t i = 0; i < lruOrder_.length; i++)
                {
                    if (lruOrder_[i] == fileNumber)
                    {
                        lruOrder_ = lruOrder_[0 .. i] ~ lruOrder_[i + 1 .. $];
                        break;
                    }
                }

                if (table !is null)
                    table.close();
            }
        }
    }

    /// 创建指定表的迭代器
    Iterator newIterator(ReadOptions options, ulong fileNumber, ulong fileSize)
    {
        Table table;
        Status s = findTable(fileNumber, fileSize, table);
        if (!s.ok())
        {
            return new EmptyIterator(s);
        }

        // 创建两级迭代器：索引块 -> 数据块
        Iterator indexIter = table.indexIterator();

        // 将table引用复制到堆上，避免闭包捕获栈变量
        Table tableRef = table;

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
            s = readBlock(tableRef.file(), tableRef.fileSize(), handle, blockContents);
            if (!s.ok())
            {
                return new EmptyIterator(s);
            }

            Block dataBlock = new Block(blockContents.data);
            return dataBlock.iterator(tableRef.internalComparator());
        }

        return newTwoLevelIterator(indexIter, &blockFunc);
    }

private:
    /// 查找或打开表，返回Status以保留原始错误信息
    Status findTable(ulong fileNumber, ulong fileSize, out Table result)
    {
        result = null;
        synchronized (mutex_)
        {
            // 先在缓存中查找
            auto pfileNumber = fileNumber in cache_;
            if (pfileNumber !is null)
            {
                result = *pfileNumber;
                // 更新LRU顺序：移到末尾
                for (size_t i = 0; i < lruOrder_.length; i++)
                {
                    if (lruOrder_[i] == fileNumber)
                    {
                        lruOrder_ = lruOrder_[0 .. i] ~ lruOrder_[i + 1 .. $] ~ fileNumber;
                        break;
                    }
                }
                return Status();
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
                    return s;
            }

            Table table = new Table(options_, file, fileSize, fileNumber);
            s = table.open();
            if (!s.ok())
                return s;

            // 添加到缓存
            cache_[fileNumber] = table;
            lruOrder_ ~= fileNumber;

            // 淘汰最旧的条目
            while (cast(int) cache_.length > maxOpenFiles_ - 10 && lruOrder_.length > 0)
            {
                ulong oldest = lruOrder_[0];
                lruOrder_ = lruOrder_[1 .. $];
                auto pOldest = oldest in cache_;
                if (pOldest !is null)
                {
                    Table oldTable = *pOldest;
                    cache_.remove(oldest);
                    if (oldTable !is null)
                        oldTable.close();
                }
            }

            result = table;
            return Status();
        }
    }
}
