module dleveldb.version_edit;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.dbformat;
import dleveldb.coding;

/**
 * 文件元数据
 */
struct FileMetaData
{
    ulong number;         // 文件编号
    ulong fileSize;       // 文件大小
    InternalKey smallest; // 最小内部键
    InternalKey largest;  // 最大内部键
    int refs;             // 引用计数
    int allowedSeeks;     // 允许的seek次数

    /// 构造文件元数据
    ///
    /// Params:
    ///     num = 文件编号
    ///     size = 文件大小
    ///     small = 最小内部键
    ///     large = 最大内部键
    this(ulong num, ulong size, InternalKey small, InternalKey large)
    {
        number = num;
        fileSize = size;
        smallest = small;
        largest = large;
        refs = 0;
        allowedSeeks = cast(int) (size / 16384);
        if (allowedSeeks < 100)
            allowedSeeks = 100;
    }
}

/**
 * 版本编辑记录
 * 记录Version之间的增量变更
 */
struct VersionEdit
{
    // 被删除的文件：(level, fileNumber)
    struct DeletedFile
    {
        int level;
        ulong fileNumber;
    }

    // 新增的文件：(level, FileMetaData)
    struct NewFile
    {
        int level;
        FileMetaData metaData;
    }

    // 压缩指针：(level, internalKey)
    struct CompactPointer
    {
        int level;
        InternalKey key;
    }

    string comparator_;              // 比较器名称
    ulong logNumber_;                // 日志编号
    ulong prevLogNumber_;            // 前一日志编号
    ulong nextFileNumber_;           // 下一个文件编号
    ulong lastSequence_;             // 最后序列号
    bool hasComparator_;
    bool hasLogNumber_;
    bool hasPrevLogNumber_;
    bool hasNextFileNumber_;
    bool hasLastSequence_;

    DeletedFile[] deletedFiles_;
    NewFile[] newFiles_;
    CompactPointer[] compactPointers_;

    // 使用默认init值，不需要构造函数

    /// 清空
    void clear() pure nothrow @safe
    {
        hasComparator_ = false;
        hasLogNumber_ = false;
        hasPrevLogNumber_ = false;
        hasNextFileNumber_ = false;
        hasLastSequence_ = false;
        deletedFiles_ = null;
        newFiles_ = null;
        compactPointers_ = null;
    }

    /// 添加删除文件
    void deleteFile(int level, ulong fileNumber) 
    {
        deletedFiles_ ~= DeletedFile(level, fileNumber);
    }

    /// 添加新增文件
    void addFile(int level, ulong fileNumber, ulong fileSize,
        InternalKey smallest, InternalKey largest) 
    {
        newFiles_ ~= NewFile(level,
            FileMetaData(fileNumber, fileSize, smallest, largest));
    }

    /// 编码到缓冲区
    void encodeTo(ref ubyte[] dst) const
    {
        // 比较器
        if (hasComparator_)
        {
            dst ~= cast(ubyte) Tag.comparator;
            putLengthPrefixedSlice(dst, sliceFromString(comparator_));
        }

        // 日志编号
        if (hasLogNumber_)
        {
            dst ~= cast(ubyte) Tag.logNumber;
            size_t oldLen = dst.length;
            dst.length = oldLen + varintLength64(logNumber_);
            encodeVarint64(dst.ptr + oldLen, logNumber_);
        }

        // 前一日志编号
        if (hasPrevLogNumber_)
        {
            dst ~= cast(ubyte) Tag.prevLogNumber;
            size_t oldLen = dst.length;
            dst.length = oldLen + varintLength64(prevLogNumber_);
            encodeVarint64(dst.ptr + oldLen, prevLogNumber_);
        }

        // 下一个文件编号
        if (hasNextFileNumber_)
        {
            dst ~= cast(ubyte) Tag.nextFileNumber;
            size_t oldLen = dst.length;
            dst.length = oldLen + varintLength64(nextFileNumber_);
            encodeVarint64(dst.ptr + oldLen, nextFileNumber_);
        }

        // 最后序列号
        if (hasLastSequence_)
        {
            dst ~= cast(ubyte) Tag.lastSequence;
            size_t oldLen = dst.length;
            dst.length = oldLen + varintLength64(lastSequence_);
            encodeVarint64(dst.ptr + oldLen, lastSequence_);
        }

        // 压缩指针
        foreach (cp; compactPointers_)
        {
            dst ~= cast(ubyte) Tag.compactPointer;
            size_t oldLen = dst.length;
            dst.length = oldLen + varintLength(cast(uint) cp.level);
            encodeVarint32(dst.ptr + oldLen, cast(uint) cp.level);
            putLengthPrefixedSlice(dst, cp.key.encode());
        }

        // 删除文件
        foreach (df; deletedFiles_)
        {
            dst ~= cast(ubyte) Tag.deletedFile;
            size_t oldLen = dst.length;
            int varintLevel = varintLength(cast(uint) df.level);
            int varintFile = varintLength64(df.fileNumber);
            dst.length = oldLen + varintLevel + varintFile;
            ubyte* p = dst.ptr + oldLen;
            p += encodeVarint32(p, cast(uint) df.level);
            encodeVarint64(p, df.fileNumber);
        }

        // 新增文件
        // 字段顺序：level → number → size → smallest → largest（与原版LevelDB一致）
        foreach (nf; newFiles_)
        {
            dst ~= cast(ubyte) Tag.newFile;
            size_t oldLen = dst.length;
            int varintLevel = varintLength(cast(uint) nf.level);
            int varintFile = varintLength64(nf.metaData.number);
            int varintSize = varintLength64(nf.metaData.fileSize);
            dst.length = oldLen + varintLevel + varintFile + varintSize;
            ubyte* p = dst.ptr + oldLen;
            p += encodeVarint32(p, cast(uint) nf.level);
            p += encodeVarint64(p, nf.metaData.number);
            encodeVarint64(p, nf.metaData.fileSize);
            putLengthPrefixedSlice(dst, nf.metaData.smallest.encode());
            putLengthPrefixedSlice(dst, nf.metaData.largest.encode());
        }
    }

