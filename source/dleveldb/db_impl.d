module dleveldb.db_impl;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.options;
import dleveldb.dbformat;
import dleveldb.memtable;
import dleveldb.write_batch;
import dleveldb.version_set;
import dleveldb.version_edit;
import dleveldb.table_cache;
import dleveldb.log_writer;
import dleveldb.log_reader;
import dleveldb.log_format;
import dleveldb.snapshot;
import dleveldb.iterator;
import dleveldb.merger;
import dleveldb.db_iter;
import dleveldb.comparator;
import dleveldb.env;
import dleveldb.filename;
import dleveldb.coding;
import std.path : buildPath;
import dleveldb.key_filter;
import dleveldb.compression_filter;
import dleveldb.builder;
import dleveldb.table_builder;

import core.sync.mutex;
import core.sync.condition;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;

/**
 * DBImpl：DB的核心实现
 * 
 * 线程模型：
 * - 写入：通过writers_队列串行化，支持组提交
 * - 读取：MemTable和SSTable读取无锁
 * - 压缩：后台线程异步执行
 */
class DBImpl
{
private:
    string dbname_;
    Options options_;
    Env env_;
    Comparator userComparator_;
    InternalKeyComparator icmp_;

    // 状态（受mutex_保护）
    Mutex mutex_;
    Condition backgroundWorkFinishedSignal_;

    MemTable mem_;
    MemTable imm_;     // immutable memtable
    bool hasImm_;      // 在mutex_下访问的标志

    WritableFile logfile_;
    LogWriter log_;
    ulong logfileNumber_;

    VersionSet versions_;
    TableCache tableCache_;

    // 写入队列
    struct Writer
    {
        WriteBatch batch;
        bool sync;
        bool done;
        Status status;
        Condition cond;
    }
    Writer*[] writers_;

    // 后台压缩
    bool backgroundCompactionScheduled_;
    Status bgError_;

    // 关闭标志
    bool shuttingDown_;

    // 快照
    SnapshotList snapshots_;

    // 序列号
    ulong lastSequence_;

    // 正在生成的输出文件
    ulong[] pendingOutputs_;

