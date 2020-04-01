//
//  CrashTool.m
//  WatchDogDemo02
//
//  Created by 无头骑士 GJ on 2020/3/27.
//  Copyright © 2020 无头骑士 GJ. All rights reserved.
//

#import "CrashTool.h"
#import <sys/utsname.h>
#import <UIKit/UIKit.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/resource.h>
#import <sys/time.h>
#import <mach/mach.h>
#import <mach/exc.h>
#import <mach/message.h>
#import <mach/port.h>
#import <mach/host_info.h>
#import <mach/exception.h>
#import <mach/exception_types.h>
#import <mach/task.h>
#import <mach/mach_time.h>
#import <mach/vm_map.h>
#import <pthread/pthread.h>
#import <mach-o/arch.h>
#import <mach-o/dyld.h>
#import <mach-o/ldsyms.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <sys/types.h>
#import <ifaddrs.h>
#import <resolv.h>
#import <cstring>
#import <string>
#import "list"


typedef struct
{
    mach_msg_header_t head;

    mach_msg_body_t msgh_body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;

    NDR_record_t NDR;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    uint64_t code[2];
    char pad[512];      // Avoiding MACH_MSG_RCV_TOO_LARGE
} MACH_REQUEST_MSG;

typedef struct
{
    mach_msg_header_t head;
    NDR_record_t NDR;
    kern_return_t return_code;
} MACH_REPLY_MSG;

// 系统内存信息
typedef struct _GJ_MEM_INFO_S
{
    uint32_t total_phy;           // 可用内核内存大小，单位KB
    uint32_t free_phy;            // 空闲内核内存大小，单位KB

    uint32_t resident_size;       // 常驻物理内存大小，单位KB
    uint32_t virtual_size;        // 进程虚拟内存大小，单位KB
} GJ_MEM_INFO_S;

// 系统时间定义
typedef struct _GJ_SYSTIME_S
{
    int year;             // 年，例如2012
    int month;            // 月，1~12
    int day;              // 日，1~31
    int hour;             // 小时，0~23
    int minute;           // 分钟，0~59
    int second;           // 秒，0~59
    int milli_seconds;    // 毫秒，0~999
} GJ_SYSTIME_S;

using namespace std;
#define MAX_STACK                   64


// 最大日志文件大小4MB
#define MAX_CRASH_LOG               (1 << 22)

// mach_msg超时
#define MACH_MSG_TIMEOUT    2000


// watchDog超时时间，单位毫秒
#define WATCHDOG_TIMEOUT    8000

// watchDog报警时间，单位毫秒
#define WATCHDOG_ALARM      3000

#define MEM_INFO_OS_TOTAL       "OS Total"
#define MEM_INFO_OS_FREE        "OS Free"
#define MEM_INFO_APP_RES        "App Resident"
#define MEM_INFO_APP_VIR        "App Virtual"

// Define thread state, type and count
#if defined __arm__
    #define THREAD_STATE            ARM_THREAD_STATE
    #define THREAD_STATE_TYPE       arm_thread_state32_t
    #define THREAD_STATE_COUNT      ARM_THREAD_STATE32_COUNT
#elif defined __arm64__
    #define THREAD_STATE            ARM_THREAD_STATE64
    #define THREAD_STATE_TYPE       arm_thread_state64_t
    #define THREAD_STATE_COUNT      ARM_THREAD_STATE64_COUNT
#elif defined __i386__
    #define THREAD_STATE            x86_THREAD_STATE
    #define THREAD_STATE_TYPE       i386_thread_state_t
    #define THREAD_STATE_COUNT      x86_THREAD_STATE_COUNT
#elif defined __x86_64__
    #define THREAD_STATE            x86_THREAD_STATE64
    #define THREAD_STATE_TYPE       x86_thread_state64_t
    #define THREAD_STATE_COUNT      x86_THREAD_STATE64
#endif

#define INSTACK(a)    ((a) >= stack_bot && (a) <= stack_top)

