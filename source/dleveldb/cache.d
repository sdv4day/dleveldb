module dleveldb.cache;

import cachetools.cache2q;
import core.sync.mutex;

/**
 * 默认缓存大小（10MB）
 */
enum DefaultCacheSize = 0x10_0000 * 10;

/**
 * LRU 缓存抽象基类
 * 
 * 提供泛型 get/put/remove 接口
 * 底层使用 2Q 缓存算法（比纯 LRU 更优）
 */
abstract class ACache
{
    /// 获取缓存元素数量
    abstract @property int length();

    /// 清空缓存
    abstract void clear();
}

/**
 * LRU 缓存实现（基于 2Q 算法）
 * 
 * 2Q 算法比纯 LRU 更好地处理扫描工作负载
 * 参考：http://www.vldb.org/conf/1994/P439.PDF
 * 
 * 示例：
 *   auto cache = new LRUCache!string(1024);
 *   cache.put(1, "hello");
 *   auto val = cache.get(1);
 */
final class LRUCache(V) : ACache
{
private:
    Cache2Q!(ulong, V) cache_;
    Mutex mutex_;

public:
    /// 构造LRU缓存
    /// Params: capacity = 缓存容量
    this(size_t capacity = DefaultCacheSize)
    {
        cache_ = new Cache2Q!(ulong, V)(cast(int) capacity);
        mutex_ = new Mutex;
    }

    /// 获取元素，未命中返回 Nullable!V
    auto get(ulong key)
    {
        synchronized (mutex_)
        {
            return cache_.get(key);
        }
    }

    /// 放入元素
    void put(ulong key, V value)
    {
        synchronized (mutex_)
        {
            cache_.put(key, value);
        }
    }

    /// 移除元素
    bool remove(ulong key)
    {
        synchronized (mutex_)
        {
            return cache_.remove(key);
        }
    }

    /// 元素数量
    override @property int length()
    {
        synchronized (mutex_)
        {
            return cache_.length;
        }
    }

    /// 清空
    override void clear()
    {
        synchronized (mutex_)
        {
            cache_.clear();
        }
    }
}
