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
    Status append(Slice data);
    Status close();
    Status flush();
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
    void logv(string msg);
}

/**
 * 环境抽象接口
 * 提供文件系统操作和线程调度
 */
interface Env
{
    // 文件操作
    Status newSequentialFile(string fname, out SequentialFile result);
    Status newRandomAccessFile(string fname, out RandomAccessFile result);
    Status newWritableFile(string fname, out WritableFile result);
    Status newAppendableFile(string fname, out WritableFile result);

    // 文件系统操作
    bool fileExists(string fname) const;
    Status getChildren(string dir, out string[] result);
    Status removeFile(string fname);
    Status createDir(string dir);
    Status removeDir(string dir);
    Status getFileSize(string fname, out ulong size);
    Status renameFile(string src, string dst);
    Status lockFile(string fname, out FileLock lock);
    Status unlockFile(FileLock lock);

    // 线程操作
    void schedule(void delegate() task);
    void startThread(void delegate() task);

    // 时间操作
    ulong nowMicros() const;
    void sleepForMicroseconds(int micros);

    // 日志
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
    this(string fname)
    {
        file_ = File(fname, "rb");
    }

    ~this()
    {
        if (file_.isOpen())
            file_.close();
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
    this(string fname)
    {
        filename_ = fname;
        file_ = File(fname, "rb");
        mutex_ = new Mutex;
    }

    ~this()
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
    this(string fname)
    {
        filename_ = fname;
        file_ = File(fname, "wb");
        mutex_ = new Mutex;
    }

    ~this()
    {
        if (!closed_)
            close();
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
                    file_.close();
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
                    // Windows: 调用 _commit 将缓冲数据刷新到磁盘
                    // _commit 是 Windows CRT 函数，接受 int 类型的文件描述符
                    extern (C) nothrow @nogc int _commit(int fd);
                    _commit(cast(int) file_.fileno());
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
    this(string fname)
    {
        file_ = File(fname, "a");
    }

    ~this()
    {
        if (file_.isOpen())
            file_.close();
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

        this(HANDLE h)
        {
            hFile_ = h;
        }

        ~this()
        {
            if (hFile_ != INVALID_HANDLE_VALUE)
                CloseHandle(hFile_);
        }
    }

    /**
     * Windows环境实现
     */
    class WindowsEnv : Env
    {
    private:
        Mutex mutex_;
        TaskPool bgPool_;

    public:
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

    /// 全局默认 Windows 环境实例
    __gshared WindowsEnv windowsEnv_;

    shared static this()
    {
        windowsEnv_ = new WindowsEnv();
    }

    /// 获取默认环境
    Env defaultEnv() nothrow @nogc
    {
        return windowsEnv_;
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

    /// 全局默认 Posix 环境实例
    __gshared PosixEnv posixEnv_;

    shared static this()
    {
        posixEnv_ = new PosixEnv();
    }

    /// 获取默认环境
    Env defaultEnv() nothrow @nogc
    {
        return posixEnv_;
    }
}
