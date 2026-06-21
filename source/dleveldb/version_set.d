module dleveldb.version_set;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.dbformat;
import dleveldb.version_edit;
import dleveldb.comparator;
import dleveldb.env;
import dleveldb.options;
import dleveldb.coding;
import dleveldb.log_writer;
import dleveldb.log_reader;
import dleveldb.table_cache;
import dleveldb.iterator;
import dleveldb.merger;
import dleveldb.filename;
import std.path : buildPath;
import std.logger;

import core.sync.mutex;
import core.atomic : atomicFetchAdd, atomicFetchSub;

/**
 * Version：数据库某一时刻的完整状态快照
 * 包含所有层级的SSTable文件集合
 * 不可变，通过引用计数管理生命周期
 */
class Version
{
private:
    VersionSet vset_;
    FileMetaData[][] files_;  // 每层的文件列表
    int refs_;

    // 压缩调度信息
    double compactionScore_;
    int compactionLevel_;

    // seek-based压缩
    FileMetaData fileToCompact_;
    int fileToCompactLevel_;

    // 双向链表
    Version next_;
    Version prev_;

public:
    /// 构造版本快照
    /// Params: vset = 所属版本集合管理器
    this(VersionSet vset)
    {
        vset_ = vset;
        refs_ = 0;
        compactionScore_ = -1;
        compactionLevel_ = -1;
        files_.length = numLevels;
        next_ = this;
        prev_ = this;
    }

    /// 析构函数，重置引用计数（链表清理由VersionSet.closeResources()统一处理）
    ~this()
    {
        // GC回收时机不可控，不再断言refs_==0，不再操作链表
        // 链表清理由VersionSet.closeResources()统一处理
        refs_ = 0;
    }

    /// 增加引用（原子操作）
    void addRef()  @nogc nothrow
    {
        atomicFetchAdd(refs_, 1);
    }

    /// 减少引用（原子操作）
    void unref() nothrow
    {
        assert(refs_ > 0);
        atomicFetchSub(refs_, 1);
    }

    /// 获取指定层的文件列表
    FileMetaData[] files(int level)  @nogc
    {
        return files_[level];
    }

    /// 设置指定层的文件列表
    void setFiles(int level, FileMetaData[] files) 
    {
        files_[level] = files;
    }

    /// 获取压缩分数
    double compactionScore() const pure @safe @nogc { return compactionScore_; }
    int compactionLevel() const pure @safe @nogc { return compactionLevel_; }

    /// 获取VersionSet
    VersionSet versionSet()  @nogc { return vset_; }

    /// 计算某层的总字节数
    ulong numLevelBytes(int level) const 
    {
        ulong total = 0;
        foreach (f; files_[level])
            total += f.fileSize;
        return total;
    }

    /// 计算某层的文件数
    int numLevelFiles(int level) const pure @safe @nogc
    {
        return cast(int) files_[level].length;
    }

    /// 获取下一个迭代器级别
    Version next()  @nogc { return next_; }

    /// 在SSTable层级中查找键
    /// 遍历所有层级的SSTable，使用TableCache查找
    Status get(ReadOptions options, LookupKey lkey, ref ubyte[] value)
    {
        Slice userKey = lkey.userKey();
        auto ucmp = vset_.userComparator();
        Status s;

        // Level 0：文件可能有重叠，需要检查所有文件
        for (size_t i = 0; i < files_[0].length; i++)
        {
            FileMetaData f = files_[0][i];
            if (ucmp.compare(userKey, f.smallest.userKey()) < 0)
            {
                continue;
            }
            if (ucmp.compare(userKey, f.largest.userKey()) > 0)
            {
                continue;
            }

            s = vset_.tableCache_.get(options, f.number, f.fileSize,
                lkey.internalKey(), value);
            if (s.ok() || s.isNotFound())
            {
                if (s.ok())
                    return s;
                // NotFound: 继续搜索其他文件
            }
            else
            {
                return s; // 其他错误
            }
        }

        // Level 1+：文件不重叠，二分查找
        for (int level = 1; level < numLevels; level++)
        {
            if (files_[level].length == 0)
                continue;

            // 二分查找第一个largest >= userKey的文件
            size_t idx = findFile(level, userKey);
            if (idx >= files_[level].length)
                continue;

            FileMetaData f = files_[level][idx];
            if (ucmp.compare(userKey, f.smallest.userKey()) < 0)
                continue;

            s = vset_.tableCache_.get(options, f.number, f.fileSize,
                lkey.internalKey(), value);
            if (s.ok() || s.isNotFound())
            {
                if (s.ok())
                    return s;
            }
            else
            {
                return s;
            }
        }

        return statusNotFound("");
    }