    /// 从Slice解码
    Status decodeFrom(Slice input) 
    {
        const(ubyte)* ptr = input.data();
        const(ubyte)* limit = ptr + input.size();

        while (ptr < limit)
        {
            ubyte tag = *ptr;
            ptr++;

            final switch (cast(Tag) tag)
            {
                case Tag.comparator:
                {
                    Slice s;
                    if (!getLengthPrefixedSlice(ptr, limit, s))
                        return statusCorruption("bad comparator in VersionEdit");
                    comparator_ = s.asString().idup;
                    hasComparator_ = true;
                    break;
                }
                case Tag.logNumber:
                {
                    if (!decodeVarint64(ptr, limit, logNumber_))
                        return statusCorruption("bad logNumber in VersionEdit");
                    hasLogNumber_ = true;
                    break;
                }
                case Tag.prevLogNumber:
                {
                    if (!decodeVarint64(ptr, limit, prevLogNumber_))
                        return statusCorruption("bad prevLogNumber in VersionEdit");
                    hasPrevLogNumber_ = true;
                    break;
                }
                case Tag.nextFileNumber:
                {
                    if (!decodeVarint64(ptr, limit, nextFileNumber_))
                        return statusCorruption("bad nextFileNumber in VersionEdit");
                    hasNextFileNumber_ = true;
                    break;
                }
                case Tag.lastSequence:
                {
                    if (!decodeVarint64(ptr, limit, lastSequence_))
                        return statusCorruption("bad lastSequence in VersionEdit");
                    hasLastSequence_ = true;
                    break;
                }
                case Tag.compactPointer:
                {
                    uint level;
                    if (!decodeVarint32(ptr, limit, level))
                        return statusCorruption("bad compactPointer level");
                    Slice key;
                    if (!getLengthPrefixedSlice(ptr, limit, key))
                        return statusCorruption("bad compactPointer key");
                    CompactPointer cp;
                    cp.level = cast(int) level;
                    cp.key.setFrom(key);
                    compactPointers_ ~= cp;
                    break;
                }
                case Tag.deletedFile:
                {
                    uint level;
                    ulong fileNumber;
                    if (!decodeVarint32(ptr, limit, level))
                        return statusCorruption("bad deletedFile level");
                    if (!decodeVarint64(ptr, limit, fileNumber))
                        return statusCorruption("bad deletedFile number");
                    deletedFiles_ ~= DeletedFile(cast(int) level, fileNumber);
                    break;
                }
                case Tag.newFile:
                {
                    uint level;
                    if (!decodeVarint32(ptr, limit, level))
                        return statusCorruption("bad newFile level");
                    ulong fileNumber, fileSize;
                    if (!decodeVarint64(ptr, limit, fileNumber))
                        return statusCorruption("bad newFile number");
                    if (!decodeVarint64(ptr, limit, fileSize))
                        return statusCorruption("bad newFile size");
                    Slice smallest, largest;
                    if (!getLengthPrefixedSlice(ptr, limit, smallest))
                        return statusCorruption("bad newFile smallest");
                    if (!getLengthPrefixedSlice(ptr, limit, largest))
                        return statusCorruption("bad newFile largest");

                    NewFile nf;
                    nf.level = cast(int) level;
                    nf.metaData = FileMetaData(fileNumber, fileSize,
                        InternalKey(), InternalKey());
                    nf.metaData.smallest.setFrom(smallest);
                    nf.metaData.largest.setFrom(largest);
                    newFiles_ ~= nf;
                    break;
                }
            }
        }

        return Status();
    }

private:
    /// VersionEdit标签类型
    enum Tag : ubyte
    {
        comparator = 1,
        logNumber = 2,
        nextFileNumber = 3,
        lastSequence = 4,
        compactPointer = 5,
        deletedFile = 6,
        newFile = 7,
        prevLogNumber = 9,
    }
}