#if defined(__arm64__) || defined(__x86_64__)
#define    ISALIGNED(a)    ((((uintptr_t)(a)) & 0xf) == 0)
#elif defined(__arm__)
#define    ISALIGNED(a)    ((((uintptr_t)(a)) & 0x1) == 0)
#elif defined(__i386__)
#define    ISALIGNED(a)    ((((uintptr_t)(a)) & 0xf) == 8)
#endif

// Read PC register from thread state
#if defined __arm__
#define GJ_READ_PC(ts) ((void *)(ts->__pc))
#elif defined __arm64__
#define GJ_READ_PC(ts) ((void *)(ts->__pc))
#elif defined __i386__
#define GJ_READ_PC(ts) ((void *)(ts->__eip))
#elif defined __x86_64__
#define GJ_READ_PC(ts) ((void *)(ts->__rip))
#endif


// Read FP register from thread state
// Register R7 is used as a frame pointer
// Ref: https://developer.apple.com/library/ios/documentation/Xcode/Conceptual/
// iPhoneOSABIReference/Articles/ARMv6FunctionCallingConventions.html
#if defined __arm__
#define GJ_READ_FP(ts) ((void **)(ts->__r[7]))
#elif defined __arm64__
#define GJ_READ_FP(ts) ((void **)(ts->__fp))
#elif defined __i386__
#define GJ_READ_FP(ts) ((void **)(ts->__ebp))
#elif defined __x86_64__
#define GJ_READ_FP(ts) ((void **)(ts->__rbp))
#endif


struct DeviceInfo {
public:
    string m_device_name;
    string m_model_name;
    string m_system_name;
    string m_system_version;
    string m_cpu_name;
    string m_app_ver;
    string m_app_build_id;
    
    DeviceInfo()
    {
        // 获取设备别名
        GJiOSGetDeviceName(m_device_name);
        // 获取产品型号名称
        GJiOSGetModelName(m_model_name);
        // 获取系统名称
        GJGetSystemName(m_system_name);
        // 获取系统版本
        GJGetSystemVersion(m_system_version);
        // 获取CPU
        GJGetCPU(m_cpu_name);
        // 获取AppVersion
        GJGetAppInfo(m_app_ver);
        // 获取buildId
        GJGetAppBuildID(m_app_build_id);
       
    }
    // 获取buildId
    void GJGetAppBuildID(string &app_build_id)
    {
//
//       string build_uuid;
//       string code_type;
//       GJiOSGetAppBuildUuid(build_uuid);
//       GJiOSGetCodeTypeName(code_type);
//       GGSprintf(&g_app_build_id, "%s (%s)", build_uuid.c_str(), code_type.c_str());
    }
    
    // App version
    void GJGetAppInfo(string &app_version)
    {
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSString *displayName = [infoDictionary objectForKey: @"CFBundleDisplayName"];
        NSString *shortVersion = [infoDictionary objectForKey: @"CFBundleShortVersionString"];
        app_version.assign([[NSString stringWithFormat:@"%@_%@", displayName, shortVersion] UTF8String]);
    }
    
    // 获取CPU
    void GJGetCPU(string &cpu_name)
    {
        const NXArchInfo *archInfo = NXGetLocalArchInfo();

        if (archInfo)
        {
            cpu_name.assign(archInfo->description);
            cpu_name.append(" width cores(s)");
        }
    }
    
    // 获取系统版本
    void GJGetSystemVersion(string &system_version)
    {
        system_version = [[[UIDevice currentDevice] systemVersion] UTF8String];
    }
    
    // 获取系统名称
    void GJGetSystemName(string &system_name)
    {
        system_name = [[[UIDevice currentDevice] systemName] UTF8String];
    }
    
    // 获取设备别名
    void GJiOSGetDeviceName(string &device_name)
    {
        NSString *name = [[UIDevice currentDevice] name];
        if (name) device_name.assign([name UTF8String]);
    }
    
