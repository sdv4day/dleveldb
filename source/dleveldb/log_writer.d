module dleveldb.log_writer;

import dleveldb.slice;
import dleveldb.status;
import dleveldb.log_format;
import dleveldb.crc32c;
import dleveldb.coding;
import dleveldb.env;

/**
 * WAL日志写入器
 * 将逻辑记录写入物理块，自动分片
 */
class LogWriter
{
private:
    WritableFile dest_;
    ulong destLength_;     // 当前文件长度
    int blockOffset_;      // 当前块内偏移
    uint[5] typeCrc_;      // 每种记录类型的预计算CRC
    ubyte[] zeros_;        // 预分配的零填充缓冲区（堆上）

public:
    /// 构造WAL日志写入器
    ///
    /// Params:
    ///     dest = 目标可写文件
    ///     destLength = 当前文件长度
    this(WritableFile dest, ulong destLength = 0)
    {
        dest_ = dest;
        destLength_ = destLength;
        blockOffset_ = cast(int) (destLength % kBlockSize);

        // 预计算每种记录类型的CRC
        for (int i = 0; i <= cast(int) RecordType.last; i++)
        {
            ubyte[6] buf;
            buf[0] = 0; // length低字节
            buf[1] = 0; // length高字节
            buf[2] = cast(ubyte) i; // type
            buf[3] = 0; buf[4] = 0; buf[5] = 0; // padding
            typeCrc_[i] = crc32cValue(buf.ptr, 6);
        }

        // 预分配零填充缓冲区（堆上，避免每次调用动态分配）
        zeros_ = new ubyte[](kBlockSize);
        zeros_[] = 0;
    }

    /// 添加一条逻辑记录
    Status addRecord(Slice slice) 
    {
        const(ubyte)* ptr = slice.data();
        size_t left = slice.size();
        bool begin = true;

        Status s;
        do
        {
            int leftover = kBlockSize - blockOffset_;
            if (leftover < kHeaderSize)
            {
                // 当前块剩余空间不足，切换到新块
                if (leftover > 0)
                {
                    // 填充当前块剩余空间（使用预分配缓冲区）
                    s = dest_.append(Slice(zeros_.ptr, leftover));
                }
                blockOffset_ = 0;
            }

            // 计算可写入的字节数
            assert(kBlockSize - blockOffset_ >= kHeaderSize);
            size_t avail = kBlockSize - blockOffset_ - kHeaderSize;
            size_t fragmentLength = left < avail ? left : avail;

            RecordType type;
            bool end = (left == fragmentLength);
            if (begin && end)
            {
                type = RecordType.full;
            }
            else if (begin)
            {
                type = RecordType.first;
            }
            else if (end)
            {
                type = RecordType.last;
            }
            else
            {
                type = RecordType.middle;
            }

            s = emitPhysicalRecord(type, ptr, fragmentLength);
            if (!s.ok())
                return s;

            ptr += fragmentLength;
            left -= fragmentLength;
            begin = false;
        } while (left > 0);

        return Status();
    }

    /// 获取当前文件长度
    ulong fileLength() const pure @safe @nogc
    {
        return destLength_;
    }

private:
    /// 写入一条物理记录
    Status emitPhysicalRecord(RecordType type, const(ubyte)* ptr, size_t length) 
    {
        assert(length <= 0xffff); // 2字节长度限制
        assert(blockOffset_ + kHeaderSize + length <= kBlockSize);

        // 构造记录头
        ubyte[kHeaderSize] buf;
        buf[4] = cast(ubyte) (length & 0xff);
        buf[5] = cast(ubyte) (length >> 8);
        buf[6] = cast(ubyte) type;

        // 计算CRC
        uint crc = crc32cExtend(typeCrc_[cast(int) type], ptr, length);
        encodeFixed32(buf.ptr, crc);

        // 写入头
        Status s = dest_.append(Slice(buf.ptr, kHeaderSize));
        if (s.ok())
        {
            // 写入数据
            s = dest_.append(Slice(ptr, length));
            if (s.ok())
            {
                destLength_ += kHeaderSize + length;
                blockOffset_ += kHeaderSize + length;
            }
        }
        return s;
    }
}
