module dleveldb.env;

import dleveldb.slice;
import dleveldb.status;
import core.sync.mutex;
import std.parallelism : task, TaskPool;

/**
 * 文件类型枚举
 */
enum FileType : ubyte
{
    log = 0,
    table = 1,
    descriptor = 2,
    current = 3,
    temp = 4,
    infoLog = 5,
    dbLock = 6,
}

/**
 * 顺序读取文件接口
 */
interface SequentialFile
{
    /// 读取n字节到result，scratch为临时缓冲区
    Status read(size_t n, ref Slice result, ubyte[] scratch);

    /// 跳过n字节
    Status skip(size_t n);
}

/**
 * 随机读取文件接口（线程安全）
 */
interface RandomAccessFile
{
    /// 从offset读取n字节到result
    Status read(ulong offset, size_t n, ref Slice result, ubyte[] scratch) const;
}

/**
 * 可写文件接口
 */
interface WritableFile
{
    /// 追加数据到文件
    /// Params: data = 要写入的数据
    /// Returns: 操作状态
    Status append(Slice data);

    /// 关闭文件
    /// Returns: 操作状态
    Status close();

    /// 刷新用户态缓冲区到操作系统
    /// Returns: 操作状态
    Status flush();

    /// 将数据同步到磁盘
    /// Returns: 操作状态
    Status sync();
}

/**
 * 文件锁接口
 */
interface FileLock
{
}

/**
 * 日志写入器接口
 */
interface Logger
{
    /// 写入日志消息
    /// Params: msg = 日志内容
    void logv(string msg);
}

/**
 * 环境抽象接口
 * 提供文件系统操作和线程调度
 */
interface Env
{
    // 文件操作

    /// 创建顺序读取文件
    /// Params: fname = 文件名, result = 输出的文件对象
    /// Returns: 操作状态
    Status newSequentialFile(string fname, out SequentialFile result);

    /// 创建随机读取文件
    /// Params: fname = 文件名, result = 输出的文件对象
    /// Returns: 操作状态
    Status newRandomAccessFile(string fname, out RandomAccessFile result);

    /// 创建可写文件
    /// Params: fname = 文件名, result = 输出的文件对象
    /// Returns: 操作状态
    Status newWritableFile(string fname, out WritableFile result);

    /// 创建可追加写入文件
    /// Params: fname = 文件名, result = 输出的文件对象
    /// Returns: 操作状态
    Status newAppendableFile(string fname, out WritableFile result);

    // 文件系统操作

    /// 判断文件是否存在
    /// Params: fname = 文件名
    /// Returns: 存在则为 true
    bool fileExists(string fname) const;

    /// 获取目录下的子项名称列表
    /// Params: dir = 目录路径, result = 输出的名称数组
    /// Returns: 操作状态
    Status getChildren(string dir, out string[] result);

    /// 删除文件
    /// Params: fname = 文件名
    /// Returns: 操作状态
    Status removeFile(string fname);

    /// 创建目录（含中间目录）
    /// Params: dir = 目录路径
    /// Returns: 操作状态
    Status createDir(string dir);

    /// 删除目录
    /// Params: dir = 目录路径
    /// Returns: 操作状态
    Status removeDir(string dir);

    /// 获取文件大小
    /// Params: fname = 文件名, size = 输出的文件字节数
    /// Returns: 操作状态
    Status getFileSize(string fname, out ulong size);

    /// 重命名文件
    /// Params: src = 源文件名, dst = 目标文件名
    /// Returns: 操作状态
    Status renameFile(string src, string dst);

    /// 锁定文件
    /// Params: fname = 文件名, lock = 输出的文件锁对象
    /// Returns: 操作状态
    Status lockFile(string fname, out FileLock lock);

    /// 解锁文件
    /// Params: lock = 要释放的文件锁对象
    /// Returns: 操作状态
    Status unlockFile(FileLock lock);

    // 线程操作