    // 获取产品型号名称
    void GJiOSGetModelName(string &model_name)
    {
        // 型号名称和代号的映射表，参考自https://gist.github.com/adamawolf/3048717
        static NSDictionary* modelNameMap =
        @{
            @"i386"       : @"iPhone Simulator",
            @"x86_64"     : @"iPhone Simulator",
            @"iPhone1,1"  : @"iPhone",
            @"iPhone1,2"  : @"iPhone 3G",
            @"iPhone2,1"  : @"iPhone 3GS",
            @"iPhone3,1"  : @"iPhone 4",
            @"iPhone3,2"  : @"iPhone 4 GSM Rev A",
            @"iPhone3,3"  : @"iPhone 4 CDMA",
            @"iPhone4,1"  : @"iPhone 4S",
            @"iPhone5,1"  : @"iPhone 5 (GSM)",
            @"iPhone5,2"  : @"iPhone 5 (GSM+CDMA)",
            @"iPhone5,3"  : @"iPhone 5C (GSM)",
            @"iPhone5,4"  : @"iPhone 5C (Global)",
            @"iPhone6,1"  : @"iPhone 5S (GSM)",
            @"iPhone6,2"  : @"iPhone 5S (Global)",
            @"iPhone7,1"  : @"iPhone 6 Plus",
            @"iPhone7,2"  : @"iPhone 6",
            @"iPhone8,1"  : @"iPhone 6S",
            @"iPhone8,2"  : @"iPhone 6S Plus",
            @"iPhone8,3"  : @"iPhone SE (GSM+CDMA)",
            @"iPhone8,4"  : @"iPhone SE (GSM)",
            @"iPhone9,1"  : @"iPhone 7",
            @"iPhone9,2"  : @"iPhone 7 Plus",
            @"iPhone9,3"  : @"iPhone 7",
            @"iPhone9,4"  : @"iPhone 7 Plus",
            @"iPhone10,1" : @"iPhone 8",
            @"iPhone10,2" : @"iPhone 8 Plus",
            @"iPhone10,3" : @"iPhone X Global",
            @"iPhone10,4" : @"iPhone 8",
            @"iPhone10,5" : @"iPhone 8 Plus",
            @"iPhone10,6" : @"iPhone X GSM",
            @"iPhone11,2" : @"iPhone XS",
            @"iPhone11,4" : @"iPhone XS Max",
            @"iPhone11,6" : @"iPhone XS Max Global",
            @"iPhone11,8" : @"iPhone XR",
            @"iPad1,1"    : @"iPad",
            @"iPad1,2"    : @"iPad 3G",
            @"iPad2,1"    : @"iPad 2",
            @"iPad2,2"    : @"iPad 2 GSM",
            @"iPad2,3"    : @"iPad 2 CDMA",
            @"iPad2,4"    : @"iPad 2 New Revision",
            @"iPad3,1"    : @"iPad 3",
            @"iPad3,2"    : @"iPad 3 CDMA",
            @"iPad3,3"    : @"iPad 3 GSM",
            @"iPad2,5"    : @"iPad mini",
            @"iPad2,6"    : @"iPad mini GSM+LTE",
            @"iPad2,7"    : @"iPad mini CDMA+LTE",
            @"iPad3,4"    : @"iPad 4",
            @"iPad3,5"    : @"iPad 4 GSM+LTE",
            @"iPad3,6"    : @"iPad 4 CDMA+LTE",
            @"iPad4,1"    : @"iPad Air (WiFi)",
            @"iPad4,2"    : @"iPad Air (GSM+CDMA)",
            @"iPad4,3"    : @"iPad Air (China)",
            @"iPad4,4"    : @"iPad mini Retina (WiFi)",
            @"iPad4,5"    : @"iPad mini Retina (GSM+CDMA)",
            @"iPad4,6"    : @"iPad mini Retina (China)",
            @"iPad4,7"    : @"iPad mini 3 (WiFi)",
            @"iPad4,8"    : @"iPad mini 3 (GSM+CDMA)",
            @"iPad4,9"    : @"iPad mini 3 (China)",
            @"iPad5,1"    : @"iPad mini 4 (WiFi)",
            @"iPad5,2"    : @"iPad mini 4 (WiFi+Cellular)",
            @"iPad5,3"    : @"iPad Air 2 (WiFi)",
            @"iPad5,4"    : @"iPad Air 2 (Cellular)",
            @"iPad6,3"    : @"iPad Pro (9.7 inch, WiFi)",
            @"iPad6,4"    : @"iPad Pro (9.7 inch, WiFi+LTE)",
            @"iPad6,7"    : @"iPad Pro (12.9 inch, WiFi)",
            @"iPad6,8"    : @"iPad Pro (12.9 inch, WiFi+LTE)",
            @"iPad6,11"   : @"iPad (2017)",
            @"iPad6,12"   : @"iPad (2017)",
            @"iPad7,1"    : @"iPad Pro 2 (WiFi)",
            @"iPad7,2"    : @"iPad Pro 2 (WiFi+Cellular)",
            @"iPad7,3"    : @"iPad Pro 10.5-inch",
            @"iPad7,4"    : @"iPad Pro 10.5-inch",
            @"iPad7,5"    : @"iPad 6 (WiFi)",
            @"iPad7,6"    : @"iPad 6 (WiFi+Cellular)",
            @"iPad8,1"    : @"iPad Pro 3 (11 inch, WiFi)",
            @"iPad8,2"    : @"iPad Pro 3 (11 inch, 1TB, WiFi)",
            @"iPad8,3"    : @"iPad Pro 3 (11 inch, WiFi+Cellular)",
            @"iPad8,4"    : @"iPad Pro 3 (11 inch, 1TB, WiFi+Cellular)",
            @"iPad8,5"    : @"iPad Pro 3 (12.9 inch, WiFi)",
            @"iPad8,6"    : @"iPad Pro 3 (12.9 inch, 1TB, WiFi)",
            @"iPad8,7"    : @"iPad Pro 3 (12.9 inch, WiFi+Cellular)",
            @"iPad8,8"    : @"iPad Pro 3 (12.9 inch, 1TB, WiFi+Cellular)"
        };

        // 型号名称modelName定义为静态的，两个好处
        // 1. 避免返回局部临时变量，引起未知异常
        // 2. 缓存查询结果，提升性能
        struct utsname sysinfo;
        uname(&sysinfo);
        NSString *codeName = [NSString stringWithCString:sysinfo.machine encoding:NSASCIIStringEncoding];
        NSString *modelNameForCode = [modelNameMap objectForKey: codeName];

        if (modelNameForCode)
        {
            model_name = [modelNameForCode UTF8String];
        }
        else
        {
            model_name = [codeName UTF8String];
        }

    }
    
};

