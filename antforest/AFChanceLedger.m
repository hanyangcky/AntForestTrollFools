#import "AFChanceLedger.h"

static NSString * const kChanceValueKey      = @"AFChanceLedger.availableChance";
static NSString * const kChanceSourceKey     = @"AFChanceLedger.lastSource";
static NSString * const kChanceUpdateKey     = @"AFChanceLedger.lastUpdateTime";
static NSString * const kChanceEnabledKey    = @"AFChanceLedger.enabled";
static NSString * const kChanceLogKey        = @"AFChanceLedger.recentLogs";

/// 只有在回包里出现这些"抽奖场景标记"时才扫描，避免误抓蚂蚁森林能量数字。
static NSArray<NSString *> *AFLotteryMarkers(void) {
    return @[@"drawasset", @"drawentrancevo", @"drawactivity", @"drawprize",
             @"lottery", @"chouChouLe", @"drawtask", @"drawchance", @"drawtimes"];
}

/// 机会字段候选关键词（命中越多分越高）。
static NSArray<NSString *> *AFChanceKeyHints(void) {
    return @[@"chance", @"remain", @"available", @"left", @"surplus", @"rest",
             @"opportunity", @"drawtimes", @"drawcount", @"lotterytimes", @"ticket"];
}

/// 明确排除的字段：这些数字不是"可用机会"，抓了会算错。
static NSArray<NSString *> *AFExcludeKeyHints(void) {
    // 注意：不能排除 "time"，否则 "drawTimes" 这类正牌机会字段会被误杀。
    // 只排除明确代表"已用/总量/时间戳"的词。
    return @[@"used", @"total", @"history", @"consume", @"cost", @"limit",
             @"max", @"price", @"record", @"rank", @"level", @"timestamp",
             @"date", @"progress", @"rate"];
}

@implementation AFChanceLedger

+ (instancetype)sharedInstance {
    static AFChanceLedger *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AFChanceLedger alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        // 默认开启；只有用户显式关闭过才为 NO
        _enabled = [ud objectForKey:kChanceEnabledKey] ? [ud boolForKey:kChanceEnabledKey] : YES;
    }
    return self;
}

#pragma mark - 只读属性

- (NSInteger)availableChance {
    return [NSUserDefaults.standardUserDefaults integerForKey:kChanceValueKey];
}

- (NSString *)lastSource {
    return [NSUserDefaults.standardUserDefaults stringForKey:kChanceSourceKey] ?: @"尚未识别";
}

- (NSTimeInterval)lastUpdateTime {
    return [NSUserDefaults.standardUserDefaults doubleForKey:kChanceUpdateKey];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kChanceEnabledKey];
}

#pragma mark - 核心：镜像机会数

- (void)mirrorChanceFromResponse:(id)response {
    if (!self.enabled) return;
    if (![response isKindOfClass:NSDictionary.class]) return;

    NSDictionary *root = (NSDictionary *)response;
    NSString *json = [AFChanceLedger flatKeyPathStringOf:root];
    if (json.length == 0) return;

    // 1) 确认这是抽奖/寻宝相关回包，避免误抓其他业务数字
    BOOL hasLotteryMarker = NO;
    for (NSString *marker in AFLotteryMarkers()) {
        if ([json rangeOfString:marker options:NSCaseInsensitiveSearch].location != NSNotFound) {
            hasLotteryMarker = YES;
            break;
        }
    }
    if (!hasLotteryMarker) return;

    // 2) 递归找最像"剩余机会数"的数字字段
    NSDictionary *best = [AFChanceLedger bestChanceCandidateIn:root path:@""];
    if (!best) return;

    NSNumber *number = best[@"value"];
    NSString *path = best[@"path"] ?: @"未知字段";
    if (![number isKindOfClass:NSNumber.class]) return;

    NSInteger value = number.integerValue;
    if (value < 0 || value > 100000) return;   // 明显不是机会数，丢弃

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSInteger oldValue = [ud integerForKey:kChanceValueKey];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    // 3) 赋值而非累加：同一回包重复到达 10 次，结果仍是同一个数 —— 天然防重复累计
    [ud setInteger:value forKey:kChanceValueKey];
    [ud setObject:path forKey:kChanceSourceKey];
    [ud setDouble:now forKey:kChanceUpdateKey];

    // 4) 只在数字真正变化时写日志，避免刷屏
    if (value != oldValue) {
        NSString *line = [NSString stringWithFormat:@"机会数 %ld → %ld（来源：%@）",
                          (long)oldValue, (long)value, path];
        [AFChanceLedger appendLogLine:line];
        NSLog(@"[AFChanceLedger] %@", line);
    }

    // 5) 通知面板刷新（面板存在时才有人接收）
    [NSNotificationCenter.defaultCenter postNotificationName:@"AFChanceLedgerDidUpdate" object:nil];
}

