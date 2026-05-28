module examples.standalone_test;

/**
 * 独立测试脚本示例
 * 
 * 演示如何使用 dub --single 运行单个测试文件
 * 符合 Dlang_SP.md 第 4 节规范
 * 
 * 使用方法:
 *   dub --single examples/standalone_test.d
 */

/+ dub.sdl:
name "standalone_test"
dependency "silly" version="~>1.1.1"
+/

import std.stdio;
import silly;

// ====== 简单的工具函数 ======

/// 计算两个整数的最大公约数
int gcd(int a, int b) pure @safe @nogc
{
    while (b != 0)
    {
        int temp = b;
        b = a % b;
        a = temp;
    }
    return a;
}

/// 判断是否为质数
bool isPrime(int n) pure @safe @nogc
{
    if (n < 2) return false;
    if (n == 2) return true;
    if (n % 2 == 0) return false;
    
    for (int i = 3; i * i <= n; i += 2)
    {
        if (n % i == 0)
            return false;
    }
    return true;
}

/// 生成斐波那契数列
int[] fibonacci(int count) pure @safe
{
    int[] fib;
    fib.length = count;
    if (count > 0) fib[0] = 0;
    if (count > 1) fib[1] = 1;
    
    for (int i = 2; i < count; i++)
    {
        fib[i] = fib[i-1] + fib[i-2];
    }
    return fib;
}

// ====== 主函数 ======

void main()
{
    writeln("=== 独立测试脚本示例 ===");
    writeln("使用 dub --single 运行此文件");
    writeln();
    
    // 测试 1: GCD
    writeln("1. 最大公约数测试:");
    writeln("   gcd(12, 8) = ", gcd(12, 8));
    writeln("   gcd(54, 24) = ", gcd(54, 24));
    writeln("   gcd(17, 13) = ", gcd(17, 13));
    writeln();
    
    // 测试 2: 质数判断
    writeln("2. 质数判断测试:");
    foreach (n; [2, 3, 4, 5, 10, 13, 17, 20, 23, 29])
    {
        writeln("   ", n, " 是质数: ", isPrime(n));
    }
    writeln();
    
    // 测试 3: 斐波那契数列
    writeln("3. 斐波那契数列测试:");
    auto fib = fibonacci(10);
    write("   ");
    foreach (i, val; fib)
    {
        write(val);
        if (i < fib.length - 1)
            write(", ");
    }
    writeln();
    writeln();
    
    // 运行单元测试
    writeln("运行单元测试...");
    runUnitTests();
    writeln("所有测试通过！✓");
}

// ====== 单元测试 ======

void runUnitTests()
{
    // 测试 GCD
    assert(gcd(12, 8) == 4);
    assert(gcd(54, 24) == 6);
    assert(gcd(17, 13) == 1);
    assert(gcd(0, 5) == 5);
    assert(gcd(5, 0) == 5);
    
    // 测试质数
    assert(isPrime(2));
    assert(isPrime(3));
    assert(!isPrime(4));
    assert(isPrime(5));
    assert(!isPrime(10));
    assert(isPrime(13));
    assert(isPrime(17));
    assert(!isPrime(20));
    assert(isPrime(23));
    assert(isPrime(29));
    
    // 测试斐波那契
    auto fib = fibonacci(10);
    assert(fib.length == 10);
    assert(fib[0] == 0);
    assert(fib[1] == 1);
    assert(fib[5] == 5);
    assert(fib[9] == 34);
}