    // 统计
    ulong[2] stats_; // [0]=read, [1]=seek

public:
    this(Options options, string dbname)
    {
        dbname_ = dbname;
        options_ = sanitizeOptions(options);
        env_ = options_.env;
        userComparator_ = options_.comparator;
        icmp_ = InternalKeyComparator(userComparator_);

        mutex_ = new Mutex;
        backgroundWorkFinishedSignal_ = new Condition(mutex_);

        mem_ = null;
        imm_ = null;
        hasImm_ = false;
        logfile_ = null;
        log_ = null;
        logfileNumber_ = 0;
        backgroundCompactionScheduled_ = false;
        shuttingDown_ = false;
        lastSequence_ = 0;

        versions_ = null;
        tableCache_ = null;
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    /// 打开数据库
    Status open()
    {
        // 创建数据库目录
        Status s = env_.createDir(dbname_);
        if (!s.ok() && !s.isIoError())
        {
            // 目录可能已存在
        }

        // 创建TableCache
        tableCache_ = new TableCache(dbname_, options_, options_.maxOpenFiles - 10);

        // 创建VersionSet
        versions_ = new VersionSet(dbname_, options_, env_, userComparator_);
        versions_.setTableCache(tableCache_);

        // 从MANIFEST恢复
        s = versions_.recover();
        if (!s.ok())
            return s;

        // 创建新的MemTable
        mem_ = new MemTable(icmp_, options_.allocator);
        mem_.addRef();

        lastSequence_ = versions_.lastSequence();

        // 创建新的WAL日志文件
        logfileNumber_ = versions_.newFileNumber();
        string logName = logFileName(dbname_, logfileNumber_);
        s = env_.newWritableFile(logName, logfile_);
        if (!s.ok())
            return s;

        log_ = new LogWriter(logfile_);

        return Status();
    }

    /// 关闭数据库
    void close()
    {
        if (versions_ is null)
            return;

        synchronized (mutex_)
        {
            shuttingDown_ = true;

            // 等待后台压缩完成
            while (backgroundCompactionScheduled_)
            {
                backgroundWorkFinishedSignal_.wait();
            }
        }

        // 刷新immutable memtable
        if (imm_ !is null)
        {
            compactMemTable();
        }

        // 释放MemTable（在mutex_下操作共享状态）
        synchronized (mutex_)
        {
            if (imm_ !is null)
            {
                imm_.unref();
                imm_ = null;
                hasImm_ = false;
            }
            if (mem_ !is null)
            {
                mem_.unref();
                mem_ = null;
            }
        }

        // 关闭日志文件
        if (logfile_ !is null)
        {
            logfile_.close();
            logfile_ = null;
        }

        log_ = null;

        // 释放版本集资源（关闭MANIFEST文件句柄）
        if (versions_ !is null)
        {
            versions_.closeResources();
            // 手动调用析构函数，确保 current_.unref() 按正确顺序执行
            destroy(versions_);
            versions_ = null;
        }

        // 释放TableCache（关闭缓存的SSTable文件句柄）
        tableCache_ = null;

        // 触发一次GC回收，确保析构函数关闭所有文件句柄
        // 注意：manual refcounting 对象（Version）已在 destroy() 中正确处理，
        // 因此不会出现 GC 终结顺序导致的断言失败
        import core.memory : GC;
        GC.collect();
    }

    /// 写入键值对
    Status put(WriteOptions options, Slice key, Slice value)
    {
        // 检查键过滤器
        if (options_.keyFilter !is null && options_.keyFilter.filter(key))
        {
            return Status(); // 键被过滤，静默跳过
        }

        auto batch = new WriteBatch();
        batch.put(key, value);
        return write(options, batch);
    }

    /// 删除键
    Status delete_(WriteOptions options, Slice key)
    {
        // 检查键过滤器
        if (options_.keyFilter !is null && options_.keyFilter.filter(key))
        {
            return Status(); // 键被过滤，静默跳过
        }

        auto batch = new WriteBatch();
        batch.delete_(key);
        return write(options, batch);
    }

    /// 原子写批次
    Status write(WriteOptions options, WriteBatch updates)
    {
        Writer w;
        w.batch = updates;
        w.sync = options.sync;
        w.done = false;
        w.cond = new Condition(mutex_);

        synchronized (mutex_)
        {
            // 加入写入队列
            writers_ ~= &w;

            // 等待成为队列头部
            while (!w.done && writers_[0] !is &w)
            {
                w.cond.wait();
            }

            if (w.done)
            {
                return w.status;
            }
        }

        // 执行写入
        Status s = writeInternal(w);

        synchronized (mutex_)
        {
            // 标记完成
            w.status = s;
            w.done = true;
            writers_ = writers_[1 .. $];

            // 唤醒下一个写入者
            if (writers_.length > 0)
            {
                writers_[0].cond.notify();
            }
        }

        return s;
    }

    /// 读取键
    Status get(ReadOptions options, Slice key, ref ubyte[] value)
    {
        // 检查键过滤器
        if (options_.keyFilter !is null && options_.keyFilter.filter(key))
        {
            return statusNotFound("");
        }

        MemTable mem, imm;
        Version current;
        ulong sequence;

        synchronized (mutex_)
        {
            // 确定快照序列号
            sequence = (options.snapshot != 0) ?
                options.snapshot : versions_.lastSequence();

            mem = mem_;
            mem.addRef();
            imm = imm_;
            if (imm !is null)
                imm.addRef();
            current = versions_.current();
            current.addRef();
        }

        // 创建查找键
        LookupKey lkey = LookupKey(key, sequence);

        Status s;

        // 1. 查找活跃MemTable
        if (mem.get(lkey, value, s))
        {
            // 找到（包括删除标记）
        }
        else
        {
            // 2. 查找Immutable MemTable
            if (imm !is null && imm.get(lkey, value, s))
            {
                // 找到
            }
            else
            {
                // 3. 查找SSTable层级
                s = current.get(options, lkey, value);
            }
        }

        synchronized (mutex_)
        {
            mem.unref();
            if (imm !is null)
                imm.unref();
            current.unref();
        }

        return s;
    }

    /// 创建迭代器
    Iterator newIterator(ReadOptions options)
    {
        MemTable mem, imm;
        Version current;
        ulong sequence;

        synchronized (mutex_)
        {
            sequence = (options.snapshot != 0) ?
                options.snapshot : versions_.lastSequence();

            mem = mem_;
            mem.addRef();
            imm = imm_;
            if (imm !is null)
                imm.addRef();
            current = versions_.current();
            current.addRef();
        }

        // 收集所有源迭代器
        Iterator[] iters;

        if (imm !is null)
        {
            // 添加Immutable MemTable迭代器
            auto immIter = new MemTableIterator(imm.tablePtr());
            iters ~= immIter;
        }
        if (mem !is null)
        {
            // 添加MemTable迭代器
            auto memIter = new MemTableIterator(mem.tablePtr());
            iters ~= memIter;
        }
        // 添加Version迭代器
        current.addIterators(options, iters);

        // 创建合并迭代器
        Iterator internalIter = newMergingIterator(userComparator_, iters);

        // 包装为用户键迭代器
        Iterator dbIter = newDBIterator(userComparator_, internalIter, sequence);

        // 返回带引用保护的迭代器，析构时释放mem/imm/current引用
        return new DbIteratorWithRefs(dbIter, this, mem, imm, current);
    }

    /// 释放迭代器持有的mem/imm/current引用（在mutex_下调用）
    void releaseIteratorRefs(MemTable mem, MemTable imm, Version current)
    {
        synchronized (mutex_)
        {
            if (mem !is null) mem.unref();
            if (imm !is null) imm.unref();
            if (current !is null) current.unref();
        }
    }

    /// 获取快照
    const(Snapshot) getSnapshot()
    {
        synchronized (mutex_)
        {
            return snapshots_.newSnapshot(versions_.lastSequence());
        }
    }

    /// 释放快照
    void releaseSnapshot(const(Snapshot) snapshot)
    {
        synchronized (mutex_)
        {
            snapshots_.deleteSnapshot(cast(Snapshot) snapshot);
        }
    }

    /// 压缩指定范围
    void compactRange(Slice begin, Slice end)
    {
        // 简化实现：触发后台压缩
        maybeScheduleCompaction();
    }

private:
    /// 内部写入实现
    Status writeInternal(ref Writer w)
    {
        synchronized (mutex_)
        {
            // 确保有空间写入
            Status s = makeRoomForWrite(w.batch is null);

            if (!s.ok())
            {
                return s;
            }

            // 设置序列号
            ulong lastSequence = lastSequence_;
            w.batch.setSequence(lastSequence + 1);
            lastSequence_ += cast(ulong) w.batch.count();

            // 写入WAL
            Slice batchData = Slice(w.batch.rep().ptr, w.batch.rep().length);
            s = log_.addRecord(batchData);
            if (s.ok() && w.sync)
            {
                s = logfile_.sync();
            }

            if (!s.ok())
            {
                // 写入失败，可能需要恢复
                return s;
            }

            // 插入MemTable
            insertIntoMemTable(w.batch, mem_);

            // 更新VersionSet序列号
            versions_.setLastSequence(lastSequence_);
        }

        return Status();
    }

    /// 确保有空间写入
    /// force: 是否强制切换（即使有空间）
    Status makeRoomForWrite(bool force)
    {
        Status s;
        bool allowDelay = !force;

        while (true)
        {
            if (!bgError_.ok())
            {
                return bgError_;
            }

            if (allowDelay && versions_.current().numLevelFiles(0) >= kL0_SlowdownWritesTrigger)
            {
                // L0文件过多，延迟写入
                env_.sleepForMicroseconds(1000);
                allowDelay = false;
            }
            else if (mem_.approximateMemoryUsage() <= options_.writeBufferSize)
            {
                // 有空间
                break;
            }
            else if (imm_ !is null)
            {
                // 等待immutable memtable压缩完成
                backgroundWorkFinishedSignal_.wait();
            }
            else if (versions_.current().numLevelFiles(0) >= kL0_StopWritesTrigger)
            {
                // L0文件过多，停止写入
                backgroundWorkFinishedSignal_.wait();
            }
            else
            {
                // 切换MemTable
                ulong newLogNumber = versions_.newFileNumber();
                string logName = logFileName(dbname_, newLogNumber);

                WritableFile newLogFile;
                s = env_.newWritableFile(logName, newLogFile);
                if (!s.ok())
                    return s;

                // 关闭旧日志
                if (logfile_ !is null)
                {
                    logfile_.close();
                }

                logfile_ = newLogFile;
                logfileNumber_ = newLogNumber;
                log_ = new LogWriter(logfile_);

                // 切换MemTable
                imm_ = mem_;
                hasImm_ = true;
                mem_ = new MemTable(icmp_, options_.allocator);
                mem_.addRef();

                // 触发压缩
                maybeScheduleCompaction();
            }
        }

        return Status();
    }

    /// 可能调度后台压缩
    void maybeScheduleCompaction()
    {
        synchronized (mutex_)
        {
            if (backgroundCompactionScheduled_)
            {
                // 已有压缩在执行
            }
            else if (shuttingDown_)
            {
                // 正在关闭
            }
            else if (bgError_.ok() && (imm_ !is null ||
                versions_.current().compactionScore() >= 1))
            {
                // 需要压缩
                backgroundCompactionScheduled_ = true;

                // 在后台线程执行压缩
                env_.schedule({
                    backgroundCall();
                });
            }
        }
    }

    /// 后台压缩入口
    void backgroundCall()
    {
        synchronized (mutex_)
        {
            assert(backgroundCompactionScheduled_);

            if (!shuttingDown_ && bgError_.ok())
            {
                Status s = backgroundCompaction();
                if (!s.ok())
                {
                    bgError_ = s;
                }
            }

            backgroundCompactionScheduled_ = false;
            backgroundWorkFinishedSignal_.notifyAll();
        }

        maybeScheduleCompaction();
    }

    /// 执行后台压缩
    Status backgroundCompaction()
    {
        if (imm_ !is null)
        {
            // 压缩Immutable MemTable
            return compactMemTable();
        }

        // 层级压缩
        Compaction c = versions_.pickCompaction();
        if (c is null)
        {
            return Status(); // 无需压缩
        }

        if (c.isTrivialMove())
        {
            // 简单移动：直接将文件从level移到level+1
            FileMetaData f = c.inputLevel(0)[0];
            c.edit().deleteFile(c.level(), f.number);
            c.edit().addFile(c.level() + 1, f.number, f.fileSize,
                f.smallest, f.largest);

            return versions_.logAndApply(c.edit());
        }

        // 执行实际压缩
        return doCompactionWork(c);
    }

    /// 压缩Immutable MemTable
    Status compactMemTable()
    {
        // 将Immutable MemTable写入Level 0 SSTable
        VersionEdit edit;

        if (imm_ !is null)
        {
            // 从immutable memtable迭代器构建SSTable
            auto iter = new MemTableIterator(imm_.tablePtr());
            FileMetaData metaData;
            Status s = buildTable(dbname_, env_, options_, iter, metaData, versions_);

            if (!s.ok())
            {
                return s;
            }

            if (metaData.fileSize > 0)
            {
                // SSTable构建成功，添加到Level 0
                edit.addFile(0, metaData.number, metaData.fileSize,
                    metaData.smallest, metaData.largest);
            }
        }

        edit.hasLogNumber_ = true;
        edit.logNumber_ = logfileNumber_;
        edit.hasNextFileNumber_ = true;
        edit.nextFileNumber_ = versions_.nextFileNumber();
        edit.hasLastSequence_ = true;
        edit.lastSequence_ = lastSequence_;

        Status s = versions_.logAndApply(edit);
        if (s.ok() && imm_ !is null)
        {
            imm_.unref();
            imm_ = null;
            hasImm_ = false;
            removeObsoleteFiles();
        }

        return s;
    }

    /// 执行压缩工作
    Status doCompactionWork(Compaction c)
    {
        int level = c.level();
        ulong smallestUserKey = 0; // 用于判断是否可以丢弃删除标记

        // 创建合并迭代器
        Iterator[] iters;
        foreach (f; c.inputLevel(0))
        {
            iters ~= tableCache_.newIterator(ReadOptions(), f.number, f.fileSize);
        }
        foreach (f; c.inputLevel(1))
        {
            iters ~= tableCache_.newIterator(ReadOptions(), f.number, f.fileSize);
        }

        Iterator mergingIter = newMergingIterator(userComparator_, iters);

        // 创建SSTable构建器
        ulong outputNumber = versions_.newFileNumber();
        string outputName = tableFileName(dbname_, outputNumber);
        WritableFile outputFile;
        Status s = env_.newWritableFile(outputName, outputFile);
        if (!s.ok())
            return s;

        auto builder = new TableBuilder(options_, outputFile, icmp_);
        FileMetaData metaData;

        // 逐键处理
        mergingIter.seekToFirst();
        bool isFirst = true;
        ulong currentSequence = 0;

        while (mergingIter.valid())
        {
            Slice key = mergingIter.key();
            Slice value = mergingIter.value();

            // 解析内部键
            ParsedInternalKey parsed;
            parsed.userKey = extractUserKey(key);
            ulong packedTag = extractPackedTag(key);
            parsed.sequence = unpackSequence(packedTag);
            parsed.type = unpackValueType(packedTag);

            // 检查是否可以丢弃此条目
            bool shouldDrop = false;

            // 1. 如果是删除标记且没有更早的快照需要此键，可以丢弃
            if (parsed.type == ValueType.deletion)
            {
                // 检查是否在祖父层有重叠（简化：保守处理，不丢弃）
            }

            // 2. 检查压缩过滤器
            if (!shouldDrop && options_.compressionFilter !is null)
            {
                Slice newValue;
                auto result = options_.compressionFilter.filter(
                    parsed.userKey, value, newValue);
                if (result == CompressionFilterResult.remove)
                    shouldDrop = true;
                else if (result == CompressionFilterResult.change)
                    value = newValue;
            }

            if (!shouldDrop)
            {
                if (isFirst)
                {
                    metaData.smallest = InternalKey(parsed.userKey,
                        parsed.sequence, parsed.type);
                    isFirst = false;
                }

                builder.add(key, value);
                metaData.largest = InternalKey(parsed.userKey,
                    parsed.sequence, parsed.type);
            }

            mergingIter.next();
        }

        // 完成SSTable构建
        if (builder.numEntries() > 0)
        {
            s = builder.finish();
            if (s.ok())
            {
                metaData.number = outputNumber;
                metaData.fileSize = builder.fileSize();
                s = outputFile.sync();
            }
            if (s.ok())
            {
                s = outputFile.close();
            }

            if (s.ok())
            {
                // 添加新文件到level+1
                c.edit().addFile(level + 1, metaData.number, metaData.fileSize,
                    metaData.smallest, metaData.largest);
            }
        }
        else
        {
            outputFile.close();
            env_.removeFile(outputName);
            versions_.newFileNumber(); // 消耗掉未使用的编号
        }

        // 删除输入文件
        foreach (f; c.inputLevel(0))
        {
            c.edit().deleteFile(level, f.number);
        }
        foreach (f; c.inputLevel(1))
        {
            c.edit().deleteFile(level + 1, f.number);
        }

        // 应用版本编辑
        if (s.ok())
        {
            c.edit().hasLogNumber_ = true;
            c.edit().logNumber_ = logfileNumber_;
            c.edit().hasNextFileNumber_ = true;
            c.edit().nextFileNumber_ = versions_.nextFileNumber();
            c.edit().hasLastSequence_ = true;
            c.edit().lastSequence_ = lastSequence_;
            s = versions_.logAndApply(c.edit());
        }

        return s;
    }

    /// 删除废弃文件
    void removeObsoleteFiles()
    {
        // 收集所有活跃文件编号
        ulong[ulong] liveFiles;

        // 添加WAL日志编号
        liveFiles[logfileNumber_] = 1;

        // 添加MANIFEST编号
        liveFiles[versions_.manifestFileNumber()] = 1;

        // 添加当前版本中所有SSTable文件编号
        Version current = versions_.current();
        for (int level = 0; level < kNumLevels; level++)
        {
            foreach (f; current.files(level))
            {
                liveFiles[f.number] = 1;
            }
        }

        // 添加正在生成的输出文件
        foreach (num; pendingOutputs_)
        {
            liveFiles[num] = 1;
        }

        // 列出数据库目录中的所有文件
        string[] children;
        Status s = env_.getChildren(dbname_, children);
        if (!s.ok())
            return;

        // 删除不在活跃集合中的文件
        foreach (fname; children)
        {
            ulong number;
            FileType type;
            if (parseFileName(fname, number, type))
            {
                if (type == FileType.table && (number in liveFiles) is null)
                {
                    // 删除废弃SSTable
                    env_.removeFile(buildPath(dbname_, fname));
                    tableCache_.evict(number);
                }
                else if (type == FileType.log && (number in liveFiles) is null &&
                         number < versions_.logNumber())
                {
                    // 删除旧WAL日志
                    env_.removeFile(buildPath(dbname_, fname));
                }
                else if (type == FileType.descriptor && (number in liveFiles) is null &&
                         number != versions_.manifestFileNumber())
                {
                    // 删除旧MANIFEST
                    env_.removeFile(buildPath(dbname_, fname));
                }
                else if (type == FileType.temp)
                {
                    // 删除临时文件
                    env_.removeFile(buildPath(dbname_, fname));
                }
            }
        }
    }
}

/**
 * 带引用保护的数据库迭代器
 * 包装内部迭代器，析构时释放mem/imm/current的引用
 * 解决newIterator()中引用泄漏问题
 */
class DbIteratorWithRefs : Iterator
{
private:
    Iterator inner_;
    DBImpl db_;
    MemTable mem_;
    MemTable imm_;
    Version version_;
    bool released_;

public:
    this(Iterator inner, DBImpl db, MemTable mem, MemTable imm, Version ver)
    {
        inner_ = inner;
        db_ = db;
        mem_ = mem;
        imm_ = imm;
        version_ = ver;
        released_ = false;
    }

    ~this()
    {
        if (!released_ && db_ !is null)
        {
            try
            {
                db_.releaseIteratorRefs(mem_, imm_, version_);
            }
            catch (Throwable)
            {
                // db_可能已被销毁，忽略异常
            }
            released_ = true;
        }
    }

    /// 显式释放迭代器引用（在close前调用，避免GC回收时访问已销毁的db_）
    void release()
    {
        if (!released_ && db_ !is null)
        {
            db_.releaseIteratorRefs(mem_, imm_, version_);
            released_ = true;
        }
    }

    bool valid() const nothrow @nogc { return inner_.valid(); }
    void seekToFirst() { inner_.seekToFirst(); }
    void seekToLast() { inner_.seekToLast(); }
    void seek(Slice target) { inner_.seek(target); }
    void next() { inner_.next(); }
    void prev() { inner_.prev(); }
    Slice key() nothrow @nogc { return inner_.key(); }
    Slice value() nothrow @nogc { return inner_.value(); }
    Status status() const nothrow @nogc { return inner_.status(); }
}