    /// 将任务提交到后台线程池执行
    /// Params: task = 要执行的任务委托
    void schedule(void delegate() task);

    /// 在新线程中启动任务
    /// Params: task = 要执行的任务委托
    void startThread(void delegate() task);

    // 时间操作

    /// 获取当前时间的微秒数
    /// Returns: 自 Unix 纪元以来的微秒数
    ulong nowMicros() const;

    /// 休眠指定微秒数
    /// Params: micros = 休眠时长（微秒）
    void sleepForMicroseconds(int micros);

    // 日志

    /// 创建日志写入器
    /// Params: fname = 日志文件名, result = 输出的 Logger 对象
    /// Returns: 操作状态
    Status newLogger(string fname, out Logger result);
}

// ===== Cross-platform File I/O =====
// 这些类使用 std.stdio.File，在所有平台上均能正常工作

/**
 * 跨平台顺序读取文件
 */
class FileSequentialFile : SequentialFile
{
private:
    import std.stdio : File;
    File file_;

public:
    /// 构造顺序读取文件
    /// Params: fname = 文件名
    this(string fname)
    {
        file_ = File(fname, "rb");
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    Status read(size_t n, ref Slice result, ubyte[] scratch)
    {
        try
        {
            size_t bytesRead = file_.rawRead(scratch[0 .. n]).length;
            result = Slice(scratch.ptr, bytesRead);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("read: " ~ e.msg);
        }
    }

    Status skip(size_t n)
    {
        try
        {
            file_.seek(n);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("skip: " ~ e.msg);
        }
    }
}

/**
 * 跨平台随机读取文件（线程安全）
 */
class FileRandomAccessFile : RandomAccessFile
{
private:
    string filename_;
    import std.stdio : File;
    File file_;
    import core.sync.mutex;
    Mutex mutex_;

public:
    /// 构造随机读取文件
    /// Params: fname = 文件名
    this(string fname)
    {
        filename_ = fname;
        file_ = File(fname, "rb");
        mutex_ = new Mutex;
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    /// 关闭文件
    void close()
    {
        if (file_.isOpen())
            file_.close();
    }

    Status read(ulong offset, size_t n, ref Slice result, ubyte[] scratch) const
    {
        auto self = cast(FileRandomAccessFile) this;
        synchronized (self.mutex_)
        {
            try
            {
                self.file_.seek(cast(long) offset);
                size_t bytesRead = self.file_.rawRead(scratch[0 .. n]).length;
                result = Slice(scratch.ptr, bytesRead);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("read " ~ filename_ ~ ": " ~ e.msg);
            }
        }
    }
}

/**
 * 跨平台可写文件
 */
class FileWritableFile : WritableFile
{
private:
    import std.stdio : File;
    File file_;
    string filename_;
    bool closed_ = false;
    Mutex mutex_;

public:
    /// 构造可写文件
    /// Params: fname = 文件名
    this(string fname)
    {
        filename_ = fname;
        file_ = File(fname, "wb");
        mutex_ = new Mutex;
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    Status append(Slice data)
    {
        synchronized (mutex_)
        {
            try
            {
                file_.rawWrite(data.asBytes());
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("append " ~ filename_ ~ ": " ~ e.msg);
            }
        }
    }

    Status close()
    {
        synchronized (mutex_)
        {
            try
            {
                if (file_.isOpen())
                {
                    file_.flush();
                    version (Windows)
                    {
                        import core.sys.windows.winbase : FlushFileBuffers;
                        import core.stdc.stdio : _get_osfhandle;
                        FlushFileBuffers(cast(void*) _get_osfhandle(cast(int) file_.fileno()));
                    }
                    file_.close();
                }
                closed_ = true;
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("close " ~ filename_ ~ ": " ~ e.msg);
            }
        }
    }

    Status flush()
    {
        synchronized (mutex_)
        {
            try
            {
                file_.flush();
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("flush " ~ filename_ ~ ": " ~ e.msg);
            }
        }
    }

    Status sync()
    {
        synchronized (mutex_)
        {
            try
            {
                file_.flush();
                version (Windows)
                {
                    // Windows: 调用 FlushFileBuffers 将缓冲数据刷新到磁盘
                    import core.sys.windows.winbase : FlushFileBuffers;
                    import core.stdc.stdio : _get_osfhandle;
                    FlushFileBuffers(cast(void*) _get_osfhandle(cast(int) file_.fileno()));
                }
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("sync " ~ filename_ ~ ": " ~ e.msg);
            }
        }
    }
}

/**
 * 跨平台日志
 */
class FileLogger : Logger
{
private:
    import std.stdio : File;
    File file_;

public:
    /// 构造日志写入器
    /// Params: fname = 日志文件名
    this(string fname)
    {
        file_ = File(fname, "a");
    }