static struct DeviceInfo deviceInfo;
//static string g_crach_s = "";
static char *g_crach_s = NULL;


// 主线程ID
static int32_t g_main_thread_id = 0;

// 线程锁
static pthread_mutex_t g_watchdog_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_last_feed_time = 0;


// 临终遗言
static string g_last_note;


// 自启动以来的毫秒数
uint64_t GJiOSGetUpTime()
{
    // 参考 https://github.com/curl/curl/pull/3048/files/ad73b50ac72c48999c774132c988fcb527139a44
    if (@available(iOS 10, *))
    {
        // 必须用available关键字说明，直接调用会导致在iOS 9设备上因为_clock_gettime符号
        // 找不到而启动崩溃
        struct timespec tp;

        if (!clock_gettime(CLOCK_MONOTONIC, &tp))
        {
            uint64_t up_time = tp.tv_sec * 1000ULL + tp.tv_nsec / 1000000;
            return up_time;
        }
    }

    return (uint64_t)([[NSProcessInfo processInfo] systemUptime] * 1000.0);
}



static size_t GJiOSGetStackSize(pthread_t thread)
{
    // Ref: https://github.com/robovm/robovm/issues/274
    // pthread_get_stacksize_np returns wrong value (512kB) on MAC OS/X 10.9 and iOS 7
    // for the main thread. According to https://developer.apple.com/library/mac/docum
    // entation/Cocoa/Conceptual/Multithreading/CreatingThreads/CreatingThreads.html,
    // the stack size for the main thread should be 8MB and 1MB for MAC OS/X and iOS

    // Check if the thread is the main thread. The method is copied from
    // http://www.opensource.apple.com/source/Libc/Libc-498.1.1/pthreads/pthread.c

#ifndef _PTHREAD_CREATE_PARENT
#define _PTHREAD_CREATE_PARENT 4
#endif

    // Ref: http://www.opensource.apple.com/source/Libc/Libc-498.1.1/pthreads/pthread_internals.h
    char *bytes = (char *)thread;

    // Hacked with hardcoded offset
#ifndef __LP64__
    char detached = bytes[16];
#else
    char detached = bytes[24];
#endif

    if ((detached & _PTHREAD_CREATE_PARENT) == _PTHREAD_CREATE_PARENT)
    {
        // 1MB for iOS main thread
        return 1u << 20;
    }

    return pthread_get_stacksize_np(thread);
}