    /// 收集所有层级的SSTable迭代器
    void addIterators(ReadOptions options, ref Iterator[] iters)
    {
        for (int level = 0; level < numLevels; level++)
        {
            foreach (f; files_[level])
            {
                Iterator iter = vset_.tableCache_.newIterator(
                    options, f.number, f.fileSize);
                iters ~= iter;
            }
        }
    }

    /// 检查指定user key是否在某层中存在覆盖它的文件
    /// 用于compaction时判断删除标记是否可安全丢弃
    bool overlapInLevel(int level, Slice userKey)
    {
        auto ucmp = vset_.userComparator();
        if (level == 0)
        {
            // Level 0 文件有重叠，需遍历所有文件
            foreach (f; files_[0])
            {
                if (ucmp.compare(userKey, f.smallest.userKey()) >= 0 &&
                    ucmp.compare(userKey, f.largest.userKey()) <= 0)
                {
                    return true;
                }
            }
            return false;
        }
        else
        {
            // Level 1+ 文件不重叠，二分查找
            size_t idx = findFile(level, userKey);
            if (idx >= files_[level].length)
                return false;
            FileMetaData f = files_[level][idx];
            return ucmp.compare(userKey, f.smallest.userKey()) >= 0;
        }
    }

private:
    /// 在指定层级二分查找第一个largest >= target的文件索引
    size_t findFile(int level, Slice targetKey)
    {
        auto ucmp = vset_.userComparator();
        auto files = files_[level];
        size_t lo = 0;
        size_t hi = files.length;
        while (lo < hi)
        {
            size_t mid = (lo + hi) / 2;
            if (ucmp.compare(targetKey, files[mid].largest.userKey()) > 0)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }
        return lo;
    }
}

/**
 * VersionSet：版本集合管理器
 * 管理所有Version，读写MANIFEST
 */
class VersionSet
{
private:
    string dbname_;
    Options options_;
    Env env_;
    Comparator userComparator_;
    InternalKeyComparator icmp_;

    Version dummyVersions_;  // 版本双向链表头
    Version current_;        // 当前版本

    ulong nextFileNumber_;
    ulong manifestFileNumber_;
    ulong lastSequence_;
    ulong logNumber_;
    ulong prevLogNumber_;

    WritableFile descriptorFile_;
    LogWriter descriptorLog_;

    InternalKey[numLevels] compactPointer_;

    Mutex mutex_;

    TableCache tableCache_;  // 由DBImpl设置

public:
    /// 构造版本集合管理器
    ///
    /// Params:
    ///     dbname = 数据库名称
    ///     options = 数据库选项
    ///     env = 环境接口
    ///     userCmp = 用户键比较器
    this(string dbname, Options options, Env env, Comparator userCmp)
    {
        dbname_ = dbname;
        options_ = options;
        env_ = env;
        userComparator_ = userCmp;
        icmp_ = new InternalKeyComparator(userCmp);

        dummyVersions_ = new Version(this);
        current_ = dummyVersions_;

        nextFileNumber_ = 1;
        manifestFileNumber_ = 0;
        lastSequence_ = 0;
        logNumber_ = 0;
        prevLogNumber_ = 0;
    }

    /// 析构函数（资源释放由closeResources()完成）
    ~this()
    {
        // closeResources()已在DBImpl.close()中先调用，此处不再操作
    }

    /// 获取当前版本
    Version current()  @nogc { return current_; }

    /// 获取/设置最后序列号
    ulong lastSequence() const pure @safe @nogc { return lastSequence_; }
    void setLastSequence(ulong s)  @nogc { lastSequence_ = s; }

    /// 获取/设置日志编号
    ulong logNumber() const pure @safe @nogc { return logNumber_; }
    void setLogNumber(ulong n)  @nogc { logNumber_ = n; }