    ~this()
    {
        // 不在析构函数中调用close(),避免GC回收时访问无效内存
        // 调用者应显式调用close()
    }

    void logv(string msg)
    {
        import std.datetime : Clock;
        import std.format : format;
        auto now = Clock.currTime();
        file_.writeln(format("[%s] %s", now, msg));
        file_.flush();
    }
}

// ===== Platform-Specific Environment =====

/**
 * 环境公共基类
 * 封装所有平台无关的 Env 方法实现
 * 子类只需实现 lockFile/unlockFile 两个平台特定方法
 */
abstract class BaseEnv : Env
{
private:
    import core.sync.mutex;
    Mutex mutex_;
    TaskPool bgPool_;

public:
    this()
    {
        mutex_ = new Mutex;
    }

    Status newSequentialFile(string fname, out SequentialFile result)
    {
        try
        {
            result = new FileSequentialFile(fname);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("open " ~ fname ~ ": " ~ e.msg);
        }
    }

    Status newRandomAccessFile(string fname, out RandomAccessFile result)
    {
        try
        {
            result = new FileRandomAccessFile(fname);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("open " ~ fname ~ ": " ~ e.msg);
        }
    }

    Status newWritableFile(string fname, out WritableFile result)
    {
        try
        {
            result = new FileWritableFile(fname);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("open " ~ fname ~ ": " ~ e.msg);
        }
    }

    Status newAppendableFile(string fname, out WritableFile result)
    {
        return newWritableFile(fname, result);
    }

    bool fileExists(string fname) const
    {
        import std.file : exists;
        return exists(fname);
    }

    Status getChildren(string dir, out string[] result)
    {
        import std.file : dirEntries, SpanMode;
        try
        {
            result = [];
            foreach (de; dirEntries(dir, SpanMode.shallow))
            {
                import std.path : baseName;
                result ~= de.name.baseName;
            }
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("dir " ~ dir ~ ": " ~ e.msg);
        }
    }

    Status removeFile(string fname)
    {
        import std.file : remove;
        try
        {
            remove(fname);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("remove " ~ fname ~ ": " ~ e.msg);
        }
    }

    Status createDir(string dir)
    {
        import std.file : mkdirRecurse;
        try
        {
            mkdirRecurse(dir);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("mkdir " ~ dir ~ ": " ~ e.msg);
        }
    }

    Status removeDir(string dir)
    {
        import std.file : rmdir;
        try
        {
            rmdir(dir);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("rmdir " ~ dir ~ ": " ~ e.msg);
        }
    }

    Status getFileSize(string fname, out ulong size)
    {
        import std.file : getSize;
        try
        {
            size = getSize(fname);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("stat " ~ fname ~ ": " ~ e.msg);
        }
    }

    Status renameFile(string src, string dst)
    {
        import std.file : rename;
        try
        {
            rename(src, dst);
            return Status();
        }
        catch (Exception e)
        {
            return statusIoError("rename " ~ src ~ " -> " ~ dst ~ ": " ~ e.msg);
        }
    }