// 获取当前应用构建唯一标识
void GJiOSGetAppBuildUuid(string &build_uuid)
{
#if TARGET_IPHONE_SIMULATOR
    build_uuid.clear();
#else
    const struct mach_header *mh_execute_header =
        (const struct mach_header *)dlsym(RTLD_MAIN_ONLY, MH_EXECUTE_SYM);
    if (!mh_execute_header)
    {
        return;
    }

    const uint8_t *command = (const uint8_t *)(mh_execute_header + 1);

    for (uint32_t i = 0; i < mh_execute_header->ncmds; ++i)
    {
        const struct load_command *load_command = (const struct load_command *)command;

        if (load_command->cmd == LC_UUID)
        {
            const struct uuid_command *uuid_command = (const struct uuid_command *)command;
            const uint8_t *uuid = uuid_command->uuid;
            char *temp = strdup(build_uuid.c_str());
            sprintf(temp, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                       uuid[0],
                       uuid[1],
                       uuid[2],
                       uuid[3],
                       uuid[4],
                       uuid[5],
                       uuid[6],
                       uuid[7],
                       uuid[8],
                       uuid[9],
                       uuid[10],
                       uuid[11],
                       uuid[12],
                       uuid[13],
                       uuid[14],
                       uuid[15]);
            build_uuid.assign(temp);
        }
        else
        {
            command += load_command->cmdsize;
        }
    }
#endif
}

// 获取当前运行代码类型名称(armv7/armv7s/arm64/i386/x86_64)
const string & GJiOSGetCodeTypeName(string &code_type_name)
{
#if defined   __ARM_ARCH_7A__
    code_type_name = "armv7";
#elif defined __ARM_ARCH_7S__
    code_type_name = "armv7s";
#elif defined __ARM_ARCH_ISA_A64
    code_type_name = "arm64";
#elif defined __i386__
    code_type_name = "i386";
#elif defined __x86_64__
    code_type_name = "x86_64";
#else
    code_type_name = "unknown";
#endif
    return code_type_name;
}