    /// 获取前一日志编号
    ulong prevLogNumber() const pure @safe @nogc { return prevLogNumber_; }

    /// 分配新文件编号
    ulong newFileNumber()  @nogc
    {
        return nextFileNumber_++;
    }

    /// 获取下一个文件编号
    ulong nextFileNumber() const pure @safe @nogc { return nextFileNumber_; }

    /// 获取MANIFEST文件编号
    ulong manifestFileNumber() const pure @safe @nogc { return manifestFileNumber_; }

    /// 获取内部键比较器
    InternalKeyComparator internalComparator()  @nogc { return icmp_; }

    /// 获取用户比较器
    Comparator userComparator()  @nogc { return userComparator_; }

    /// 获取数据库名
    string dbname() const pure nothrow @safe { return dbname_; }

    /// 设置TableCache（由DBImpl在open时调用）
    void setTableCache(TableCache tc) { tableCache_ = tc; }

    /// 应用版本编辑
    Status logAndApply(VersionEdit edit) 
    {
        // 确保edit包含必要信息
        if (edit.hasLogNumber_)
            assert(edit.logNumber_ >= logNumber_);
        if (edit.hasPrevLogNumber_)
            assert(edit.prevLogNumber_ >= prevLogNumber_);
        if (edit.hasNextFileNumber_)
            assert(edit.nextFileNumber_ >= nextFileNumber_);

        // 创建新Version
        Version v = new Version(this);
        for (int level = 0; level < numLevels; level++)
        {
            auto srcFiles = current_.files(level);
            // 优化：直接赋值而非 .dup，因为后续 applyEdit 会修改副本
            // FileMetaData 是 struct，数组切片拷贝是浅拷贝，但元素是值类型
            auto newFiles = new FileMetaData[srcFiles.length];
            newFiles[] = srcFiles[];
            v.setFiles(level, newFiles);
        }

        // 应用编辑
        applyEdit(edit, v);

        // 计算压缩分数
        finalize(v);

        // 安装新版本
        appendVersion(v);

        // 写入MANIFEST
        if (descriptorLog_ !is null)
        {
            ubyte[] encoded;
            edit.encodeTo(encoded);
            Status s = descriptorLog_.addRecord(Slice(encoded.ptr, encoded.length));
            if (!s.ok())
                return s;
        }

        return Status();
    }

