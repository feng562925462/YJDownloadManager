//
//  YJDownloadOperation.m
//  HJDownloadManager
//
//  Created by cool on 2018/5/17.
//  Copyright © 2018 WHJ. All rights reserved.
//

#import "YJDownloadOperation.h"

#define kKVOBlock(KEYPATH,BLOCK)\
[self willChangeValueForKey:KEYPATH];\
BLOCK();\
[self didChangeValueForKey:KEYPATH];

#import <objc/runtime.h>
#import "YJDownloadModel.h"
#import "MJExtension.h"


@implementation NSURLSessionTask (YJModel)

/**
 *  添加downloadModel属性
 */
static const void *yj_downloadModelKey = @"downloadModelKey";

- (void)setDownloadModel:(YJDownloadModel *)downloadModel{
    objc_setAssociatedObject(self, &yj_downloadModelKey, downloadModel, OBJC_ASSOCIATION_ASSIGN);
}

- (YJDownloadModel *)downloadModel{
    return objc_getAssociatedObject(self, &yj_downloadModelKey);
}


@end

@interface YJDownloadOperation ()

@property (nonatomic, assign) BOOL yj_executing;
@property (nonatomic, assign) BOOL yj_finished;

@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) BOOL taskIsFinished;

@end


static const NSTimeInterval kTimeoutInterval = 60;

static NSString * const kIsExecuting = @"isExecuting";

static NSString * const kIsCancelled = @"isCancelled";

static NSString * const kIsFinished = @"isFinished";

@implementation YJDownloadOperation

MJCodingImplementation

- (instancetype)initWithDownloadModel:(YJDownloadModel *)downloadModel andSession:(NSURLSession *)session{
    self = [super init];
    if (self) {
        self.downloadModel = downloadModel;
        self.session = session;
        self.downloadModel.status = kYJDownloadStatus_Waiting;
    }
    return self;
}

- (void)dealloc{
    NSLog(@"任务已销毁");
}

#pragma mark - Public Method
- (void)startRequest{
    
    //已下载完成 || 任务未就绪 --> 则直接返回
    if (self.downloadModel.isFinished || !self.isReady) {
        return;
    }
    // 创建请求
    NSURL *url = [NSURL URLWithString:self.downloadModel.fileURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:kTimeoutInterval];
    
    // 设置请求头
    NSString *range = [NSString stringWithFormat:@"bytes=%ld-", (long)self.downloadModel.fileDownloadSize];
    [request setValue:range forHTTPHeaderField:@"Range"];
    
    if(!self.downloadTask){
        self.downloadTask = [self.session dataTaskWithRequest:request];
    }
    
    self.downloadTask.downloadModel = self.downloadModel;
    [self addObserver];
    
    [self.downloadTask resume];
}

// 进行检索获取Key
- (BOOL)observerKeyPath:(NSString *)key observer:(id )observer{
    
    id info = self.downloadTask.observationInfo;
    NSArray *array = [info valueForKey:@"_observances"];
    for (id objc in array) {
        id Properties = [objc valueForKeyPath:@"_property"];
        id newObserver = [objc valueForKeyPath:@"_observer"];
        
        NSString *keyPath = [Properties valueForKeyPath:@"_keyPath"];
        if ([key isEqualToString:keyPath] && [newObserver isEqual:observer]) {
            return YES;
        }
    }
    return NO;
}

- (void)addObserver{
    
    if (![self observerKeyPath:@"state" observer:self]) {
        [self.downloadTask addObserver:self
                            forKeyPath:@"state"
                               options:NSKeyValueObservingOptionNew
                               context:nil];
    }
}

- (void)removeObserver{
    
    if ([self observerKeyPath:@"state" observer:self]){
        [self.downloadTask removeObserver:self forKeyPath:@"state"];
    }
}

/** 挂起任务 */
- (void)suspend{
    
    NSLog(@"%@: currentThread = %@", NSStringFromSelector(_cmd), [NSThread currentThread]);
    
    kKVOBlock(kIsExecuting, ^{
        [self.downloadTask suspend];
        self.yj_executing = NO;
    });
}

/** 开始执行任务 */
- (void)startExcuting{
    
    NSLog(@"%@: currentThread = %@", NSStringFromSelector(_cmd), [NSThread currentThread]);
    
    kKVOBlock(kIsExecuting, ^{
        [self startRequest];
        self.yj_executing = YES;
    });
}