// 获取系统内存分页大小
uint32_t GJSysGetPageSize()
{
    static uint32_t page_size = 0;

    if (page_size)
    {
        return page_size;
    }

#ifdef __APPLE__
    // 2016-01-29 huxiaoxiang 00160924
    // getpagesize() returns 16KB on iOS 64bit, but it's not true.
    // If you use that value for host_statistics with HOST_VM_INFO, you'll
    // see the free memory may be greater than total physical memory.

    // BTW, getpagesize is deprecated by apple:
    // unistd.h:int     getpagesize(void) __pure2 __POSIX_C_DEPRECATED(199506L);

    // http://stackoverflow.com/questions/21552747/strange-behavior-on-64bit-ios-devices-when-retrieving-vm-statistics
    // https://opensource.apple.com/source/xnu/xnu-3247.1.106/libsyscall/mach/mach_init.c

    // After researching on stackoverflow.com and opensource.apple.com, I found
    // that there are two global variables holding page size which are vm_kernel_page_size
    // and vm_page_size.
    // getpagesize() & sysctl(HW_PAGESIZE ) returns vm_page_size which is 16K on iOS 64bit
    // host_page_size returns vm_kernel_page_size which is 4KB on iOS 64bit
    // page_size = (UINT32)getpagesize();

    // Update 2017-05-12 huxiaoxiang 00160924
    // host_page_size also returns 16KB on iPhone7 Plus with iOS 10.0.3 which is NOT a bug!

    // https://developer.apple.com/library/content/documentation/Performance/Conceptual/ManagingMemory/Articles/AboutMemory.html
    // In OS X and in earlier versions of iOS, the size of a page is 4 kilobytes. In later
    // versions of iOS, A7- and A8-based systems expose 16-kilobyte pages to the 64-bit userspace
    // backed by 4-kilobyte physical pages, while A9 systems expose 16-kilobyte pages backed by
    // 16-kilobyte physical pages.

    vm_size_t size;
    host_page_size(mach_host_self(), &size);
    page_size = (uint32_t)size;
#endif

    return page_size;
}

// 获取系统内存信息
int32_t GJSysGetMemInfo(GJ_MEM_INFO_S *mem_info)
{

    // Get total memory
    // 2017-05-12 huxiaoxiang Fix negative mem got on iPhone7Plus
    // int mem = 0;
    uint32_t mem = 0;
    int mib[2] = {CTL_HW, HW_USERMEM}; // HW_USERMEM usable by user program, HW_PHYSMEM is also an
                                       // option
    size_t length = sizeof(mem);
    sysctl(mib, 2, &mem, &length, NULL, 0);
    mem_info->total_phy = mem >> 10;

    // Get free memory
    // DTS2017101006468 host_statistics64接口在iOS11下阻塞0~3秒不等，换成host_statistics接口可以规避
    vm_statistics_data_t vmstat;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;

    if (KERN_SUCCESS !=
        host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmstat, &count))
    {
        return -1;
    }

    mem_info->free_phy = vmstat.free_count * (GJSysGetPageSize() >> 10);

    task_basic_info_64_data_t task_basic_info;
    count = sizeof(task_basic_info);

    task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&task_basic_info, &count);

    mem_info->resident_size = (uint32_t)(task_basic_info.resident_size >> 10);
    mem_info->virtual_size  = (uint32_t)(task_basic_info.virtual_size  >> 10);


    return 0;
}

/* Ref: http://www.opensource.apple.com/source/Libc/Libc-825.25/gen/thread_stack_pcs.c */
static uint32_t GJiOSGetStackTrace(pthread_t          thread,
                                  THREAD_STATE_TYPE *ts,
                                  void **            buffer,
                                  uint32_t             size)
{
    if (!thread || !ts || !buffer || !size)
    {
        return 0;
    }

    // Get stack size of the thread
    size_t stack_size = GJiOSGetStackSize(thread);
    void *stack_top = pthread_get_stackaddr_np(thread);
    void *stack_bot = static_cast <char *> (stack_top) - stack_size;

    // Make sure return address is never out of bounds
    stack_bot = (void *)((long)stack_bot - 2 * sizeof(void *));

    // Current instruction address
    void *pc = GJ_READ_PC(ts);
    uint32_t count = 0;
    buffer[count++] = pc;
    size--;

    // First return address was hold in link register under ARM
#if defined __arm__ || defined __arm64__
    buffer[count++] = (void *)ts->__lr;
    size--;
#endif

    // Frame pointer
    // __builtin_frame_address(0); is for current thread only!
    void **fp = GJ_READ_FP(ts);

    if (!INSTACK(fp) || !ISALIGNED(fp))
    {
        return count;
    }

    while (size--)
    {
        // Read next frame pointer
        void **next = (void **)*fp;

        // Read return address
        buffer[count++] = *(fp + 1);

        if (!INSTACK(next) || !ISALIGNED(next) || (next <= fp))
        {
            break;
        }
        fp = next;
    }

    return count;
}