    void schedule(void delegate() fn)
    {
        if (bgPool_ is null)
        {
            synchronized (mutex_)
            {
                if (bgPool_ is null)
                {
                    auto pool = new TaskPool(1);
                    pool.isDaemon = true;
                    bgPool_ = pool;
                }
            }
        }
        bgPool_.put(task(fn));
    }

    void startThread(void delegate() fn)
    {
        task(fn).executeInNewThread();
    }

    ulong nowMicros() const
    {
        import std.datetime : Clock;
        import core.time : usecs;
        auto now = Clock.currTime();
        return cast(ulong) (now.toUnixTime() * 1_000_000L
            + now.fracSecs.total!"usecs");
    }

    void sleepForMicroseconds(int micros)
    {
        import core.thread : Thread;
        import core.time : dur;
        Thread.sleep(dur!"usecs"(micros));
    }

    Status newLogger(string fname, out Logger result)
    {
        result = new FileLogger(fname);
        return Status();
    }
}

version (Windows)
{
    import core.sys.windows.windows;

    /**
     * Windows文件锁
     * 使用 LockFileEx / UnlockFileEx 实现真正的文件锁定
     */
    class WindowsFileLock : FileLock
    {
        HANDLE hFile_;

        /// 构造 Windows 文件锁
        /// Params: h = 已打开的文件句柄
        this(HANDLE h)
        {
            hFile_ = h;
        }

        ~this()
        {
            // 不在析构函数中调用CloseHandle,避免GC回收时访问无效内存
            // 调用者应显式调用close()
        }
    }

    /**
     * Windows环境实现
     */
    class WindowsEnv : BaseEnv
    {
        Status lockFile(string fname, out FileLock lock)
        {
            import std.utf : toUTF16z;
            import std.conv : to;

            HANDLE h = CreateFileW(
                toUTF16z(fname),
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                null,
                OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                null
            );
            if (h == INVALID_HANDLE_VALUE)
                return statusIoError("lock " ~ fname ~ ": CreateFile failed");

            OVERLAPPED ov;
            ov.Offset = 0;
            ov.OffsetHigh = 0;
            ov.hEvent = null;
            ov.Internal = 0;
            ov.InternalHigh = 0;

            if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &ov))
            {
                DWORD err = GetLastError();
                CloseHandle(h);
                return statusIoError("lock " ~ fname ~ ": LockFileEx failed (error " ~ to!string(err) ~ ")");
            }

            lock = new WindowsFileLock(h);
            return Status();
        }

        Status unlockFile(FileLock lock)
        {
            auto wlock = cast(WindowsFileLock) lock;
            if (wlock is null || wlock.hFile_ == INVALID_HANDLE_VALUE)
                return Status();

            OVERLAPPED ov;
            ov.Offset = 0;
            ov.OffsetHigh = 0;
            ov.hEvent = null;
            ov.Internal = 0;
            ov.InternalHigh = 0;

            UnlockFileEx(wlock.hFile_, 0, 1, 0, &ov);
            CloseHandle(wlock.hFile_);
            wlock.hFile_ = INVALID_HANDLE_VALUE;
            return Status();
        }
    }