    /// 从MANIFEST恢复
    Status recover()
    {
        // 尝试读取CURRENT文件获取MANIFEST文件名
        string currentFile = currentFileName(dbname_);
        string manifestName;
        bool foundManifest = false;

        if (env_.fileExists(currentFile))
        {
            // 读取CURRENT文件内容
            SequentialFile file;
            Status s = env_.newSequentialFile(currentFile, file);
            if (s.ok())
            {
                Slice result;
                ubyte[1024] buf;
                s = file.read(1024, result, buf);
                if (s.ok() && result.size() > 0)
                {
                    // CURRENT文件内容为"MANIFEST-XXXXXX\n"
                    import std.string : strip;
                    manifestName = buildPath(dbname_, strip(result.asString().idup));
                    foundManifest = env_.fileExists(manifestName);
                }
            }
        }

        if (!foundManifest)
        {
            // 没有MANIFEST，创建初始版本
            manifestFileNumber_ = newFileNumber();
            Version v = new Version(this);
            finalize(v);
            appendVersion(v);

            // 创建MANIFEST文件
            string manifestFileName = descriptorFileName(dbname_, manifestFileNumber_);
            Status s = env_.newWritableFile(manifestFileName, descriptorFile_);
            if (!s.ok())
                return s;
            descriptorLog_ = new LogWriter(descriptorFile_);

            // 写入CURRENT文件
            writeCurrentFile();
            return Status();
        }

        // 从MANIFEST文件恢复
        // 解析MANIFEST文件名获取编号
        ulong manifestNumber;
        foreach (i, ch; manifestName)
        {
            if (ch == '-')
            {
                import std.conv : to;
                try
                {
                    manifestNumber = to!ulong(manifestName[i + 1 .. $]);
                }
                catch (Exception)
                {
                    manifestNumber = 0;
                }
                break;
            }
        }
        manifestFileNumber_ = manifestNumber;

        // 读取并重放MANIFEST记录
        SequentialFile manifestFile;
        Status s = env_.newSequentialFile(manifestName, manifestFile);
        if (!s.ok())
            return s;

        LogReader reader = new LogReader(manifestFile, true, 0, 0);
        Slice record;
        ubyte[] scratch;

        Version v = new Version(this);
        ulong nextFileNum = 0;

        while (reader.readRecord(record, scratch))
        {
            VersionEdit edit;
            s = edit.decodeFrom(record);
            if (!s.ok())
            {
                warning("version_set recover: skipping corrupted MANIFEST record: ", s.toString());
                continue;
            }

            // 应用编辑
            applyEdit(edit, v);

            // 更新文件编号
            if (edit.hasNextFileNumber_ && edit.nextFileNumber_ > nextFileNum)
                nextFileNum = edit.nextFileNumber_;
            if (edit.hasLastSequence_)
                lastSequence_ = edit.lastSequence_;
            if (edit.hasLogNumber_)
                logNumber_ = edit.logNumber_;
            if (edit.hasPrevLogNumber_)
                prevLogNumber_ = edit.prevLogNumber_;
        }

        // 确保nextFileNumber大于所有已见编号
        if (nextFileNum > nextFileNumber_)
            nextFileNumber_ = nextFileNum;

        finalize(v);
        appendVersion(v);

        // 打开新的MANIFEST文件用于后续写入
        manifestFileNumber_ = newFileNumber();
        string newManifestName = descriptorFileName(dbname_, manifestFileNumber_);
        s = env_.newWritableFile(newManifestName, descriptorFile_);
        if (!s.ok())
            return s;
        descriptorLog_ = new LogWriter(descriptorFile_);

        // 将当前版本的完整文件快照写入新 MANIFEST，
        // 确保下次open能正确恢复所有文件
        {
            VersionEdit snapshotEdit;
            for (int level = 0; level < numLevels; level++)
            {
                foreach (ref FileMetaData f; v.files(level))
                {
                    snapshotEdit.addFile(level, f.number, f.fileSize,
                        f.smallest, f.largest);
                }
            }
            snapshotEdit.hasNextFileNumber_ = true;
            snapshotEdit.nextFileNumber_ = nextFileNumber_;
            snapshotEdit.hasLastSequence_ = true;
            snapshotEdit.lastSequence_ = lastSequence_;
            snapshotEdit.hasLogNumber_ = true;
            snapshotEdit.logNumber_ = logNumber_;

            ubyte[] encoded;
            snapshotEdit.encodeTo(encoded);
            Status s2 = descriptorLog_.addRecord(Slice(encoded.ptr, encoded.length));
            if (!s2.ok())
                return s2;
        }

        // 写入CURRENT文件
        writeCurrentFile();

        return Status();
    }