// 获取系统当前时间
void GJGetCurrentFullTime(GJ_SYSTIME_S *systime)
{

    struct timeval tv;
    struct tm local_time;

    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &local_time);
    systime->year  = 1900 + local_time.tm_year;
    systime->month = local_time.tm_mon + 1;
    systime->day  = local_time.tm_mday;
    systime->hour = local_time.tm_hour;
    systime->minute = local_time.tm_min;
    systime->second = local_time.tm_sec;
    systime->milli_seconds = tv.tv_usec / 1000;
}

void WTGetCurrentFullTime(GJ_SYSTIME_S *systime);


static void GJiOSAnrAlarmHandler(int64_t elapsed)
{

    GJ_SYSTIME_S systime;
    GJGetCurrentFullTime(&systime);

    int pos = sprintf(g_crach_s, "\r\n[%04d-%02d-%02d %02d:%02d:%02d.%03d] Watchdog alarm! The application hasn't respond to system events for %.2f seconds.\r\n",
                              systime.year,
                              systime.month,
                              systime.day,
                              systime.hour,
                              systime.minute,
                              systime.second,
                              systime.milli_seconds,
                              elapsed / 1000.0);
    uint32_t cpu = 0;
    GJ_MEM_INFO_S mem_info;

    if (0 == GJSysGetMemInfo(&mem_info))
    {
        pos += sprintf(g_crach_s + pos,
                          "CPU Usage:%u%%\r\n"
                          "OS Total:%uMB\r\n"
                          "OS Free:%uMB\r\n"
                          "App Resident:%uMB\r\n"
                          "App Virtual:%uMB\r\n",
                          cpu,
                          mem_info.total_phy >> 10,
                          mem_info.free_phy >> 10,
                          mem_info.resident_size >> 10,
                          mem_info.virtual_size >> 10);
    }

    // 先暂停住
    thread_suspend(g_main_thread_id);

    // 获取线程上下文
    THREAD_STATE_TYPE ts;
    mach_msg_type_number_t number = THREAD_STATE_COUNT;
    thread_get_state(g_main_thread_id, THREAD_STATE, (thread_state_t)&ts, &number);

    // 获取调用栈
    void *stacks[MAX_STACK];
    pthread_t thread  = pthread_from_mach_thread_np(g_main_thread_id);
    uint32_t stack_size = GJiOSGetStackTrace(thread, &ts, stacks, MAX_STACK);

    
    
    // 恢复主线程
    thread_resume(g_main_thread_id);

    if (stack_size > 0)
    {
        pos += sprintf(g_crach_s + pos,
                          "Call stacks of main thread %d:\r\n",
                          g_main_thread_id);

        for (uint32_t i = 0; i < stack_size; i++)
        {
            char module_info[128];
            char symbol_info[128];
            void * address = stacks[i];
            Dl_info dlinfo;

            if (dladdr(address, &dlinfo))
            {
                if (dlinfo.dli_fname && dlinfo.dli_fbase)
                {
                    // 提取模块名
                    const char *module_name = (const char *)strrchr(dlinfo.dli_fname, '/');

                    if (NULL == module_name)
                    {
                        module_name = dlinfo.dli_fname;
                    }
                    else
                    {
                        module_name++;
                    }

                    sprintf(module_info, "%s + 0x%lx", module_name, (u_long)address - (u_long)dlinfo.dli_fbase);
                }

                if (dlinfo.dli_sname && dlinfo.dli_saddr)
                {
                    sprintf(symbol_info, "(%s + 0x%lx)", dlinfo.dli_sname, (u_long)address - (u_long)dlinfo.dli_saddr);
                }
            }

            pos += sprintf(g_crach_s + pos,
#ifdef __LP64__
                              "Call Stack %02u: 0x%016lx %48s %s\r\n",
#else
                              "Call Stack %02u: 0x%08lx %48s %s\r\n",
#endif
                              i,
                              (u_long)address,
                              module_info,
                              symbol_info);
        }
    }

    // 这里只用NSLog，避免崩溃日志里面出现重复信息
    NSLog(@"%s", g_crach_s);
}