    /// 获取默认环境（TLS惰性初始化，线程安全）
    Env defaultEnv()
    {
        static WindowsEnv inst;
        if (inst is null)
            inst = new WindowsEnv();
        return inst;
    }
}
else
{
    /**
     * Posix文件锁
     */
    class PosixFileLock : FileLock
    {
        string filename_;
        /// 构造 Posix 文件锁
        /// Params: fname = 锁定的文件名
        this(string fname) { filename_ = fname; }
    }

    /**
     * Posix环境实现
     */
    class PosixEnv : Env
    {
    private:
        import core.sync.mutex;
        Mutex mutex_;
        TaskPool bgPool_;       /// 延迟初始化：首次调用 schedule() 时创建

    public:
        /// 构造 Posix 环境实例
        this()
        {
            mutex_ = new Mutex;
        }

        Status newSequentialFile(string fname, out SequentialFile result)
        {
            import std.stdio : File;
            try
            {
                result = new FileSequentialFile(fname);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("open " ~ fname ~ ": " ~ e.msg);
            }
        }

        Status newRandomAccessFile(string fname, out RandomAccessFile result)
        {
            try
            {
                result = new FileRandomAccessFile(fname);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("open " ~ fname ~ ": " ~ e.msg);
            }
        }

        Status newWritableFile(string fname, out WritableFile result)
        {
            try
            {
                result = new FileWritableFile(fname);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("open " ~ fname ~ ": " ~ e.msg);
            }
        }

        Status newAppendableFile(string fname, out WritableFile result)
        {
            return newWritableFile(fname, result);
        }

        bool fileExists(string fname) const
        {
            import std.file : exists;
            return exists(fname);
        }

        Status getChildren(string dir, out string[] result)
        {
            import std.file : dirEntries, SpanMode;
            try
            {
                result = [];
                foreach (de; dirEntries(dir, SpanMode.shallow))
                {
                    import std.path : baseName;
                    result ~= de.name.baseName;
                }
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("dir " ~ dir ~ ": " ~ e.msg);
            }
        }

        Status removeFile(string fname)
        {
            import std.file : remove;
            try
            {
                remove(fname);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("remove " ~ fname ~ ": " ~ e.msg);
            }
        }

        Status createDir(string dir)
        {
            import std.file : mkdirRecurse;
            try
            {
                mkdirRecurse(dir);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("mkdir " ~ dir ~ ": " ~ e.msg);
            }
        }

        Status removeDir(string dir)
        {
            import std.file : rmdir;
            try
            {
                rmdir(dir);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("rmdir " ~ dir ~ ": " ~ e.msg);
            }
        }

        Status getFileSize(string fname, out ulong size)
        {
            import std.file : getSize;
            try
            {
                size = getSize(fname);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("stat " ~ fname ~ ": " ~ e.msg);
            }
        }

        Status renameFile(string src, string dst)
        {
            import std.file : rename;
            try
            {
                rename(src, dst);
                return Status();
            }
            catch (Exception e)
            {
                return statusIoError("rename " ~ src ~ " -> " ~ dst ~ ": " ~ e.msg);
            }
        }

        Status lockFile(string fname, out FileLock lock)
        {
            lock = new PosixFileLock(fname);
            return Status();
        }

        Status unlockFile(FileLock lock)
        {
            // lock 参数由接口约束，unlock 在简化实现中为空操作
            return Status();
        }

        void schedule(void delegate() fn)
        {
            // 延迟初始化 TaskPool：不在 shared static this() 中创建，
            // 避免 D 运行时初始化期间的线程创建死锁。
            if (bgPool_ is null)
            {
                synchronized (mutex_)
                {
                    if (bgPool_ is null)
                    {
                        auto pool = new TaskPool(1);
                        pool.isDaemon = true;   // 守护线程，不阻止进程退出
                        bgPool_ = pool;
                    }
                }
            }
            // 使用 TaskPool 复用后台线程，避免每次创建新 OS 线程
            bgPool_.put(task(fn));
        }

        void startThread(void delegate() fn)
        {
            // startThread 语义为创建独立线程，不使用共享线程池
            task(fn).executeInNewThread();
        }

        ulong nowMicros() const
        {
            import std.datetime : Clock;
            import core.time : usecs;
            auto now = Clock.currTime();
            return cast(ulong) (now.toUnixTime() * 1_000_000L
                + now.fracSecs.total!"usecs");
        }

        void sleepForMicroseconds(int micros)
        {
            import core.thread : Thread;
            import core.time : dur;
            Thread.sleep(dur!"usecs"(micros));
        }

        Status newLogger(string fname, out Logger result)
        {
            result = new FileLogger(fname);
            return Status();
        }
    }

    /// 获取默认环境（TLS惰性初始化，线程安全）
    Env defaultEnv()
    {
        static PosixEnv inst;
        if (inst is null)
            inst = new PosixEnv();
        return inst;
    }
}