    /// 选择下一个压缩
    Compaction pickCompaction()
    {
        Compaction c;
        int level = -1;
        double bestScore = 1.0;

        // 查找最需要压缩的层级
        for (int i = 0; i < numLevels - 1; i++)
        {
            double score = current_.compactionScore();
            if (current_.compactionLevel() == i && score > bestScore)
            {
                bestScore = score;
                level = i;
            }
        }

        if (level >= 0)
        {
            c = new Compaction(level);

            auto levelFiles = current_.files(level);
            if (levelFiles.length > 0)
            {
                if (level == 0)
                {
                    // Level 0：选择所有与第一个文件重叠的文件
                    // L0文件允许键范围重叠，必须将所有重叠文件一起压缩
                    // 注意：使用 InternalKey 存储范围，避免 Slice 悬挂引用
                    InternalKey smallest = levelFiles[0].smallest;
                    InternalKey largest = levelFiles[0].largest;

                    // 扩展范围直到没有新的重叠文件
                    bool expanded = true;
                    while (expanded)
                    {
                        expanded = false;
                        foreach (f; levelFiles)
                        {
                            // 检查文件是否与当前[smallest, largest]重叠
                            if (icmp_.compare(f.smallest.encode(), largest.encode()) <= 0 &&
                                icmp_.compare(f.largest.encode(), smallest.encode()) >= 0)
                            {
                                // 检查是否已在输入列表中
                                bool alreadyAdded = false;
                                foreach (existing; c.inputs_[0])
                                {
                                    if (existing.number == f.number)
                                    {
                                        alreadyAdded = true;
                                        break;
                                    }
                                }
                                if (!alreadyAdded)
                                {
                                    c.inputs_[0] ~= f;
                                    // 扩展键范围
                                    if (icmp_.compare(f.smallest.encode(), smallest.encode()) < 0)
                                        smallest = f.smallest;
                                    if (icmp_.compare(f.largest.encode(), largest.encode()) > 0)
                                        largest = f.largest;
                                    expanded = true;
                                }
                            }
                        }
                    }
                }
                else
                {
                    // Level 1+：选择与压缩指针对应的文件
                    // 使用当前层的第一个文件（简化实现）
                    c.inputs_[0] ~= levelFiles[0];
                }
            }

            // 选择level+1层与输入重叠的文件
            if (c.inputs_[0].length > 0)
            {
                // 使用 InternalKey 存储范围，避免 Slice 悬挂引用
                InternalKey smallest = c.inputs_[0][0].smallest;
                InternalKey largest = c.inputs_[0][0].largest;

                // 找到输入文件的整体键范围
                foreach (f; c.inputs_[0])
                {
                    if (icmp_.compare(f.smallest.encode(), smallest.encode()) < 0)
                        smallest = f.smallest;
                    if (icmp_.compare(f.largest.encode(), largest.encode()) > 0)
                        largest = f.largest;
                }

                auto nextLevelFiles = current_.files(level + 1);
                foreach (f; nextLevelFiles)
                {
                    // 检查是否与[smallest, largest]重叠
                    if (icmp_.compare(f.smallest.encode(), largest.encode()) <= 0 &&
                        icmp_.compare(f.largest.encode(), smallest.encode()) >= 0)
                    {
                        c.inputs_[1] ~= f;
                    }
                }
            }

            // 检查是否可以简单移动
            c.checkTrivialMove();
        }

        return c;
    }

    /// 计算某层最大字节数
    ulong maxBytesForLevel(int level) const 
    {
        // Level 0和1: 10MB
        // Level L (L>=2): 10MB * 10^(L-1)
        ulong result = 10 * 1024 * 1024; // 10MB
        for (int i = 2; i <= level; i++)
        {
            result *= 10;
        }
        return result;
    }

private:
    /// 将版本添加到链表并设为当前
    void appendVersion(Version v) 
    {
        // 从链表中移除旧current
        if (current_ !is dummyVersions_)
        {
            current_.unref();
        }

        // 添加到链表
        v.next_ = dummyVersions_;
        v.prev_ = dummyVersions_.prev_;
        v.prev_.next_ = v;
        v.next_.prev_ = v;

        v.addRef();
        current_ = v;
    }

    /// 应用版本编辑到新版本
    void applyEdit(VersionEdit edit, Version v) 
    {
        // 更新压缩指针
        foreach (cp; edit.compactPointers_)
        {
            compactPointer_[cp.level] = cp.key;
        }

        // 删除文件
        foreach (df; edit.deletedFiles_)
        {
            auto files = v.files(df.level);
            // 移除指定编号的文件
            size_t writeIdx = 0;
            for (size_t readIdx = 0; readIdx < files.length; readIdx++)
            {
                if (files[readIdx].number != df.fileNumber)
                {
                    files[writeIdx] = files[readIdx];
                    writeIdx++;
                }
            }
            v.setFiles(df.level, files[0 .. writeIdx]);
        }

        // 新增文件
        foreach (nf; edit.newFiles_)
        {
            auto files = v.files(nf.level);
            files ~= nf.metaData;
            v.setFiles(nf.level, files);
        }

        // 更新序列号等
        if (edit.hasLastSequence_)
            lastSequence_ = edit.lastSequence_;
        if (edit.hasNextFileNumber_)
            nextFileNumber_ = edit.nextFileNumber_;
        if (edit.hasLogNumber_)
            logNumber_ = edit.logNumber_;
        if (edit.hasPrevLogNumber_)
            prevLogNumber_ = edit.prevLogNumber_;
    }