static void GJiOSCheckWatchDog()
{
    // 获取当前时间
    uint64_t curr = GJiOSGetUpTime();

    // 获取上一次主线程的时间
    pthread_mutex_lock(&g_watchdog_lock);
    uint64_t last_feed_time = g_last_feed_time;
    pthread_mutex_unlock(&g_watchdog_lock);
    
    // 说明已经开始警告了
    if (last_feed_time && (curr > last_feed_time + WATCHDOG_ALARM))
    {
        GJiOSAnrAlarmHandler(curr - last_feed_time);
    }

    // 主线程更新一次时间
    dispatch_async(dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&g_watchdog_lock);
        g_last_feed_time = GJiOSGetUpTime();
        pthread_mutex_unlock(&g_watchdog_lock);
    });
}

static void *GJRunLoop(void * /* param */)
{
    // 创建MACH消息监听端口
    task_t task_self = mach_task_self();
    mach_port_t server_port = MACH_PORT_NULL;
    // 内核中创建一个消息队列，获取对应的port
    mach_port_allocate(task_self, MACH_PORT_RIGHT_RECEIVE, &server_port);
    // 授予task对port的指定权限
    mach_port_insert_right(task_self, server_port, server_port, MACH_MSG_TYPE_MAKE_SEND);
    exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_GUARD | EXC_MASK_RESOURCE;

    task_set_exception_ports(task_self,
                             mask,
                             server_port,
                             EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES,
                             MACHINE_THREAD_STATE);

    MACH_REQUEST_MSG request;
    


    for (;;)
    {
        memset_s(&request, sizeof(MACH_REQUEST_MSG), 0, sizeof(MACH_REQUEST_MSG));
        request.head.msgh_local_port = server_port;
        request.head.msgh_size = sizeof(MACH_REQUEST_MSG);
        
        // 通过设定参数：MACH_RSV_MSG/MACH_SEND_MSG用于接收/发送mach message
        mach_msg_return_t result = mach_msg((mach_msg_header_t *)&request,
                                            MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT,
                                            0,
                                            sizeof(MACH_REQUEST_MSG),
                                            server_port,
                                            MACH_MSG_TIMEOUT,
                                            MACH_PORT_NULL);

        if (MACH_MSG_SUCCESS == result)
        {
            
        }
        else
        {
            GJiOSCheckWatchDog();
        }
    }
}



void GJiOSInitCrashReport()
{
    // 全局日志
    g_crach_s = (char *)malloc(MAX_CRASH_LOG);
    if (g_crach_s == NULL) return;
    memset_s(g_crach_s, MAX_CRASH_LOG, 0, MAX_CRASH_LOG);

    // 创建RunLoop检查
    pthread_t thread = NULL;
    pthread_create(&thread, NULL, GJRunLoop, NULL);
    if (thread) pthread_detach(thread);
}

void __attribute__ ((constructor(101))) GJInitTool()
{
    @autoreleasepool
    {
        // 获取主线程ID
        g_main_thread_id = pthread_mach_thread_np(pthread_self());

        // 初始化
        GJiOSInitCrashReport();

    
    }
}
