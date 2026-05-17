module dleveldb.db;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.iterator;
import dleveldb.write_batch;
import dleveldb.snapshot;
import dleveldb.comparator;
import dleveldb.env;

/**
 * DB抽象接口
 * 提供键值存储的核心操作
 */
interface DB
{
    /// 打开数据库
    /// dbname: 数据库目录路径
    /// options: 配置选项
    /// db: 输出数据库实例
    static Status open(Options options, string dbname, out DB db)
    {
        import dleveldb.db_impl : DBImpl;
        auto impl = new DBImpl(options, dbname);
        Status s = impl.open();
        if (s.ok())
        {
            db = impl;
        }
        else
        {
            db = null;
        }
        return s;
    }

    /// 关闭数据库
    abstract void close();

    /// 写入键值对
    abstract Status put(WriteOptions options, Slice key, Slice value);

    /// 删除键
    abstract Status delete_(WriteOptions options, Slice key);

    /// 原子写批次
    abstract Status write(WriteOptions options, WriteBatch updates);

    /// 读取键
    abstract Status get(ReadOptions options, Slice key, ref ubyte[] value);

    /// 创建迭代器
    abstract Iterator newIterator(ReadOptions options);

    /// 获取快照
    abstract const(Snapshot) getSnapshot();

    /// 释放快照
    abstract void releaseSnapshot(const(Snapshot) snapshot);

    /// 压缩指定范围
    abstract void compactRange(Slice begin, Slice end);
}
