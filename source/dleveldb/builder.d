module dleveldb.builder;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.table_builder;
import dleveldb.dbformat;
import dleveldb.version_edit;
import dleveldb.version_set;
import dleveldb.compression_filter;
import dleveldb.env;
import dleveldb.filename;
import dleveldb.iterator;

/**
 * 从迭代器构建SSTable
 * 将MemTable或压缩输入的数据写入新的SSTable文件
 */
Status buildTable(string dbname, Env env, Options options,
    Iterator iter, ref FileMetaData metaData, VersionSet versions)
{
    if (!iter.valid())
    {
        iter.seekToFirst();
    }
    if (!iter.valid())
    {
        metaData.number = 0;
        metaData.fileSize = 0;
        return Status();
    }

    // 从VersionSet分配文件编号
    ulong fileNumber = versions.newFileNumber();
    string fname = tableFileName(dbname, fileNumber);

    // 创建文件
    WritableFile file;
    Status s = env.newWritableFile(fname, file);
    if (!s.ok())
        return s;

    // 构建SSTable（使用内部键比较器确保有序性）
    auto icmp = new InternalKeyComparator(options.comparator);
    auto builder = new TableBuilder(options, file, icmp);

    // 使用第一个键作为 smallest（直接使用 InternalKey，保留原始序列号和类型）
    Slice firstKey = iter.key();
    metaData.smallest = InternalKey(firstKey);
    
    while (iter.valid())
    {
        Slice key = iter.key();
        Slice value = iter.value();

        // 检查压缩过滤器
        if (options.compressionFilter !is null)
        {
            Slice newValue;
            auto result = options.compressionFilter.filter(
                extractUserKey(key), value, newValue);
            if (result == CompressionFilterResult.remove)
            {
                iter.next();
                continue;
            }
            else if (result == CompressionFilterResult.change)
            {
                value = newValue;
            }
        }

        builder.add(key, value);
        // 更新 largest 为当前键（直接使用 InternalKey，保留原始序列号和类型）
        metaData.largest = InternalKey(key);
        iter.next();
    }

    s = builder.finish();
    if (s.ok())
    {
        metaData.number = fileNumber;
        metaData.fileSize = builder.fileSize();
    }

    if (s.ok())
    {
        s = file.sync();
    }
    if (s.ok())
    {
        s = file.close();
    }

    if (!s.ok())
    {
        env.removeFile(fname);
    }

    return s;
}