- (void)resetLocalDisplay {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setInteger:0 forKey:kChanceValueKey];
    [ud setObject:@"本地手动归零" forKey:kChanceSourceKey];
    [ud setDouble:NSDate.date.timeIntervalSince1970 forKey:kChanceUpdateKey];
    [AFChanceLedger appendLogLine:@"本地显示已手动归零（不影响服务端真实数据）"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"AFChanceLedgerDidUpdate" object:nil];
}

#pragma mark - 内部工具

/// 把整个回包拍平成一段小写字符串，仅用于判断"是否抽奖场景"。
+ (NSString *)flatKeyPathStringOf:(id)obj {
    NSMutableString *out = [NSMutableString string];
    [AFChanceLedger flattenKeysOf:obj into:out depth:0];
    return out.copy;
}

+ (void)flattenKeysOf:(id)obj into:(NSMutableString *)out depth:(NSInteger)depth {
    if (depth > 6 || !out) return;
    if ([obj isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:NSString.class]) [out appendFormat:@"%@ ", [key lowercaseString]];
            [AFChanceLedger flattenKeysOf:value into:out depth:depth + 1];
        }];
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)obj) [AFChanceLedger flattenKeysOf:item into:out depth:depth + 1];
    }
}

/// 递归打分，挑出最像"剩余抽奖机会"的字段。
+ (NSDictionary *)bestChanceCandidateIn:(id)obj path:(NSString *)path {
    NSMutableArray *candidates = [NSMutableArray array];
    [AFChanceLedger collectCandidatesFrom:obj path:path into:candidates depth:0];

    NSDictionary *best = nil;
    NSInteger bestScore = 0;
    for (NSDictionary *c in candidates) {
        NSInteger score = [c[@"score"] integerValue];
        if (score > bestScore) { bestScore = score; best = c; }
    }
    return best;
}

+ (void)collectCandidatesFrom:(id)obj path:(NSString *)path into:(NSMutableArray *)candidates depth:(NSInteger)depth {
    if (depth > 6 || !candidates) return;

    if ([obj isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if (![key isKindOfClass:NSString.class]) return;
            NSString *k = (NSString *)key;
            NSString *lower = [k lowercaseString];
            NSString *childPath = path.length ? [NSString stringWithFormat:@"%@.%@", path, k] : k;

            if ([value isKindOfClass:NSNumber.class]) {
                NSInteger score = [AFChanceLedger scoreForKey:lower];
                if (score > 0) {
                    [candidates addObject:@{@"value": value, @"path": childPath, @"score": @(score)}];
                }
            } else {
                [AFChanceLedger collectCandidatesFrom:value path:childPath into:candidates depth:depth + 1];
            }
        }];
    } else if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        for (NSInteger i = 0; i < arr.count && i < 30; i++) {
            [AFChanceLedger collectCandidatesFrom:arr[i]
                                             path:[NSString stringWithFormat:@"%@[%ld]", path, (long)i]
                                             into:candidates
                                            depth:depth + 1];
        }
    }
}

/// 字段打分：命中"剩余/可用"加分，命中"已用/总数"直接判负。
+ (NSInteger)scoreForKey:(NSString *)lowerKey {
    for (NSString *bad in AFExcludeKeyHints()) {
        if ([lowerKey rangeOfString:bad].location != NSNotFound) return -1;
    }
    NSInteger score = 0;
    for (NSString *hint in AFChanceKeyHints()) {
        if ([lowerKey rangeOfString:hint].location != NSNotFound) score += 2;
    }
    // 只含 "chance" 或 "remain" 且字段很短的，可信度最高
    if ([lowerKey containsString:@"chance"] || [lowerKey containsString:@"remain"]) score += 3;
    return score;
}

+ (void)appendLogLine:(NSString *)line {
    if (line.length == 0) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableArray *logs = [[ud arrayForKey:kChanceLogKey] mutableCopy] ?: [NSMutableArray array];
    [logs insertObject:line atIndex:0];
    if (logs.count > 40) [logs removeObjectsInRange:NSMakeRange(40, logs.count - 40)];
    [ud setObject:logs.copy forKey:kChanceLogKey];
}

+ (NSArray<NSString *> *)recentLogs {
    return [NSUserDefaults.standardUserDefaults arrayForKey:kChanceLogKey] ?: @[];
}

@end