/** 开始执行任务 */
- (void)resume{
    
    //等待中的任务交给队列调度
    if (self.downloadModel.status == kYJDownloadStatus_Waiting)
        return;
    
    kKVOBlock(kIsExecuting, ^{
        [self startRequest];
        self.yj_executing  = YES;
    });
}


/** 任务已完成 */
- (void)completeOperation{
    
    [self willChangeValueForKey:kIsFinished];
    [self willChangeValueForKey:kIsExecuting];
    
    self.yj_executing  = NO;
    self.yj_finished = YES;
    
    [self didChangeValueForKey:kIsExecuting];
    [self didChangeValueForKey:kIsFinished];
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context{
    
    if ([keyPath isEqualToString:@"state"]) {
        
        NSInteger newState = [[change objectForKey:@"new"] integerValue];
        NSInteger oldState = [[change objectForKey:@"old"] integerValue];
        
        switch (newState) {
            case NSURLSessionTaskStateSuspended:
                self.downloadModel.status = kYJDownloadStatus_Suspended;
                //为进行任务管理 暂停任务后 直接取消
                [self cancel];
                break;
            case NSURLSessionTaskStateCompleted:{
                if (self.downloadModel.isFinished) {
                    self.downloadModel.status = kYJDownloadStatus_Completed;
                    [self cancel];
                }else{
                    if (self.downloadModel.status == kYJDownloadStatus_Suspended) {
                        
                    }else{// 下载失败
                        self.downloadModel.status = kYJDownloadStatus_Failed;
                    }
                }
            }break;
            case NSURLSessionTaskStateRunning:
                self.downloadModel.status = kYJDownloadStatus_Running;
                break;
            case NSURLSessionTaskStateCanceling:
                self.taskIsFinished = YES;
                break;
            default:
                break;
        }
        
        if (newState != oldState) {
            if (self.downloadStatusChangedBlock) {
                self.downloadStatusChangedBlock();
            }
        }
    }
}



#pragma mark - Override Methods
- (void)start{
    
    self.lock = [[NSLock alloc] init];
    [self.lock lock];
    //重写start方法时，要做好isCannelled的判断
    if ([self isCancelled]){
        //若已取消则设置状态已完成
        kKVOBlock(kIsFinished, ^{
            self.yj_finished = YES;
        });
        return;
    }
    
    kKVOBlock(kIsExecuting, ^{
        self.yj_executing  = YES;
    });
    
    //未取消则调用main方法来执行任务
    //经测试 加入operationQueue中后会自动开启新的线程执行 无需手动开启
    [NSThread currentThread].name = self.downloadModel.fileName.stringByDeletingPathExtension;
    [NSThread mainThread].name = @"主线程";
    [self main];
    [self.lock unlock];
}


- (void)main{
    
    @try {
        // 必须为自定义的 operation 提供 autorelease pool，因为 operation 完成后需要销毁。
        @autoreleasepool {
            // 提供一个变量标识，来表示需要执行的操作是否完成了，当然，没开始执行之前，为NO
            _taskIsFinished = NO;
            
            //只有当没有执行完成和没有被取消，才执行自定义的相应操作
            if (self.taskIsFinished == NO && [self isCancelled] == NO) {
                [self startExcuting];
            }
            
        }
    }@catch (NSException * e) {
        NSLog(@"Exception %@", e);
    }
}

- (BOOL)isExecuting{
    return self.yj_executing;
}


- (BOOL)isFinished{
    return self.yj_finished;
}

- (BOOL)isAsynchronous{
    return YES;
}
/**
 *  1.cancel方法调用后 该operation将会取消并从queue中移除
 *  2.若队列中有等待中的任务，将会自动执行
 */
- (void)cancel{
    
    BOOL isWaiting = self.downloadModel.status == kYJDownloadStatus_Waiting;
    [self.downloadTask cancel];
    [self removeObserver];
    [super cancel];
    //等待状态下取消时 无需将isFinished设置为已完成  等调用start方法时检测canceled来设置
    //参考：https://blog.csdn.net/loggerhuang/article/details/50015573
    if (!isWaiting) {
        [self completeOperation];
    }
}
@end
