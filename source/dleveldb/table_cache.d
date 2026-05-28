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

    // 使用关联数组实现 O(1) 查找
    // order_ 记录插入顺序，用于容量溢出时 FIFO 淘汰
    Table[ulong] tables_;
    ulong[] order_;
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
            foreach (key, table; tables_)
            {
                if (table !is null)
                {
                    table.close();
                }
            }
            tables_.destroy();
            order_ = null;
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

    /// 驱逐指定表的缓存（evict 操作较罕见，使用线性扫描是合理的）
    void evict(ulong fileNumber) 
    {
        synchronized (mutex_)
        {
            if (auto removed = fileNumber in tables_)
            {
                tables_.remove(fileNumber);
                // 从 order_ 中移除（线性扫描，evict 调用频率低，开销可接受）
                for (size_t i = 0; i < order_.length; i++)
                {
                    if (order_[i] == fileNumber)
                    {
                        order_[i] = order_[$ - 1];
                        order_ = order_[0 .. $ - 1];
                        break;
                    }
                }
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
    /// 查找或打开表，返回Status以保留原始错误信息
    Status findTable(ulong fileNumber, ulong fileSize, out Table result) 
    {
        result = null;
        synchronized (mutex_)
        {
            // 先在缓存中查找（O(1) 关联数组）
            if (auto t = fileNumber in tables_)
            {
                result = *t;
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

            // 添加到缓存（O(1) 关联数组）
            tables_[fileNumber] = table;
            order_ ~= fileNumber;

            // 简单的缓存淘汰
            if (cast(int) tables_.length > maxOpenFiles_ - 10)
            {
                // 移除最旧的（FIFO）
                ulong oldest = order_[0];
                tables_.remove(oldest);
                order_ = order_[1 .. $];
            }

            result = table;
            return Status();
        }
    }
}
