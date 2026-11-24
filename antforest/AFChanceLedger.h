#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 抽奖机会账本：只镜像服务端返回的机会数量，不发送任何抽奖/领奖 RPC。
/// 设计原则：服务端是唯一账本；本类只做"读取 + 本地缓存 + 展示"。
@interface AFChanceLedger : NSObject

+ (instancetype)sharedInstance;

/// 当前可用抽奖机会次数（来自最近一次识别到的服务端回包；无数据时为 0）
@property (nonatomic, assign, readonly) NSInteger availableChance;

/// 最近一次机会数的来源描述（例如 drawAsset.remainTimes），用于面板调试
@property (nonatomic, copy, readonly) NSString *lastSource;

/// 最近一次更新机会数的时间戳（Unix 秒）
@property (nonatomic, assign, readonly) NSTimeInterval lastUpdateTime;

/// 开关：账本功能是否启用。关闭后不再记录，但保留已有数据。
@property (nonatomic, assign) BOOL enabled;

/// 从回包中镜像机会数。只读取、不发包、不抽奖。
/// @param response transformResponseData 收到的完整回包字典（value）
- (void)mirrorChanceFromResponse:(id)response;

/// 手动把显示值归零（仅本地显示，不影响服务端真实数据）
- (void)resetLocalDisplay;

/// 最近的机会数变化日志（最多 40 条，最新在前）
+ (NSArray<NSString *> *)recentLogs;

@end

NS_ASSUME_NONNULL_END