    /// 计算压缩分数
    void finalize(Version v) 
    {
        double bestScore = -1;
        int bestLevel = -1;

        for (int level = 0; level < numLevels - 1; level++)
        {
            double score;
            if (level == 0)
            {
                score = cast(double) v.numLevelFiles(level) / l0CompactionTrigger;
            }
            else
            {
                ulong bytes = v.numLevelBytes(level);
                score = cast(double) bytes / maxBytesForLevel(level);
            }

            if (score > bestScore)
            {
                bestScore = score;
                bestLevel = level;
            }
        }

        v.compactionScore_ = bestScore;
        v.compactionLevel_ = bestLevel;
    }

    /// 写入CURRENT文件
    Status writeCurrentFile()
    {
        import std.string : strip;
        import std.format : format;

        string currentName = currentFileName(dbname_);
        // 与 descriptorFileName 使用相同的格式化，确保一致
        string manifestBase = format("MANIFEST-%06d", manifestFileNumber_);
        string content = manifestBase ~ "\n";

        // 先写临时文件，再原子重命名
        string tmpName = tempFileName(dbname_, manifestFileNumber_);
        WritableFile tmpFile;
        Status s = env_.newWritableFile(tmpName, tmpFile);
        if (!s.ok())
            return s;

        s = tmpFile.append(Slice(content));
        if (s.ok())
            s = tmpFile.sync();
        if (s.ok())
            s = tmpFile.close();

        if (s.ok())
            s = env_.renameFile(tmpName, currentName);

        return s;
    }

public:
    /// 释放资源（关闭MANIFEST文件句柄）
    void closeResources()
    {
        descriptorLog_ = null;
        if (descriptorFile_ !is null)
        {
            descriptorFile_.close();
            descriptorFile_ = null;
        }

        // 显式断开整个Version链表，防止GC按不确定顺序回收时访问无效链表节点
        if (dummyVersions_ !is null)
        {
            Version v = dummyVersions_.next_;
            while (v !is dummyVersions_)
            {
                Version next = v.next_;
                v.next_ = v;
                v.prev_ = v;
                v = next;
            }
            dummyVersions_.next_ = dummyVersions_;
            dummyVersions_.prev_ = dummyVersions_;
        }

        // 释放current_引用
        if (current_ !is null && current_ !is dummyVersions_)
        {
            current_.unref();
        }
        current_ = null;
    }
}

/**
 * 压缩任务描述
 */
class Compaction
{
private:
    int level_;
    FileMetaData[][2] inputs_;  // level和level+1的输入文件
    FileMetaData[] grandparents_; // 祖父层重叠文件
    ulong maxOutputFileSize_;
    VersionEdit edit_;
    bool isTrivialMove_;

public:
    /// 构造压缩任务
    /// Params: level = 压缩层级
    this(int level)
    {
        level_ = level;
        maxOutputFileSize_ = 2 * 1024 * 1024; // 2MB
        isTrivialMove_ = false;
    }

    /// 获取压缩层级
    /// Returns: 压缩层级
    int level() const pure @safe @nogc { return level_; }

    /// 获取输入文件（level和level+1两层）
    /// Returns: 两层输入文件数组
    FileMetaData[][2] inputs()  @nogc { return inputs_; }

    /// 获取指定层级的输入文件
    /// Params: which = 层级索引（0为当前层，1为下一层）
    /// Returns: 指定层级的输入文件列表
    FileMetaData[] inputLevel(int which)  @nogc { return inputs_[which]; }

    /// 获取最大输出文件大小
    /// Returns: 最大输出文件大小（字节）
    ulong maxOutputFileSize() const pure @safe @nogc { return maxOutputFileSize_; }

    /// 获取版本编辑记录
    /// Returns: 版本编辑记录
    VersionEdit edit()  @nogc { return edit_; }

    /// 检查是否为平凡移动
    /// Returns: 如果是平凡移动返回true
    bool isTrivialMove() const pure @safe @nogc { return isTrivialMove_; }

    /// 判断是否可简单移动
    void checkTrivialMove() 
    {
        isTrivialMove_ = (inputs_[0].length == 1 &&
            inputs_[1].length == 0 &&
            grandparents_.length == 0);
    }
}
